import Foundation
import GRDB
import MazidiDomain
import MazidiFoundations
import MazidiPersistence
import MazidiSync

// ─────────────────────────────────────────────────────────────────────────────
//  v4 health-data consent rows (ADR-0013). Internal to the GRDB adapter (ADR-0007: only
//  this target imports GRDB). Rows carry ids, a purpose identifier, a notice version and
//  timestamps — never health content.
// ─────────────────────────────────────────────────────────────────────────────

/// `health_data_consent` — one immutable consent decision for one purpose.
struct HealthDataConsentRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "health_data_consent"

    var id: String
    var purpose: String
    var grantedAt: Date
    var noticeVersion: String
    var withdrawnAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, purpose
        case grantedAt = "granted_at"
        case noticeVersion = "notice_version"
        case withdrawnAt = "withdrawn_at"
    }

    init(record: HealthDataConsent) {
        id = record.id.rawValue.uuidString
        purpose = record.purpose.rawValue
        grantedAt = record.grantedAt
        noticeVersion = record.noticeVersion.rawValue
        withdrawnAt = record.withdrawnAt
    }

    func toDomain() throws -> HealthDataConsent {
        guard let uuid = UUID(uuidString: id) else {
            throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "id", value: id)
        }
        guard let purpose = HealthDataConsent.Purpose(rawValue: purpose) else {
            throw RecordMappingError.unknownEnumValue(table: Self.databaseTableName, column: "purpose", value: purpose)
        }
        return HealthDataConsent(
            restoring: Identifier<HealthDataConsent>(uuid),
            purpose: purpose,
            noticeVersion: PrivacyNoticeVersion(noticeVersion),
            grantedAt: grantedAt,
            withdrawnAt: withdrawnAt
        )
    }
}

// MARK: - HealthDataConsentRepository (ADR-0013)

extension GRDBStore: HealthDataConsentRepository {
    /// Grant: consent row + outbox operation(s) + audit event in ONE transaction — the same
    /// invariant every other mutation obeys (ADR-0003/0006). The consent row is INSERTed, never
    /// saved-over: a colliding id violates the primary key and rolls the whole write back
    /// rather than overwriting an existing decision.
    public func grantConsentAtomically(
        _ record: HealthDataConsent,
        enqueueing operations: [SyncOperation],
        auditing event: PendingAuditEvent
    ) async throws {
        let hook = atomicWriteHook
        try await writer.write { db in
            try HealthDataConsentRecord(record: record).insert(db)
            try hook?()
            for operation in operations {
                try OutboxOperationRecord(operation: operation).insert(db)
            }
            try Self.appendAudit(event, in: db)
        }
    }

    /// Withdrawal: stamps `withdrawn_at` and nothing else, in ONE transaction with its outbox
    /// operation and audit event.
    ///
    /// The UPDATE names a single column and is conditional on `withdrawn_at IS NULL`, so:
    /// no row can be deleted here, `purpose`/`granted_at`/`notice_version` cannot be rewritten
    /// here, and a repeated withdrawal changes nothing and throws instead of quietly moving the
    /// timestamp. Nothing in this method can touch `set_entry`, `workout_session` or any other
    /// recorded data — withdrawal stops future collection, it does not erase history.
    public func withdrawConsentAtomically(
        recordID: Identifier<HealthDataConsent>,
        at withdrawnAt: Date,
        enqueueing operations: [SyncOperation],
        auditing event: PendingAuditEvent
    ) async throws {
        let key = recordID.rawValue.uuidString
        let hook = atomicWriteHook
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE health_data_consent SET withdrawn_at = ? WHERE id = ? AND withdrawn_at IS NULL",
                arguments: [withdrawnAt, key]
            )
            guard db.changesCount == 1 else {
                throw HealthDataConsentStoreError.noRecordInForce(recordID)
            }
            try hook?()
            for operation in operations {
                try OutboxOperationRecord(operation: operation).insert(db)
            }
            try Self.appendAudit(event, in: db)
        }
    }

    public func consentLedger() async throws -> HealthDataConsentLedger {
        try await writer.read { db in
            HealthDataConsentLedger(
                records: try HealthDataConsentRecord
                    .order(Column("granted_at"), Column("id"))
                    .fetchAll(db)
                    .map { try $0.toDomain() }
            )
        }
    }

    /// Link and insert an audit event inside an open transaction (ADR-0006): the chain hash can
    /// only be resolved here, against the row that is genuinely last at commit time.
    static func appendAudit(_ event: PendingAuditEvent, in db: Database) throws {
        let previousHash = try AuditEventRecord.order(sql: "rowid DESC").fetchOne(db)
            .map { auditChainHash(of: try $0.toDomain()) } ?? "0"
        try AuditEventRecord(event: event.linked(previousHash: previousHash)).insert(db)
    }
}
