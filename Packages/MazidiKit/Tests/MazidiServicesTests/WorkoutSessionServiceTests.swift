import Foundation
import Testing
@testable import MazidiServices
import MazidiDomain
import MazidiPersistence
import MazidiSync
import MazidiFoundations

private func makeService(store: InMemorySyncStore, clock: FixedClock = FixedClock()) -> WorkoutSessionService {
    WorkoutSessionService(
        store: .init(sessions: store, operations: store, audit: store),
        clock: clock,
        actorID: UUID()
    )
}

private func makeWorkout() -> (AssignedWorkout, AssignedExercise) {
    let squat = AssignedExercise(
        slug: "barbell-squat",
        prescription: .repsAndLoad(sets: 2, reps: 5...8, loadKg: 80),
        approvedAlternatives: ["barbell-bent-over-row"]
    )
    return (AssignedWorkout(title: "Lower A", programmeVersion: 1, sections: [.main: [squat]]), squat)
}

@Suite struct WorkoutSessionServiceTests {
    @Test func everyMutationEnqueuesExactlyOneOrderedOperation() async throws {
        let store = InMemorySyncStore()
        let service = makeService(store: store)
        let (workout, squat) = makeWorkout()

        let session = try await service.start(workout: workout, epoch: 1)
        _ = try await service.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80))
        _ = try await service.recordSet(exerciseID: squat.id, setIndex: 1, value: .repsAndLoad(reps: 6, loadKg: 82.5))
        _ = try await service.complete()

        let ops = try await store.operations(inAggregate: session.id.rawValue)
        #expect(ops.map(\.kind) == [.workoutSessionStarted, .setRecorded, .setRecorded, .workoutSessionCompleted])
        #expect(ops.map(\.sequence) == [0, 1, 2, 3])
        // Distinct idempotency keys per operation.
        #expect(Set(ops.map(\.idempotencyKey)).count == 4)
    }

    @Test func crashDuringAtomicWriteLosesNeitherHalf() async throws {
        let store = InMemorySyncStore()
        let service = makeService(store: store)
        let (workout, squat) = makeWorkout()
        let session = try await service.start(workout: workout, epoch: 1)

        // Simulate power loss at the persist boundary of the next set.
        await store.setFailNextAtomicWrite(true)
        await #expect(throws: (any Error).self) {
            _ = try await service.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80))
        }

        // Invariant (ADR-0003): either both the snapshot and the op exist, or neither.
        let ops = try await store.operations(inAggregate: session.id.rawValue)
        #expect(ops.map(\.kind) == [.workoutSessionStarted]) // no orphan setRecorded op
        let persisted = try await store.session(id: session.id)
        #expect(persisted?.setEntries.isEmpty == true) // no orphan snapshot either
    }

    @Test func restoreAfterRelaunchFindsResumableSession() async throws {
        let store = InMemorySyncStore()
        let (workout, squat) = makeWorkout()
        do {
            let service = makeService(store: store)
            _ = try await service.start(workout: workout, epoch: 1)
            _ = try await service.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80))
            try await service.pause()
        }
        // "Relaunch": a fresh service over the same store (5b).
        let service2 = makeService(store: store)
        let restored = try await service2.restoreIfNeeded()
        #expect(restored != nil)
        #expect(restored?.phase == .paused)
        #expect(restored?.setEntries.count == 1)
    }

    @Test func exitKeepsProgressAndSessionResumable() async throws {
        let store = InMemorySyncStore()
        let (workout, squat) = makeWorkout()
        do {
            let service = makeService(store: store)
            _ = try await service.start(workout: workout, epoch: 1)
            _ = try await service.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80))
            try await service.exit() // 5a/5g "nothing lost"
        }
        // "Relaunch": the exited session is resumable from Today (5b) with its work intact.
        let service2 = makeService(store: store)
        let restored = try await service2.restoreIfNeeded()
        #expect(restored?.phase == .paused)
        #expect(restored?.setEntries.count == 1)
        try await service2.resume()
        let resumed = await service2.currentSession
        #expect(resumed?.phase == .active)
    }

    @Test func discardAbandonsEnqueuesOperationAndKeepsHistory() async throws {
        let store = InMemorySyncStore()
        let service = makeService(store: store)
        let (workout, squat) = makeWorkout()
        let session = try await service.start(workout: workout, epoch: 1)
        _ = try await service.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80))

        try await service.discard()
        let current = await service.currentSession
        #expect(current?.phase == .abandoned)
        #expect(current?.setEntries.count == 1) // history kept, never silently discarded

        // The abandon is a durable, ordered operation like any other mutation (ADR-0003).
        let ops = try await store.operations(inAggregate: session.id.rawValue)
        #expect(ops.map(\.kind) == [.workoutSessionStarted, .setRecorded, .workoutSessionAbandoned])
        #expect(ops.map(\.sequence) == [0, 1, 2])

        // An abandoned session is not offered for resume.
        let service2 = makeService(store: store)
        let restored = try await service2.restoreIfNeeded()
        #expect(restored == nil)
    }

    @Test func completedSessionIsNotResumable() async throws {
        let store = InMemorySyncStore()
        let (workout, _) = makeWorkout()
        let service = makeService(store: store)
        _ = try await service.start(workout: workout, epoch: 1)
        _ = try await service.complete()

        let service2 = makeService(store: store)
        let restored = try await service2.restoreIfNeeded()
        #expect(restored == nil)
    }

    @Test func serverEpochSupersessionIsAuditedAndPreservesData() async throws {
        let store = InMemorySyncStore()
        let service = makeService(store: store)
        let (workout, squat) = makeWorkout()
        _ = try await service.start(workout: workout, epoch: 1)
        _ = try await service.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80))

        try await service.applyServerEpoch(2)
        let current = await service.currentSession
        #expect(current?.phase == .supersededReadOnly)
        #expect(current?.setEntries.count == 1) // recoverable, never discarded

        let audit = try await store.allEvents()
        #expect(audit.map(\.kind).contains(.workoutSessionSuperseded))
    }

    @Test func auditChainLinksEvents() async throws {
        let store = InMemorySyncStore()
        let service = makeService(store: store)
        let (workout, _) = makeWorkout()
        _ = try await service.start(workout: workout, epoch: 1)
        _ = try await service.complete()

        let events = try await store.allEvents()
        #expect(events.count == 2)
        #expect(events[0].previousHash == "0")
        #expect(events[1].previousHash != "0") // chained to predecessor
    }

    @Test func endToEndSyncAfterOfflineWorkout() async throws {
        let store = InMemorySyncStore()
        let service = makeService(store: store)
        let (workout, squat) = makeWorkout()
        let session = try await service.start(workout: workout, epoch: 1)
        _ = try await service.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80))
        _ = try await service.recordSet(exerciseID: squat.id, setIndex: 1, value: .repsAndLoad(reps: 7, loadKg: 80))
        _ = try await service.complete()

        let transport = AlwaysAckTransport()
        let engine = SyncEngine(store: store, transport: transport)
        let status = try await engine.syncOnce()
        #expect(status == .idle)
        let ops = try await store.operations(inAggregate: session.id.rawValue)
        #expect(ops.allSatisfy { $0.status == .acknowledged })
    }
}

private actor AlwaysAckTransport: SyncTransport {
    func send(_ operation: SyncOperation) async -> SyncAttemptOutcome { .acknowledged }
}
