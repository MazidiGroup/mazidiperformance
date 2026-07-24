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

    @Test func pauseAndResumeAreIdempotent() async throws {
        let store = InMemorySyncStore()
        let service = makeService(store: store)
        let (workout, _) = makeWorkout()
        _ = try await service.start(workout: workout, epoch: 1)

        // Double pause: second call is a silent no-op (M3).
        try await service.pause()
        try await service.pause()
        #expect(await service.currentSession?.phase == .paused)

        // Double resume: second call is a silent no-op (M1).
        try await service.resume()
        try await service.resume()
        #expect(await service.currentSession?.phase == .active)
    }

    @Test func restoredActiveSessionResumesWithoutError() async throws {
        // The app was killed while active; the restored session is still `.active` (M1).
        let store = InMemorySyncStore()
        let (workout, _) = makeWorkout()
        do {
            let service = makeService(store: store)
            _ = try await service.start(workout: workout, epoch: 1)
        }
        let service2 = makeService(store: store)
        let restored = try await service2.restoreIfNeeded()
        #expect(restored?.phase == .active)
        try await service2.resume() // must not throw
        #expect(await service2.currentSession?.phase == .active)
    }

    @Test func positionAndRestSurviveRestore() async throws {
        let store = InMemorySyncStore()
        let clock = FixedClock()
        let (workout, squat) = makeWorkout()
        do {
            let service = makeService(store: store, clock: clock)
            _ = try await service.start(workout: workout, epoch: 1)
            try await service.updateCurrentExercise(squat.id)
            try await service.updateActiveRest(RestTimer(durationSeconds: 120, startedAt: clock.now()))
            try await service.pause()
        }
        // Relaunch 30s later: rest still running → restored with honest remaining time.
        clock.advance(by: 30)
        let service2 = makeService(store: store, clock: clock)
        let restored = try await service2.restoreIfNeeded()
        #expect(restored?.currentExerciseID == squat.id)
        #expect(restored?.activeRest?.remainingSeconds(at: clock.now()) == 90)
    }

    @Test func elapsedRestIsRestoredAsElapsedNotRestarted() async throws {
        let store = InMemorySyncStore()
        let clock = FixedClock()
        let (workout, _) = makeWorkout()
        do {
            let service = makeService(store: store, clock: clock)
            _ = try await service.start(workout: workout, epoch: 1)
            try await service.updateActiveRest(RestTimer(durationSeconds: 60, startedAt: clock.now()))
            try await service.pause()
        }
        // Relaunch well after the rest finished: restored as elapsed (cleared), and the
        // normalisation is persisted so later restores agree.
        clock.advance(by: 300)
        let service2 = makeService(store: store, clock: clock)
        let restored = try await service2.restoreIfNeeded()
        #expect(restored?.activeRest == nil)
        let persisted = try await store.session(id: restored!.id)
        #expect(persisted?.activeRest == nil)
    }

    @Test func restorationMetadataIsIgnoredOnTerminalPhases() async throws {
        let store = InMemorySyncStore()
        let clock = FixedClock()
        let service = makeService(store: store, clock: clock)
        let (workout, squat) = makeWorkout()
        _ = try await service.start(workout: workout, epoch: 1)
        _ = try await service.complete()
        // Completed history is never rewritten by restoration hints.
        try await service.updateCurrentExercise(squat.id)
        try await service.updateActiveRest(RestTimer(durationSeconds: 60, startedAt: clock.now()))
        let current = await service.currentSession
        #expect(current?.currentExerciseID == nil)
        #expect(current?.activeRest == nil)
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
