import Foundation
import GRDB
import MazidiDomain
import MazidiFoundations
import MazidiPersistence
import MazidiSync

// ─────────────────────────────────────────────────────────────────────────────
//  v3 backend-sync metadata rows (ADR-0012). Internal to the GRDB adapter (ADR-0007:
//  only this target imports GRDB). These carry ONLY sync metadata (ids, versions,
//  cursors, delivery state) — never a copy of a domain payload snapshot. The push/pull
//  engine (CG4/CG5) maps these to the provider-neutral MazidiNetworking contracts.
// ─────────────────────────────────────────────────────────────────────────────

/// `sync_cursor` — durable, account-scoped pull checkpoint.
struct SyncCursorRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "sync_cursor"

    var stream: String
    var cursorToken: String?
    var lastServerVersion: Int
    var schemaVersion: Int
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case stream
        case cursorToken = "cursor_token"
        case lastServerVersion = "last_server_version"
        case schemaVersion = "schema_version"
        case updatedAt = "updated_at"
    }
}

/// `remote_record` — local↔remote id mapping + server version + tombstone flag.
struct RemoteRecordRow: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "remote_record"

    var entityType: String
    var localId: String
    var remoteId: String?
    var serverVersion: Int
    var tombstoned: Bool
    var lastSyncedAt: Date?

    enum CodingKeys: String, CodingKey {
        case entityType = "entity_type"
        case localId = "local_id"
        case remoteId = "remote_id"
        case serverVersion = "server_version"
        case tombstoned
        case lastSyncedAt = "last_synced_at"
    }
}

/// `relationship` — Coach–Client relationship (opaque account ids, never email).
struct RelationshipRow: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "relationship"

    var id: String
    var remoteId: String?
    var coachAccountId: String
    var clientAccountId: String
    var status: String
    var createdAt: Date
    var acceptedAt: Date?
    var endedAt: Date?
    var serverVersion: Int
    var localSyncState: String

    enum CodingKeys: String, CodingKey {
        case id, status
        case remoteId = "remote_id"
        case coachAccountId = "coach_account_id"
        case clientAccountId = "client_account_id"
        case createdAt = "created_at"
        case acceptedAt = "accepted_at"
        case endedAt = "ended_at"
        case serverVersion = "server_version"
        case localSyncState = "local_sync_state"
    }

    init(id: String, remoteId: String?, coachAccountId: String, clientAccountId: String,
         status: String, createdAt: Date, acceptedAt: Date?, endedAt: Date?, serverVersion: Int, localSyncState: String) {
        self.id = id
        self.remoteId = remoteId
        self.coachAccountId = coachAccountId
        self.clientAccountId = clientAccountId
        self.status = status
        self.createdAt = createdAt
        self.acceptedAt = acceptedAt
        self.endedAt = endedAt
        self.serverVersion = serverVersion
        self.localSyncState = localSyncState
    }

    init(relationship: Relationship) {
        id = relationship.id.rawValue.uuidString
        remoteId = nil
        coachAccountId = relationship.coachAccountRef
        clientAccountId = relationship.clientAccountRef
        status = relationship.status.rawValue
        createdAt = relationship.createdAt
        acceptedAt = relationship.acceptedAt
        endedAt = relationship.endedAt
        serverVersion = relationship.serverVersion
        localSyncState = relationship.localSyncState.rawValue
    }

    func toDomain() throws -> Relationship {
        guard let uuid = UUID(uuidString: id) else {
            throw RecordMappingError.badUUID(table: Self.databaseTableName, column: "id", value: id)
        }
        guard let status = Relationship.Status(rawValue: status) else {
            throw RecordMappingError.unknownEnumValue(table: Self.databaseTableName, column: "status", value: status)
        }
        guard let localSync = Relationship.LocalSyncState(rawValue: localSyncState) else {
            throw RecordMappingError.unknownEnumValue(table: Self.databaseTableName, column: "local_sync_state", value: localSyncState)
        }
        return Relationship(
            restoring: Identifier<Relationship>(uuid),
            coachAccountRef: coachAccountId,
            clientAccountRef: clientAccountId,
            status: status,
            createdAt: createdAt,
            acceptedAt: acceptedAt,
            endedAt: endedAt,
            serverVersion: serverVersion,
            localSyncState: localSync
        )
    }
}

/// Projection of the `workout_assignment` delivery/receipt columns (read/updated without
/// touching the immutable `content_json` snapshot).
struct AssignmentDeliveryRow: Codable, FetchableRecord, TableRecord, Equatable {
    static let databaseTableName = "workout_assignment"

    var id: String
    var remoteId: String?
    var serverVersion: Int
    var relationshipId: String?
    var deliveryState: String
    var deliveredAt: Date?
    var openedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case remoteId = "remote_id"
        case serverVersion = "server_version"
        case relationshipId = "relationship_id"
        case deliveryState = "delivery_state"
        case deliveredAt = "delivered_at"
        case openedAt = "opened_at"
    }
}

// MARK: - Store accessors (internal; consumed by CG4–CG8 and the migration tests)

