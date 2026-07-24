import Foundation
import Testing
import MazidiDomain
import MazidiFoundations
import MazidiSync
@testable import MazidiPersistenceGRDB

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)
private let actor = UUID()

@Suite struct AssignmentDeliveryTests {
    private func makeStore() throws -> GRDBStore { try GRDBStore.inMemory() }

    private func assignment() throws -> WorkoutAssignment {
        var template = WorkoutTemplate(
            draft: WorkoutTemplateContent(title: "Lower A", exercises: [
                PrescribedExercise(slug: "barbell-squat", order: 0, prescription: .repsAndLoad(sets: 3, reps: 5...8, loadKg: 80)),
            ]),
            updatedAt: t0
        )
        let version = try template.publish(at: t0)
        return WorkoutAssignment(version: version, assigneeAccountRef: "dev-client-001", assignedAt: t0)
    }

    private func seed(_ store: GRDBStore) async throws -> WorkoutAssignment {
        let a = try assignment()
        try await store.saveAssignmentAtomically(a, enqueueing: [])
        return a
    }

    // (ii) Delivery ≠ Opened: acceptedByServer sets delivered_at but NOT opened_at, and never
    // touches the execution status. Opening is a separate later event.
    @Test func deliveryIsDistinctFromOpened() async throws {
        let store = try makeStore()
        let a = try await seed(store)
        try await store.advanceAssignmentDelivery(id: a.id, to: .queuedForUpload, at: t0, auditActorID: actor)
        try await store.advanceAssignmentDelivery(id: a.id, to: .acceptedByServer, remoteID: "R1", serverVersion: 3, at: t0.addingTimeInterval(10), auditActorID: actor)

        let d = try #require(try await store.assignmentDelivery(id: a.id))
        #expect(d.deliveryState == "acceptedByServer")
        #expect(d.deliveredAt == t0.addingTimeInterval(10))
        #expect(d.openedAt == nil)                                   // delivered is NOT opened
        #expect(try await store.assignment(id: a.id)?.status == .queued)   // execution status untouched
    }

    // Client receipt is a separate event writing opened_at.
    @Test func clientReceiptWritesOpenedAtSeparately() async throws {
        let store = try makeStore()
        let a = try await seed(store)
        try await store.advanceAssignmentDelivery(id: a.id, to: .queuedForUpload, at: t0, auditActorID: actor)
        try await store.advanceAssignmentDelivery(id: a.id, to: .acceptedByServer, at: t0, auditActorID: actor)
        try await store.advanceAssignmentDelivery(id: a.id, to: .availableToClient, at: t0, auditActorID: actor)
        try await store.advanceAssignmentDelivery(id: a.id, to: .openedByClient, at: t0.addingTimeInterval(99), auditActorID: actor)

        let d = try #require(try await store.assignmentDelivery(id: a.id))
        #expect(d.deliveryState == "openedByClient")
        #expect(d.openedAt == t0.addingTimeInterval(99))
    }

    // The assignmentDelivered audit fires ONLY on acceptedByServer.
    @Test func assignmentDeliveredAuditFiresOnlyOnServerAcceptance() async throws {
        let store = try makeStore()
        let a = try await seed(store)
        try await store.advanceAssignmentDelivery(id: a.id, to: .queuedForUpload, at: t0, auditActorID: actor)
        #expect(try await store.allEvents().contains { $0.kind == .assignmentDelivered } == false)  // not at queued

        try await store.advanceAssignmentDelivery(id: a.id, to: .acceptedByServer, at: t0, auditActorID: actor)
        let delivered = try await store.allEvents().filter { $0.kind == .assignmentDelivered }
        #expect(delivered.count == 1)                                // exactly one, on acceptance
        #expect(delivered.first?.subjectDescription == "assignment:\(a.id.rawValue.uuidString)")

        try await store.advanceAssignmentDelivery(id: a.id, to: .availableToClient, at: t0, auditActorID: actor)
        try await store.advanceAssignmentDelivery(id: a.id, to: .openedByClient, at: t0, auditActorID: actor)
        #expect(try await store.allEvents().filter { $0.kind == .assignmentDelivered }.count == 1)  // still one
    }

    // Illegal transitions are guarded ("Queued" can't jump to "Opened").
    @Test func illegalDeliveryTransitionsAreRejected() async throws {
        let store = try makeStore()
        let a = try await seed(store)
        await #expect(throws: GRDBStore.AssignmentDeliveryError.self) {
            try await store.advanceAssignmentDelivery(id: a.id, to: .openedByClient, at: t0, auditActorID: actor)
        }
        #expect(try await store.assignmentDelivery(id: a.id)?.deliveryState == "createdLocally")  // unchanged
    }

    // (iii) A completed session's history is durable across a later delivery-metadata change.
    @Test func completedHistoryIsDurableAcrossDeliveryMetadataChange() async throws {
        let store = try makeStore()
        let a = try await seed(store)
        // Execute + complete through the existing linkage path.
        var started = a
        try started.markStarted()
        let workout = try a.assignedWorkout()
        var session = WorkoutSession(workout: workout, epoch: 1, assignmentID: a.id)
        try session.start(at: t0)
        try session.complete(at: t0.addingTimeInterval(60))
        var completed = started
        try completed.markCompleted(sessionID: session.id, at: t0.addingTimeInterval(60))
        try await store.recordAssignmentTransitionAtomically(session: session, assignment: completed, enqueueing: [])

        // Later delivery-metadata changes must not rewrite the completion.
        try await store.advanceAssignmentDelivery(id: a.id, to: .queuedForUpload, at: t0.addingTimeInterval(200), auditActorID: actor)
        try await store.advanceAssignmentDelivery(id: a.id, to: .acceptedByServer, at: t0.addingTimeInterval(200), auditActorID: actor)

        let restored = try #require(try await store.assignment(id: a.id))
        #expect(restored.status == .completed)                       // history preserved
        #expect(restored.completedSessionID == session.id)
        #expect(try await store.session(id: session.id)?.phase == .completed)
    }

    // The assignment remains executable after a prior sync (delivery metadata doesn't gate it).
    @Test func assignmentRemainsExecutableAfterDeliveryAdvance() async throws {
        let store = try makeStore()
        let a = try await seed(store)
        try await store.advanceAssignmentDelivery(id: a.id, to: .queuedForUpload, at: t0, auditActorID: actor)
        try await store.advanceAssignmentDelivery(id: a.id, to: .acceptedByServer, at: t0, auditActorID: actor)
        // Still maps to an executable workout with the canonical content.
        let workout = try #require(try await store.assignment(id: a.id)).assignedWorkout()
        #expect(try workout.allExercises.first?.slug == "barbell-squat")
    }
}
