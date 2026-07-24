import Foundation
import GRDB
import Testing
import MazidiAuth
import MazidiDomain
import MazidiFoundations
@testable import MazidiPersistenceGRDB

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

private func assignment(assignee: String = "dev-client-001") throws -> WorkoutAssignment {
    var template = WorkoutTemplate(
        draft: WorkoutTemplateContent(title: "Lower A", exercises: [
            PrescribedExercise(slug: "barbell-squat", order: 0, prescription: .repsAndLoad(sets: 3, reps: 5...8, loadKg: 80)),
        ]),
        updatedAt: t0
    )
    let version = try template.publish(at: t0)
    return WorkoutAssignment(version: version, assigneeAccountRef: assignee, assignedAt: t0)
}

@Suite struct SyncMetadataMigrationTests {
    private func uniqueDir(_ tag: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mazidi-\(tag)-\(UUID().uuidString)", isDirectory: true)
    }

    // (a) v3 preserves v1/v2 data: build a v2-only database with a real assignment + session,
    // then open through the store (which applies v3) and confirm nothing was lost or rewritten.
    @Test func v3MigrationPreservesExistingV2DataAndDefaultsNewColumns() async throws {
        let dir = uniqueDir("v2v3")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mazidi-client.sqlite")
        let assignment = try assignment()
        let squat = AssignedExercise(slug: "barbell-squat", prescription: .repsAndLoad(sets: 3, reps: 5...8, loadKg: 80))
        var session = WorkoutSession(workout: AssignedWorkout(title: "Old", programmeVersion: 1, sections: [.main: [squat]]), epoch: 1)
        try session.start(at: t0)
        let startedSession = session

        // Migrate a raw database up to v2 ONLY, then insert real rows with the v2 column set.
        let queue = try DatabaseQueue(path: url.path)
        try GRDBSchema.migrator().migrate(queue, upTo: "v2-coach-programming")
        try await queue.write { db in
            try WorkoutAssignmentRecord(assignment: assignment).insert(db)
            try WorkoutSessionRecord(session: startedSession).insert(db)
        }
        try queue.close()

        // Open through the store → v3 applies forward.
        let store = try GRDBStore.open(directory: dir)
        #expect(store.recovery == .normal(createdNew: false))    // a real migration, not quarantine

        // v2 data intact and unchanged.
        let restored = try await store.assignment(id: assignment.id)
        #expect(restored == assignment)                          // assignee_ref, snapshot, status all preserved
        #expect(try await store.session(id: startedSession.id)?.workout.title == "Old")

        // New v3 columns present with safe defaults; assignee never reassigned.
        let delivery = try #require(try await store.assignmentDelivery(id: assignment.id))
        #expect(delivery.deliveryState == AssignmentDeliveryState.createdLocally.rawValue)
        #expect(delivery.serverVersion == 0)
        #expect(delivery.remoteId == nil)
        #expect(delivery.relationshipId == nil)
        #expect(restored?.assigneeAccountRef == "dev-client-001")
        try store.close()
    }

    // (b) Repeated migration is idempotent: reopening an already-v3 database is a no-op and
    // preserves data.
    @Test func repeatedMigrationIsIdempotent() async throws {
        let dir = uniqueDir("v3-idem")
        let a = try assignment()
        do {
            let store = try GRDBStore.open(directory: dir)
            try await store.saveAssignmentAtomically(a, enqueueing: [])
            try store.close()
        }
        let reopened = try GRDBStore.open(directory: dir)          // migrator re-runs: no-op
        #expect(reopened.recovery == .normal(createdNew: false))
        #expect(try await reopened.assignment(id: a.id) == a)
        try reopened.close()
    }

    // (c) All v3 indexes exist.
    @Test func v3IndexesArePresent() async throws {
        let store = try GRDBStore.open(directory: uniqueDir("v3-idx"))
        let indexes = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='index'")
        }
        let expected = ["idx_outbox_due", "idx_remote_record_remote_id", "idx_relationship_status",
                        "idx_relationship_coach", "idx_relationship_client",
                        "idx_assignment_delivery_state", "idx_assignment_relationship"]
        for name in expected { #expect(indexes.contains(name), "missing index \(name)") }
        try store.close()
    }