extension GRDBStore {
    // Cursor
    func syncCursor(stream: String) async throws -> SyncCursorRecord? {
        try await writer.read { db in try SyncCursorRecord.fetchOne(db, key: stream) }
    }

    func saveSyncCursor(_ record: SyncCursorRecord) async throws {
        try await writer.write { db in try record.save(db) }
    }

    // Remote record mapping
    func remoteRecord(entityType: String, localID: String) async throws -> RemoteRecordRow? {
        try await writer.read { db in
            try RemoteRecordRow.filter(Column("entity_type") == entityType && Column("local_id") == localID).fetchOne(db)
        }
    }

    func remoteRecord(entityType: String, remoteID: String) async throws -> RemoteRecordRow? {
        try await writer.read { db in
            try RemoteRecordRow.filter(Column("entity_type") == entityType && Column("remote_id") == remoteID).fetchOne(db)
        }
    }

    func upsertRemoteRecord(_ record: RemoteRecordRow) async throws {
        try await writer.write { db in try record.save(db) }
    }

    // Relationships
    func relationshipRow(id: String) async throws -> RelationshipRow? {
        try await writer.read { db in try RelationshipRow.fetchOne(db, key: id) }
    }

    func saveRelationship(_ record: RelationshipRow) async throws {
        try await writer.write { db in try record.save(db) }
    }

    // Assignment delivery/receipt columns
    func assignmentDelivery(id: Identifier<WorkoutAssignment>) async throws -> AssignmentDeliveryRow? {
        let key = id.rawValue.uuidString
        return try await writer.read { db in try AssignmentDeliveryRow.fetchOne(db, key: key) }
    }

    public enum AssignmentDeliveryError: Error, Equatable {
        case notFound
        case illegalTransition(from: AssignmentDeliveryState, to: AssignmentDeliveryState)
    }

    /// Advance an assignment's delivery/receipt state with a guarded transition, in one
    /// transaction (ADR-0012 §7). `delivered_at` is set only on `acceptedByServer`,
    /// `opened_at` only on `openedByClient` (a distinct receipt event). The
    /// `assignmentDelivered` audit event fires ONLY on genuine `acceptedByServer` — never at
    /// `queuedForUpload`, never on the DEBUG relay path. The immutable content snapshot and
    /// the execution `status` column are never touched.
    public func advanceAssignmentDelivery(
        id: Identifier<WorkoutAssignment>,
        to newState: AssignmentDeliveryState,
        remoteID: String? = nil,
        serverVersion: Int? = nil,
        at now: Date,
        auditActorID: UUID
    ) async throws {
        let key = id.rawValue.uuidString
        try await writer.write { db in
            guard let row = try AssignmentDeliveryRow.fetchOne(db, key: key) else {
                throw AssignmentDeliveryError.notFound
            }
            let current = AssignmentDeliveryState(rawValue: row.deliveryState) ?? .createdLocally
            guard current.canAdvance(to: newState) else {
                throw AssignmentDeliveryError.illegalTransition(from: current, to: newState)
            }
            let deliveredAt = newState == .acceptedByServer ? now : row.deliveredAt
            let openedAt = newState == .openedByClient ? now : row.openedAt
            try db.execute(sql: """
                UPDATE workout_assignment
                SET delivery_state = ?,
                    remote_id = COALESCE(?, remote_id),
                    server_version = COALESCE(?, server_version),
                    delivered_at = ?, opened_at = ?
                WHERE id = ?
                """, arguments: [newState.rawValue, remoteID, serverVersion, deliveredAt, openedAt, key])

            // Audit only genuine server acceptance — in the SAME transaction.
            if newState == .acceptedByServer {
                let previousHash = try AuditEventRecord.order(sql: "rowid DESC").fetchOne(db)
                    .map { auditChainHash(of: try $0.toDomain()) } ?? "0"
                let event = AuditEvent(kind: .assignmentDelivered, actorID: auditActorID,
                                       subjectDescription: "assignment:\(key)", occurredAt: now, previousHash: previousHash)
                try AuditEventRecord(event: event).insert(db)
            }
        }
    }

