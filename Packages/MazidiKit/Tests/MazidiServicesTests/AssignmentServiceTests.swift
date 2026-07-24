import Foundation
import Testing
@testable import MazidiServices
import MazidiDomain
import MazidiPersistence
import MazidiSync
import MazidiFoundations

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

private func makeService(store: InMemorySyncStore, clock: FixedClock = FixedClock()) -> WorkoutSessionService {
    WorkoutSessionService(
        store: .init(sessions: store, operations: store, audit: store, programming: store),
        clock: clock,
        actorID: UUID()
    )
}

private func publishedAssignment() throws -> (WorkoutTemplate, WorkoutAssignment) {
    var template = WorkoutTemplate(
        draft: WorkoutTemplateContent(title: "Lower A", exercises: [
            PrescribedExercise(
                slug: "barbell-squat", order: 0,
                prescription: .repsAndLoad(sets: 2, reps: 5...8, loadKg: 80)
            ),
        ]),
        updatedAt: t0
    )
    let version = try template.publish(at: t0)
    return (template, WorkoutAssignment(version: version, assigneeAccountRef: "dev-client-001", assignedAt: t0))
}

@Suite struct AssignmentServiceTests {
    @Test func startingAnAssignmentSeedsSessionAndTransitionsAtomically() async throws {
        let store = InMemorySyncStore()
        let (_, assignment) = try publishedAssignment()
        try await store.saveAssignmentAtomically(assignment, enqueueing: [])
        let service = makeService(store: store)

        let session = try await service.startAssignment(assignment, epoch: 1)
        #expect(session.assignmentID == assignment.id)
        #expect(session.workout.title == "Lower A")
        // Assignment transitioned and persisted.
        #expect(try await store.assignment(id: assignment.id)?.status == .started)
        // Both operations queued (session start + assignment status).
        let kinds = try await store.pendingOperations().map(\.kind)
        #expect(kinds.contains(.workoutSessionStarted))
        #expect(kinds.contains(.assignmentStatusChanged))
        // Audit: session start + assignment start, chained.
        let audit = try await store.allEvents().map(\.kind)
        #expect(audit.contains(.workoutSessionStarted))
        #expect(audit.contains(.assignmentStarted))
    }

    @Test func executionNeverMutatesTheAssignmentPrescription() async throws {
        let store = InMemorySyncStore()
        let (_, assignment) = try publishedAssignment()
        try await store.saveAssignmentAtomically(assignment, enqueueing: [])
        let service = makeService(store: store)

        let session = try await service.startAssignment(assignment, epoch: 1)
        let exercise = session.workout.allExercises[0]
        _ = try await service.recordSet(
            exerciseID: exercise.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 85)
        )
        let stored = try await store.assignment(id: assignment.id)
        #expect(stored?.content == assignment.content) // prescription snapshot untouched
    }

    @Test func completionLinksAssignmentToSessionAtomically() async throws {
        let store = InMemorySyncStore()
        let (_, assignment) = try publishedAssignment()
        try await store.saveAssignmentAtomically(assignment, enqueueing: [])
        let clock = FixedClock(t0)
        let service = makeService(store: store, clock: clock)

        let session = try await service.startAssignment(assignment, epoch: 1)
        clock.advance(by: 1800)
        _ = try await service.complete()

        let stored = try await store.assignment(id: assignment.id)
        #expect(stored?.status == .completed)
        #expect(stored?.completedSessionID == session.id)
        #expect(stored?.completedAt == t0.addingTimeInterval(1800))
        let audit = try await store.allEvents().map(\.kind)
        #expect(audit.contains(.assignmentCompleted))
    }

    @Test func relaunchCannotDuplicateCompletion() async throws {
        let store = InMemorySyncStore()
        let (_, assignment) = try publishedAssignment()
        try await store.saveAssignmentAtomically(assignment, enqueueing: [])

        // First run completes normally.
        let service1 = makeService(store: store)
        let session1 = try await service1.startAssignment(assignment, epoch: 1)
        _ = try await service1.complete()

        // "Relaunch": a fresh service starts the SAME assignment again (stale UI replay)
        // and completes — the session completes, but the assignment's completion record
        // still points at the first session and is not rewritten.
        let refreshed = try await store.assignment(id: assignment.id)
        var replay = refreshed! // completed
        // A replayed start on a completed assignment is refused at the domain level:
        #expect(throws: WorkoutAssignment.TransitionError.self) { try replay.markStarted() }

        // And even a session that still carries the assignment id cannot double-complete:
        let service2 = makeService(store: store)
        let workout = try assignment.assignedWorkout()
        _ = try await service2.start(workout: workout, epoch: 2) // plain session fallback
        _ = try await service2.complete()
        let after = try await store.assignment(id: assignment.id)
        #expect(after?.status == .completed)
        #expect(after?.completedSessionID == session1.id) // unchanged — no duplication
    }

    @Test func offlineAssignmentStaysQueuedWithPendingOperations() async throws {
        let store = InMemorySyncStore()
        let (_, assignment) = try publishedAssignment()
        try await store.saveAssignmentAtomically(
            assignment,
            enqueueing: [SyncOperation(
                kind: .assignmentCreated,
                aggregateID: assignment.id.rawValue,
                sequence: 0,
                payload: Data("a".utf8),
                enqueuedAt: t0
            )]
        )
        // Nothing has acknowledged the op: the honest state is queued + pending, never
        // "delivered" (ADR-0009).
        #expect(try await store.assignment(id: assignment.id)?.status == .queued)
        #expect(try await store.pendingOperations().map(\.kind) == [.assignmentCreated])
    }

    @Test func startAssignmentWithoutProgrammingStoreFailsTyped() async throws {
        let store = InMemorySyncStore()
        let (_, assignment) = try publishedAssignment()
        let service = WorkoutSessionService(
            store: .init(sessions: store, operations: store, audit: store, programming: nil),
            clock: FixedClock(),
            actorID: UUID()
        )
        await #expect(throws: WorkoutSessionService.ServiceError.programmingUnavailable) {
            _ = try await service.startAssignment(assignment, epoch: 1)
        }
    }
}