    // (d) New v3 tables round-trip.
    @Test func syncMetadataTablesRoundTrip() async throws {
        let store = try GRDBStore.open(directory: uniqueDir("v3-rt"))

        try await store.saveSyncCursor(SyncCursorRecord(stream: "default", cursorToken: "tok-1", lastServerVersion: 42, schemaVersion: 1, updatedAt: t0))
        #expect(try await store.syncCursor(stream: "default")?.lastServerVersion == 42)

        let rr = RemoteRecordRow(entityType: "workoutAssignment", localId: "local-1", remoteId: "remote-1", serverVersion: 3, tombstoned: false, lastSyncedAt: t0)
        try await store.upsertRemoteRecord(rr)
        #expect(try await store.remoteRecord(entityType: "workoutAssignment", localID: "local-1") == rr)
        #expect(try await store.remoteRecord(entityType: "workoutAssignment", remoteID: "remote-1")?.localId == "local-1")

        let rel = RelationshipRow(id: "rel-1", remoteId: nil, coachAccountId: "dev-coach-001", clientAccountId: "dev-client-001",
                                  status: "active", createdAt: t0, acceptedAt: t0, endedAt: nil, serverVersion: 1, localSyncState: "synced")
        try await store.saveRelationship(rel)
        #expect(try await store.relationship(id: "rel-1") == rel)
        #expect(try await store.allRelationships().count == 1)

        // Assignment delivery columns update without touching the snapshot/status.
        let a = try assignment()
        try await store.saveAssignmentAtomically(a, enqueueing: [])
        try await store.updateAssignmentDelivery(id: a.id, state: .acceptedByServer, remoteID: "asg-remote-1",
                                                  serverVersion: 5, relationshipID: "rel-1", deliveredAt: t0, openedAt: nil)
        let d = try #require(try await store.assignmentDelivery(id: a.id))
        #expect(d.deliveryState == "acceptedByServer")
        #expect(d.remoteId == "asg-remote-1")
        #expect(try await store.assignment(id: a.id)?.status == .queued)   // execution status untouched
        try store.close()
    }

    // (e) No cross-account reassignment: two account-scoped databases under one base migrate
    // independently; neither sees the other's assignment, and assignee_ref is never rewritten.
    @Test func migrationNeverReassignsAcrossAccounts() async throws {
        let base = uniqueDir("v3-accts")
        let dirA = AccountDatabasePath.directory(base: base, accountID: AccountID("acct-a"))
        let dirB = AccountDatabasePath.directory(base: base, accountID: AccountID("acct-b"))
        let a = try assignment(assignee: "dev-client-001")

        let storeA = try GRDBStore.open(directory: dirA)
        try await storeA.saveAssignmentAtomically(a, enqueueing: [])
        try storeA.close()

        let storeB = try GRDBStore.open(directory: dirB)               // separate account DB
        #expect(try await storeB.allAssignments().isEmpty)             // B never receives A's row
        try storeB.close()

        let reopenedA = try GRDBStore.open(directory: dirA)
        #expect(try await reopenedA.assignment(id: a.id)?.assigneeAccountRef == "dev-client-001")
        try reopenedA.close()
    }

    // (f) Corruption recovery stays account-scoped with the v3 schema usable afterwards.
    @Test func corruptionRecoveryKeepsV3TablesUsableAndScoped() async throws {
        let base = uniqueDir("v3-corrupt")
        let victim = AccountDatabasePath.directory(base: base, accountID: AccountID("acct-a"))
        let bystander = AccountDatabasePath.directory(base: base, accountID: AccountID("acct-b"))

        let good = try GRDBStore.open(directory: bystander)
        try await good.saveRelationship(RelationshipRow(id: "rel-b", remoteId: nil, coachAccountId: "c", clientAccountId: "cl",
                                                        status: "active", createdAt: t0, acceptedAt: nil, endedAt: nil, serverVersion: 0, localSyncState: "synced"))
        try good.close()

        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: victim.appendingPathComponent("mazidi-client.sqlite"))
        let recovered = try GRDBStore.open(directory: victim)
        guard case .recoveredAfterQuarantine = recovered.recovery else {
            Issue.record("expected quarantine, got \(recovered.recovery)"); return
        }
        // v3 tables usable on the fresh replacement.
        try await recovered.saveSyncCursor(SyncCursorRecord(stream: "default", cursorToken: nil, lastServerVersion: 0, schemaVersion: 1, updatedAt: t0))
        #expect(try await recovered.syncCursor(stream: "default") != nil)
        try recovered.close()

        // Bystander untouched.
        let reopened = try GRDBStore.open(directory: bystander)
        #expect(try await reopened.relationship(id: "rel-b") != nil)
        try reopened.close()
    }
}