    /// Update only the delivery/receipt/remote-binding columns; the immutable snapshot and
    /// execution `status` are untouched.
    func updateAssignmentDelivery(
        id: Identifier<WorkoutAssignment>,
        state: AssignmentDeliveryState,
        remoteID: String?,
        serverVersion: Int,
        relationshipID: String?,
        deliveredAt: Date?,
        openedAt: Date?
    ) async throws {
        let key = id.rawValue.uuidString
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE workout_assignment
                SET delivery_state = ?, remote_id = ?, server_version = ?, relationship_id = ?,
                    delivered_at = ?, opened_at = ?
                WHERE id = ?
                """, arguments: [state.rawValue, remoteID, serverVersion, relationshipID, deliveredAt, openedAt, key])
        }
    }
}

// MARK: - BackendSyncStore + RelationshipRepository (ADR-0012 §3/§6)

extension GRDBStore: BackendSyncStore, RelationshipRepository {
    public func applyPushResults(_ applications: [PushOutcomeApplication], at now: Date) async throws {
        try await writer.write { db in
            for application in applications {
                switch application.outcome {
                case let .acknowledged(remoteID, serverVersion):
                    // Remove from replay: acknowledged, error cleared, no backoff.
                    try db.execute(sql: """
                        UPDATE outbox_operation
                        SET status = 'acknowledged', last_error = NULL, next_attempt_at = NULL
                        WHERE id = ?
                        """, arguments: [application.operationID.uuidString])
                    // Record the server version in the SAME transaction (idempotent upsert).
                    try RemoteRecordRow(
                        entityType: application.entityType,
                        localId: application.localEntityID,
                        remoteId: remoteID,
                        serverVersion: serverVersion,
                        tombstoned: false,
                        lastSyncedAt: now
                    ).save(db)
                case let .deadLettered(reason):
                    try db.execute(sql: """
                        UPDATE outbox_operation
                        SET status = 'rejected', last_error = ?, next_attempt_at = NULL
                        WHERE id = ?
                        """, arguments: [reason, application.operationID.uuidString])
                case let .retry(nextAttemptAt, reason):
                    try db.execute(sql: """
                        UPDATE outbox_operation
                        SET status = 'pending', last_error = ?, next_attempt_at = ?
                        WHERE id = ?
                        """, arguments: [reason, nextAttemptAt, application.operationID.uuidString])
                }
            }
        }
    }

    /// Clear the backoff schedule for all pending operations (retry-now), e.g. when
    /// connectivity is restored — so a reconnect drains immediately instead of waiting out
    /// the exponential backoff. Does not change status; only `next_attempt_at`.
    public func clearPendingRetrySchedule() async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE outbox_operation SET next_attempt_at = NULL WHERE status = 'pending'")
        }
    }

    public func loadSyncCursor(stream: String) async throws -> SyncCursorState? {
        try await syncCursor(stream: stream).map {
            SyncCursorState(token: $0.cursorToken, lastServerVersion: $0.lastServerVersion, schemaVersion: $0.schemaVersion)
        }
    }

    public func saveSyncCursor(_ cursor: SyncCursorState, stream: String, at now: Date) async throws {
        try await saveSyncCursor(SyncCursorRecord(
            stream: stream, cursorToken: cursor.token,
            lastServerVersion: cursor.lastServerVersion, schemaVersion: cursor.schemaVersion, updatedAt: now
        ))
    }

    public func remoteRecordState(entityType: String, localID: String) async throws -> RemoteRecordState? {
        try await remoteRecord(entityType: entityType, localID: localID).map {
            RemoteRecordState(entityType: $0.entityType, localID: $0.localId, remoteID: $0.remoteId,
                              serverVersion: $0.serverVersion, tombstoned: $0.tombstoned, lastSyncedAt: $0.lastSyncedAt)
        }
    }

    // RelationshipRepository (ADR-0012 §6): relationship write + queued op in one transaction.
    public func saveRelationshipAtomically(_ relationship: Relationship, enqueueing operations: [SyncOperation]) async throws {
        try await writer.write { db in
            try RelationshipRow(relationship: relationship).save(db)
            for operation in operations {
                try OutboxOperationRecord(operation: operation).insert(db)
            }
        }
    }

    public func relationship(id: Identifier<Relationship>) async throws -> Relationship? {
        try await relationshipRow(id: id.rawValue.uuidString)?.toDomain()
    }

    public func allRelationships() async throws -> [Relationship] {
        try await writer.read { db in
            try RelationshipRow.order(Column("created_at")).fetchAll(db).map { try $0.toDomain() }
        }
    }

    public func applyPullChanges(_ materializations: [PulledMaterialization], advancingCursorTo cursor: SyncCursorState, stream: String, at now: Date) async throws {
        try await writer.write { db in
            for change in materializations {
                var localID = change.remoteID
                var tombstoned = false
                switch change.entity {
                case let .assignment(assignment):
                    // Materialise the delivered assignment (idempotent upsert) in the SAME
                    // transaction as the cursor advance.
                    try WorkoutAssignmentRecord(assignment: assignment).save(db)
                    localID = assignment.id.rawValue.uuidString
                case let .relationship(relationship):
                    try RelationshipRow(relationship: relationship).save(db)
                    localID = relationship.id.rawValue.uuidString
                case .tombstone:
                    tombstoned = true
                case .trackVersionOnly:
                    break
                }
                // Track remote id / version / tombstone (idempotent upsert).
                try RemoteRecordRow(
                    entityType: change.entityType,
                    localId: localID,
                    remoteId: change.remoteID,
                    serverVersion: change.serverVersion,
                    tombstoned: tombstoned,
                    lastSyncedAt: now
                ).save(db)
            }
            // Advance the cursor in the SAME transaction — never past un-applied changes.
            try SyncCursorRecord(
                stream: stream, cursorToken: cursor.token,
                lastServerVersion: cursor.lastServerVersion, schemaVersion: cursor.schemaVersion, updatedAt: now
            ).save(db)
        }
    }
}
