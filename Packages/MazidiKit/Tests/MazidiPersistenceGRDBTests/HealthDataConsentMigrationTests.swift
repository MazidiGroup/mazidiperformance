import Foundation
import GRDB
import Testing
import MazidiAuth
import MazidiDomain
import MazidiFoundations
import MazidiPersistence
import MazidiSync
@testable import MazidiPersistenceGRDB

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)
private let notice = PrivacyNoticeVersion("v1")

private func uniqueDir(_ tag: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mazidi-\(tag)-\(UUID().uuidString)", isDirectory: true)
}

private func legacyAssignment(assignee: String = "dev-client-001") throws -> WorkoutAssignment {
    var template = WorkoutTemplate(
        draft: WorkoutTemplateContent(title: "Lower A", exercises: [
            PrescribedExercise(slug: "barbell-squat", order: 0, prescription: .repsAndLoad(sets: 3, reps: 5...8, loadKg: 80)),
        ]),
        updatedAt: t0
    )
    let version = try template.publish(at: t0)
    return WorkoutAssignment(version: version, assigneeAccountRef: assignee, assignedAt: t0)
}

private func operation(_ kind: SyncOperation.Kind, aggregate: UUID, sequence: Int = 0) -> SyncOperation {
    SyncOperation(kind: kind, aggregateID: aggregate, sequence: sequence, payload: Data("{}".utf8), enqueuedAt: t0)
}

private func pendingAudit(_ kind: AuditEvent.Kind, subject: String, payload: [String: String] = [:]) -> PendingAuditEvent {
    PendingAuditEvent(kind: kind, actorID: UUID(), subjectDescription: subject, occurredAt: t0, payload: payload)
}

