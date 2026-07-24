import Foundation
import GRDB
import Testing
import MazidiAuth
import MazidiDomain
import MazidiFoundations
import MazidiSync
@testable import MazidiPersistenceGRDB

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

private func draftTemplate() -> WorkoutTemplate {
    WorkoutTemplate(
        draft: WorkoutTemplateContent(title: "Lower A", exercises: [
            PrescribedExercise(
                slug: "barbell-squat", order: 0,
                prescription: .repsAndLoad(sets: 3, reps: 5...8, loadKg: 80),
                coachNotes: "Brace", approvedAlternatives: ["kettlebell-sumo-deadlift"]
            ),
            PrescribedExercise(
                slug: "barbell-bent-over-row", order: 1,
                prescription: .repsOnly(sets: 2, reps: 8...10)
            ),
        ]),
        updatedAt: t0
    )
}

private func op(kind: SyncOperation.Kind, aggregate: UUID, seq: Int) -> SyncOperation {
    SyncOperation(kind: kind, aggregateID: aggregate, sequence: seq,
                  payload: Data("p".utf8), enqueuedAt: t0)
}

@Suite struct ProgrammingPersistenceTests {
    private func makeStore() throws -> GRDBStore { try GRDBStore.inMemory() }

    @Test func templateDraftRoundTripWithQueuedOperation() async throws {
        let store = try makeStore()
        let template = draftTemplate()
        try await store.saveTemplateAtomically(
            template, enqueueing: [op(kind: .templateDraftSaved, aggregate: template.id.rawValue, seq: 0)]
        )
        let loaded = try await store.template(id: template.id)
        #expect(loaded == template)
        #expect(try await store.allTemplates().count == 1)
        #expect(try await store.pendingOperations().map(\.kind) == [.templateDraftSaved])
    }