@Suite struct HealthDataConsentMigrationTests {
    // (a) v3 → v4 preserves everything already stored, and adds the new table.
    @Test func v4MigrationPreservesExistingV1ToV3Data() async throws {
        let dir = uniqueDir("v3v4")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mazidi-client.sqlite")

        let assignment = try legacyAssignment()
        let squat = AssignedExercise(slug: "barbell-squat", prescription: .repsAndLoad(sets: 3, reps: 5...8, loadKg: 80))
        var session = WorkoutSession(
            workout: AssignedWorkout(title: "Old", programmeVersion: 1, sections: [.main: [squat]]),
            epoch: 1
        )
        try session.start(at: t0)
        _ = try session.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80), rpe: 8, at: t0)
        let started = session

        // Migrate a raw database up to v3 ONLY, then write real rows with the v3 column set.
        let queue = try DatabaseQueue(path: url.path)
        try GRDBSchema.migrator().migrate(queue, upTo: "v3-backend-sync-metadata")
        try await queue.write { db in
            try WorkoutAssignmentRecord(assignment: assignment).insert(db)
            try WorkoutSessionRecord(session: started).insert(db)
            for entry in started.setEntries {
                try SetEntryRecord(entry: entry, sessionID: started.id).insert(db)
            }
            try OutboxOperationRecord(operation: operation(.setRecorded, aggregate: started.id.rawValue)).insert(db)
            try SyncCursorRecord(stream: "default", cursorToken: "tok", lastServerVersion: 7,
                                 schemaVersion: 1, updatedAt: t0).insert(db)
        }
        try queue.close()

        // Open through the store → v4 applies forward.
        let store = try GRDBStore.open(directory: dir)
        #expect(store.recovery == .normal(createdNew: false))   // a real migration, not quarantine

        // Everything from v1/v2/v3 is intact and unchanged.
        #expect(try await store.assignment(id: assignment.id) == assignment)
        let restored = try #require(try await store.session(id: started.id))
        #expect(restored.workout.title == "Old")
        #expect(restored.setEntries.count == 1)
        #expect(restored.setEntries.first?.rpe == 8)           // health values untouched by the migration
        #expect(try await store.pendingOperations().count == 1)
        #expect(try await store.syncCursor(stream: "default")?.lastServerVersion == 7)

        // The new table exists and starts empty — no consent is invented for existing data.
        #expect(try await store.consentLedger().records.isEmpty)
        try store.close()
    }

    // (b) Repeated migration is idempotent: reopening an already-v4 database is a no-op.
    @Test func repeatedV4MigrationIsIdempotentAndPreservesConsentRecords() async throws {
        let dir = uniqueDir("v4-idem")
        let record = HealthDataConsent(purpose: .performanceRecording, noticeVersion: notice, grantedAt: t0)
        do {
            let store = try GRDBStore.open(directory: dir)
            try await store.grantConsentAtomically(
                record,
                enqueueing: [operation(.healthDataConsentGranted, aggregate: record.id.rawValue)],
                auditing: pendingAudit(.healthDataConsentGranted, subject: "healthDataConsent:\(record.id)")
            )
            try store.close()
        }
        let reopened = try GRDBStore.open(directory: dir)        // migrator re-runs: no-op
        #expect(reopened.recovery == .normal(createdNew: false))
        #expect(try await reopened.consentLedger().records == [record])
        try reopened.close()
    }

    // (c) v4 indexes exist (and the v1–v3 ones are still there).
    @Test func v4IndexesArePresent() async throws {
        let store = try GRDBStore.open(directory: uniqueDir("v4-idx"))
        let indexes = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index'")
        }
        for name in ["idx_health_consent_in_force", "idx_health_consent_purpose_granted"] {
            #expect(indexes.contains(name), "missing index \(name)")
        }
        // Additive: nothing earlier was dropped.
        for name in ["idx_outbox_status", "idx_outbox_due", "idx_assignment_delivery_state"] {
            #expect(indexes.contains(name), "v4 must not drop \(name)")
        }
        try store.close()
    }

    // (d) The ADR-0003/0006 invariant: consent row + outbox operation + audit event commit
    // together, or not at all.
    @Test func consentGrantCommitsWithItsOutboxOperationAndAuditEvent() async throws {
        let store = try GRDBStore.open(directory: uniqueDir("v4-atomic"))
        let record = HealthDataConsent(purpose: .coachSharing, noticeVersion: notice, grantedAt: t0)

        try await store.grantConsentAtomically(
            record,
            enqueueing: [operation(.healthDataConsentGranted, aggregate: record.id.rawValue)],
            auditing: pendingAudit(.healthDataConsentGranted, subject: "healthDataConsent:\(record.id)",
                                   payload: ["purpose": record.purpose.auditIdentifier])
        )

        #expect(try await store.consentLedger().records == [record])
        let ops = try await store.operations(inAggregate: record.id.rawValue)
        #expect(ops.map(\.kind) == [.healthDataConsentGranted])
        #expect(ops.first?.entityType == .healthDataConsent)
        let events = try await store.allEvents()
        #expect(events.map(\.kind) == [.healthDataConsentGranted])
        #expect(events.first?.previousHash == "0")               // genesis: chain is intact
        try store.close()
    }

    @Test func aFailureMidWriteRollsBackAllThreeHalves() async throws {
        let store = try GRDBStore.open(directory: uniqueDir("v4-rollback"))
        struct Boom: Error {}
        store.setAtomicWriteHook { throw Boom() }
        let record = HealthDataConsent(purpose: .coachSharing, noticeVersion: notice, grantedAt: t0)

        await #expect(throws: (any Error).self) {
            try await store.grantConsentAtomically(
                record,
                enqueueing: [operation(.healthDataConsentGranted, aggregate: record.id.rawValue)],
                auditing: pendingAudit(.healthDataConsentGranted, subject: "healthDataConsent:\(record.id)")
            )
        }
        store.setAtomicWriteHook(nil)

        #expect(try await store.consentLedger().records.isEmpty)   // no orphan consent row
        #expect(try await store.pendingOperations().isEmpty)       // no orphan operation
        #expect(try await store.allEvents().isEmpty)               // no orphan audit event
        try store.close()
    }

    @Test func withdrawalCommitsWithItsOutboxOperationAndAuditEvent() async throws {
        let store = try GRDBStore.open(directory: uniqueDir("v4-withdraw-atomic"))
        let record = HealthDataConsent(purpose: .coachSharing, noticeVersion: notice, grantedAt: t0)
        try await store.grantConsentAtomically(
            record,
            enqueueing: [operation(.healthDataConsentGranted, aggregate: record.id.rawValue)],
            auditing: pendingAudit(.healthDataConsentGranted, subject: "healthDataConsent:\(record.id)")
        )
        let withdrawnAt = t0.addingTimeInterval(600)
        try await store.withdrawConsentAtomically(
            recordID: record.id, at: withdrawnAt,
            enqueueing: [operation(.healthDataConsentWithdrawn, aggregate: record.id.rawValue, sequence: 1)],
            auditing: pendingAudit(.healthDataConsentWithdrawn, subject: "healthDataConsent:\(record.id)")
        )

        let ops = try await store.operations(inAggregate: record.id.rawValue)
        #expect(ops.map(\.kind) == [.healthDataConsentGranted, .healthDataConsentWithdrawn])
        #expect(ops.map(\.sequence) == [0, 1])                     // ordered replay per record
        let events = try await store.allEvents()
        #expect(events.map(\.kind) == [.healthDataConsentGranted, .healthDataConsentWithdrawn])
        // The chain links: the second event's previousHash is the first event's chain hash.
        #expect(events[1].previousHash == auditChainHash(of: events[0]))
        try store.close()
    }

    // (e) Withdrawal never deletes history and never rewrites the evidential columns.
    @Test func withdrawalPreservesTheRecordAndEveryRecordedSet() async throws {
        let store = try GRDBStore.open(directory: uniqueDir("v4-preserve"))

        // Recorded health data that must survive a withdrawal untouched.
        let squat = AssignedExercise(slug: "barbell-squat", prescription: .repsAndLoad(sets: 2, reps: 5...8, loadKg: 80))
        var session = WorkoutSession(
            workout: AssignedWorkout(title: "Lower A", programmeVersion: 1, sections: [.main: [squat]]),
            epoch: 1
        )
        try session.start(at: t0)
        _ = try session.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80), rpe: 8, at: t0)
        try await store.saveAtomically(session: session, enqueueing: [])

        let record = HealthDataConsent(purpose: .performanceRecording, noticeVersion: notice, grantedAt: t0)
        try await store.grantConsentAtomically(
            record, enqueueing: [],
            auditing: pendingAudit(.healthDataConsentGranted, subject: "healthDataConsent:\(record.id)")
        )
        let withdrawnAt = t0.addingTimeInterval(60)
        try await store.withdrawConsentAtomically(
            recordID: record.id, at: withdrawnAt, enqueueing: [],
            auditing: pendingAudit(.healthDataConsentWithdrawn, subject: "healthDataConsent:\(record.id)")
        )

        // The consent record is still there, closed — not deleted, not rewritten.
        let ledger = try await store.consentLedger()
        #expect(ledger.records.count == 1)
        let closed = try #require(ledger.records.first)
        #expect(closed.id == record.id)
        #expect(closed.grantedAt == t0)
        #expect(closed.noticeVersion == notice)
        #expect(closed.purpose == .performanceRecording)
        #expect(closed.withdrawnAt == withdrawnAt)

        // Everything recorded before the withdrawal is untouched.
        let restored = try #require(try await store.session(id: session.id))
        #expect(restored.setEntries.count == 1)
        #expect(restored.setEntries.first?.rpe == 8)
        try store.close()
    }

    @Test func withdrawingATwiceWithdrawnRecordChangesNothing() async throws {
        let store = try GRDBStore.open(directory: uniqueDir("v4-double"))
        let record = HealthDataConsent(purpose: .coachSharing, noticeVersion: notice, grantedAt: t0)
        try await store.grantConsentAtomically(
            record, enqueueing: [],
            auditing: pendingAudit(.healthDataConsentGranted, subject: "healthDataConsent:\(record.id)")
        )
        let first = t0.addingTimeInterval(10)
        try await store.withdrawConsentAtomically(
            recordID: record.id, at: first, enqueueing: [],
            auditing: pendingAudit(.healthDataConsentWithdrawn, subject: "healthDataConsent:\(record.id)")
        )

        await #expect(throws: HealthDataConsentStoreError.noRecordInForce(record.id)) {
            try await store.withdrawConsentAtomically(
                recordID: record.id, at: t0.addingTimeInterval(9999), enqueueing: [],
                auditing: pendingAudit(.healthDataConsentWithdrawn, subject: "healthDataConsent:\(record.id)")
            )
        }
        #expect(try await store.consentLedger().records.first?.withdrawnAt == first)   // not moved
        #expect(try await store.allEvents().count == 2)                                // no third event
        try store.close()
    }

    @Test func grantingTheSameRecordIdTwiceIsRejectedRatherThanOverwriting() async throws {
        let store = try GRDBStore.open(directory: uniqueDir("v4-dup"))
        let record = HealthDataConsent(purpose: .coachSharing, noticeVersion: notice, grantedAt: t0)
        try await store.grantConsentAtomically(
            record, enqueueing: [],
            auditing: pendingAudit(.healthDataConsentGranted, subject: "healthDataConsent:\(record.id)")
        )
        let impostor = HealthDataConsent(
            restoring: record.id, purpose: .performanceRecording,
            noticeVersion: PrivacyNoticeVersion("v9"), grantedAt: t0.addingTimeInterval(500), withdrawnAt: nil
        )
        await #expect(throws: (any Error).self) {
            try await store.grantConsentAtomically(
                impostor, enqueueing: [],
                auditing: pendingAudit(.healthDataConsentGranted, subject: "healthDataConsent:\(impostor.id)")
            )
        }
        let stored = try #require(try await store.consentLedger().records.first)
        #expect(stored == record)                    // original decision untouched
        #expect(try await store.allEvents().count == 1)
        try store.close()
    }

    // (f) Account scoping: consent recorded for one account is invisible to another, and the
    // migration never moves a record across account databases.
    @Test func consentIsScopedToItsAccountDatabase() async throws {
        let base = uniqueDir("v4-accts")
        let dirA = AccountDatabasePath.directory(base: base, accountID: AccountID("acct-a"))
        let dirB = AccountDatabasePath.directory(base: base, accountID: AccountID("acct-b"))
        let record = HealthDataConsent(purpose: .coachSharing, noticeVersion: notice, grantedAt: t0)

        let storeA = try GRDBStore.open(directory: dirA)
        try await storeA.grantConsentAtomically(
            record, enqueueing: [],
            auditing: pendingAudit(.healthDataConsentGranted, subject: "healthDataConsent:\(record.id)")
        )
        try storeA.close()

        let storeB = try GRDBStore.open(directory: dirB)
        #expect(try await storeB.consentLedger().records.isEmpty)   // B never sees A's consent
        // And B's gate is therefore closed — consent never leaks across accounts.
        #expect(!HealthDataConsentPolicy.mayCollect(.coachSharing, given: try await storeB.consentLedger()))
        try storeB.close()

        let reopenedA = try GRDBStore.open(directory: dirA)
        #expect(try await reopenedA.consentLedger().records == [record])
        try reopenedA.close()
    }

    // (g) Corruption recovery is unchanged: quarantine stays account-scoped and the v4 table is
    // usable on the fresh replacement (with no consent carried over — it is not evidence).
    @Test func corruptionRecoveryKeepsV4TableUsableAndScoped() async throws {
        let base = uniqueDir("v4-corrupt")
        let victim = AccountDatabasePath.directory(base: base, accountID: AccountID("acct-a"))
        let bystander = AccountDatabasePath.directory(base: base, accountID: AccountID("acct-b"))
        let bystanderRecord = HealthDataConsent(purpose: .performanceRecording, noticeVersion: notice, grantedAt: t0)

        let good = try GRDBStore.open(directory: bystander)
        try await good.grantConsentAtomically(
            bystanderRecord, enqueueing: [],
            auditing: pendingAudit(.healthDataConsentGranted, subject: "healthDataConsent:\(bystanderRecord.id)")
        )
        try good.close()

        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: victim.appendingPathComponent("mazidi-client.sqlite"))
        let recovered = try GRDBStore.open(directory: victim)
        guard case .recoveredAfterQuarantine = recovered.recovery else {
            Issue.record("expected quarantine, got \(recovered.recovery)"); return
        }
        // Fresh replacement: no consent, so the gate is closed until the client is asked again.
        #expect(try await recovered.consentLedger().records.isEmpty)
        let fresh = HealthDataConsent(purpose: .coachSharing, noticeVersion: notice, grantedAt: t0)
        try await recovered.grantConsentAtomically(
            fresh, enqueueing: [],
            auditing: pendingAudit(.healthDataConsentGranted, subject: "healthDataConsent:\(fresh.id)")
        )
        #expect(try await recovered.consentLedger().records == [fresh])
        try recovered.close()

        let reopened = try GRDBStore.open(directory: bystander)
        #expect(try await reopened.consentLedger().records == [bystanderRecord])   // untouched
        try reopened.close()
    }

    // (h) The stored row carries no health content — only ids, a purpose name, a notice
    // version and timestamps.
    @Test func storedConsentRowCarriesNoHealthContent() async throws {
        let store = try GRDBStore.open(directory: uniqueDir("v4-privacy"))
        let record = HealthDataConsent(purpose: .perceivedExertionRecording, noticeVersion: notice, grantedAt: t0)
        try await store.grantConsentAtomically(
            record, enqueueing: [],
            auditing: pendingAudit(.healthDataConsentGranted, subject: "healthDataConsent:\(record.id)",
                                   payload: ["purpose": record.purpose.auditIdentifier,
                                             "noticeVersion": notice.rawValue])
        )
        let columns = try await store.writer.read { db in
            try db.columns(in: "health_data_consent").map(\.name)
        }
        #expect(Set(columns) == ["id", "purpose", "granted_at", "notice_version", "withdrawn_at"])

        // The audit trail names the record and the purpose, nothing else.
        let event = try #require(try await store.allEvents().first)
        #expect(event.subjectDescription == "healthDataConsent:\(record.id)")
        #expect(event.payload == ["purpose": "perceivedExertionRecording", "noticeVersion": "v1"])
        try store.close()
    }
}