    @Test func publicationPersistsImmutableVersionAndRefusesDuplicates() async throws {
        let store = try makeStore()
        var template = draftTemplate()
        let v1 = try template.publish(at: t0)
        try await store.publishAtomically(template: template, version: v1, enqueueing: [])
        #expect(try await store.version(id: v1.id) == v1)
        #expect(try await store.versions(templateID: template.id).map(\.versionNumber) == [1])

        // Re-inserting the same (template, versionNumber) violates immutability — the
        // UNIQUE constraint rejects it rather than overwriting a frozen row.
        let duplicate = WorkoutTemplateVersion(
            templateID: template.id, versionNumber: 1,
            content: v1.content, publishedAt: t0.addingTimeInterval(60)
        )
        await #expect(throws: (any Error).self) {
            try await store.publishAtomically(template: template, version: duplicate, enqueueing: [])
        }
        // The frozen row is untouched.
        #expect(try await store.version(id: v1.id) == v1)
    }

    @Test func assignmentRoundTripAcrossReopen() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mazidi-prog-\(UUID().uuidString)", isDirectory: true)
        var template = draftTemplate()
        let version = try template.publish(at: t0)
        let assignment = WorkoutAssignment(version: version, assigneeAccountRef: "dev-client-001", assignedAt: t0)

        do {
            let store = try GRDBStore.open(directory: dir)
            try await store.saveAssignmentAtomically(
                assignment, enqueueing: [op(kind: .assignmentCreated, aggregate: assignment.id.rawValue, seq: 0)]
            )
            try store.close()
        }
        // Relaunch: assignment (with full snapshot) and its queued op survive.
        let reopened = try GRDBStore.open(directory: dir)
        let restored = try await reopened.assignment(id: assignment.id)
        #expect(restored == assignment)
        #expect(restored?.status == .queued) // offline pending state is durable
        #expect(try await reopened.pendingOperations().map(\.kind) == [.assignmentCreated])
        try reopened.close()
    }

    @Test func atomicRollbackAcrossProgrammingWrites() async throws {
        let store = try makeStore()
        var template = draftTemplate()
        let version = try template.publish(at: t0)

        // Injected failure between the domain rows and the outbox insert: nothing lands.
        store.setAtomicWriteHook { throw CocoaError(.fileWriteUnknown) }
        await #expect(throws: (any Error).self) {
            try await store.publishAtomically(
                template: template, version: version,
                enqueueing: [op(kind: .templatePublished, aggregate: template.id.rawValue, seq: 0)]
            )
        }
        store.setAtomicWriteHook(nil)
        #expect(try await store.template(id: template.id) == nil)
        #expect(try await store.version(id: version.id) == nil)
        #expect(try await store.pendingOperations().isEmpty)

        // Same invariant for the assignment-transition write.
        let assignment = WorkoutAssignment(version: version, assigneeAccountRef: "c", assignedAt: t0)
        var started = assignment
        try started.markStarted()
        let workout = try assignment.assignedWorkout()
        var session = WorkoutSession(workout: workout, epoch: 1, assignmentID: assignment.id)
        try session.start(at: t0)
        store.setAtomicWriteHook { throw CocoaError(.fileWriteUnknown) }
        await #expect(throws: (any Error).self) {
            try await store.recordAssignmentTransitionAtomically(
                session: session, assignment: started,
                enqueueing: [op(kind: .assignmentStatusChanged, aggregate: assignment.id.rawValue, seq: 0)]
            )
        }
        store.setAtomicWriteHook(nil)
        #expect(try await store.assignment(id: assignment.id) == nil)
        #expect(try await store.session(id: session.id) == nil)
    }

    @Test func migrationFromV1PreservesExistingWorkoutData() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mazidi-v1v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mazidi-client.sqlite")

        // Build a database at schema v1 ONLY (as a pre-slice install would have), with
        // real session data.
        let v1Only: DatabaseQueue = try DatabaseQueue(path: url.path)
        var v1Migrator = DatabaseMigrator()
        let full = GRDBSchema.migrator()
        // Register just the first migration by re-running the full migrator up to v1.
        v1Migrator = full
        try v1Migrator.migrate(v1Only, upTo: "v1-workout-persistence")
        let squat = AssignedExercise(slug: "barbell-squat", prescription: .repsAndLoad(sets: 3, reps: 5...8, loadKg: 80))
        let workout = AssignedWorkout(title: "Old", programmeVersion: 1, sections: [.main: [squat]])
        var mutableSession = WorkoutSession(workout: workout, epoch: 1)
        try mutableSession.start(at: t0)
        let session = mutableSession
        // Insert with the v1 column set (no assignment_id) — exactly what a pre-slice
        // install would contain on disk.
        let workoutJson = try JSONEncoder().encode(session.workout)
        try await v1Only.write { db in
            try db.execute(
                sql: """
                INSERT INTO workout_session (id, epoch, phase, started_at, completed_at,
                    current_exercise_id, rest_json, workout_json)
                VALUES (?, ?, ?, ?, NULL, NULL, NULL, ?)
                """,
                arguments: [session.id.rawValue.uuidString, session.epoch,
                            session.phase.rawValue, session.startedAt, workoutJson]
            )
        }
        try v1Only.close()

        // Opening through the store applies v2 forward-only; old data intact, new tables usable.
        let store = try GRDBStore.open(directory: dir)
        #expect(store.recovery == .normal(createdNew: false)) // no quarantine — a real migration
        let restored = try await store.session(id: session.id)
        #expect(restored?.workout.title == "Old")
        #expect(restored?.assignmentID == nil) // new column defaults safely
        let template = draftTemplate()
        try await store.saveTemplateAtomically(template, enqueueing: [])
        #expect(try await store.template(id: template.id) != nil)
        try store.close()
    }

    @Test func corruptionRecoveryWithProgrammingTablesStaysAccountScoped() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mazidi-prog-corrupt-\(UUID().uuidString)", isDirectory: true)
        let victimDir = AccountDatabasePath.directory(base: base, accountID: AccountID("acct-a"))
        let bystanderDir = AccountDatabasePath.directory(base: base, accountID: AccountID("acct-b"))

        // Bystander holds programming data.
        let bystander = try GRDBStore.open(directory: bystanderDir)
        let template = draftTemplate()
        try await bystander.saveTemplateAtomically(template, enqueueing: [])
        try bystander.close()

        // Victim's file is garbage → quarantine + fresh, with v2 schema usable.
        try FileManager.default.createDirectory(at: victimDir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: victimDir.appendingPathComponent("mazidi-client.sqlite"))
        let recovered = try GRDBStore.open(directory: victimDir)
        guard case .recoveredAfterQuarantine = recovered.recovery else {
            Issue.record("expected quarantine, got \(recovered.recovery)"); return
        }
        try await recovered.saveTemplateAtomically(draftTemplate(), enqueueing: [])
        try recovered.close()

        // Bystander untouched.
        let reopened = try GRDBStore.open(directory: bystanderDir)
        #expect(try await reopened.template(id: template.id) != nil)
        try reopened.close()
    }

    @Test func closedStoreRefusesProgrammingAccess() async throws {
        let store = try GRDBStore.open(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("mazidi-prog-closed-\(UUID().uuidString)", isDirectory: true)
        )
        let template = draftTemplate()
        try await store.saveTemplateAtomically(template, enqueueing: [])
        try store.close()
        await #expect(throws: (any Error).self) { _ = try await store.allTemplates() }
        await #expect(throws: (any Error).self) { _ = try await store.allAssignments() }
        await #expect(throws: (any Error).self) {
            try await store.saveTemplateAtomically(draftTemplate(), enqueueing: [])
        }
    }
}
