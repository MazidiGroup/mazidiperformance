import Foundation
import Testing
import GRDB
@testable import MazidiPersistenceGRDB
import MazidiDomain
import MazidiFoundations
import MazidiPersistence
import MazidiSync

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

func makeWorkoutFixture() -> (AssignedWorkout, AssignedExercise, AssignedExercise) {
    let squat = AssignedExercise(
        slug: "barbell-squat",
        prescription: .repsAndLoad(sets: 3, reps: 5...8, loadKg: 80),
        coachCue: "Brace.",
        approvedAlternatives: ["kettlebell-sumo-deadlift"],
        restSeconds: 120
    )
    let chopper = AssignedExercise(
        slug: "band-wood-chopper",
        prescription: .timed(sets: 2, seconds: 40),
        restSeconds: 45
    )
    let workout = AssignedWorkout(
        title: "Lower A", programmeVersion: 1,
        sections: [.warmUp: [chopper], .main: [squat]]
    )
    return (workout, squat, chopper)
}

func op(aggregate: UUID, seq: Int, key: UUID = UUID()) -> SyncOperation {
    SyncOperation(
        kind: .setRecorded,
        aggregateID: aggregate,
        sequence: seq,
        idempotencyKey: key,
        payload: Data("payload-\(seq)".utf8),
        enqueuedAt: t0
    )
}

@Suite struct GRDBStoreTests {
    // MARK: Sessions

    @Test func sessionRoundTripPreservesEverySlice1Field() async throws {
        let store = try GRDBStore.inMemory()
        let (workout, squat, chopper) = makeWorkoutFixture()
        var session = WorkoutSession(workout: workout, epoch: 3)
        try session.start(at: t0)
        _ = try session.recordSet(exerciseID: chopper.id, setIndex: 0, value: .time(seconds: 40), at: t0.addingTimeInterval(60))
        _ = try session.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80), rpe: 8, at: t0.addingTimeInterval(120))
        try session.swapExercise(squat.id, to: "kettlebell-sumo-deadlift")
        session.setCurrentExercise(squat.id)
        session.setActiveRest(RestTimer(durationSeconds: 120, startedAt: t0.addingTimeInterval(120)))
        try session.pause()

        try await store.save(session)
        let loaded = try #require(try await store.session(id: session.id))

        #expect(loaded.id == session.id)
        #expect(loaded.epoch == 3)
        #expect(loaded.phase == .paused)
        #expect(loaded.startedAt == session.startedAt)
        #expect(loaded.workout == workout)
        #expect(loaded.setEntries == session.setEntries) // ids, values, rpe, slugs, keys
        #expect(loaded.swaps == [squat.id: "kettlebell-sumo-deadlift"])
        #expect(loaded.currentExerciseID == squat.id)
        #expect(loaded.activeRest == session.activeRest)
        #expect(loaded.completedAt == nil)
    }

    @Test func resumableSelectionMatchesLifecycleRules() async throws {
        let store = try GRDBStore.inMemory()
        let (workout, _, _) = makeWorkoutFixture()

        // Completed and abandoned sessions are history — never resumable.
        var done = WorkoutSession(workout: workout, epoch: 1)
        try done.start(at: t0)
        try done.complete(at: t0.addingTimeInterval(100))
        try await store.save(done)

        var dropped = WorkoutSession(workout: workout, epoch: 1)
        try dropped.start(at: t0)
        try dropped.abandon()
        try await store.save(dropped)

        #expect(try await store.resumableSession() == nil)

        // A paused (exited) session IS resumable.
        var paused = WorkoutSession(workout: workout, epoch: 2)
        try paused.start(at: t0)
        try paused.exitKeepingProgress()
        try await store.save(paused)

        let resumable = try #require(try await store.resumableSession())
        #expect(resumable.id == paused.id)
        #expect(resumable.phase == .paused)
    }

    @Test func setEntryDuplicateIndexIsRejectedByTheDatabaseToo() async throws {
        // Belt-and-braces (MIGRATIONS.md): the domain already refuses duplicate
        // (exercise, setIndex); the UNIQUE constraint refuses it even for a hypothetical
        // buggy caller writing a *different* entry id for the same logical set.
        let store = try GRDBStore.inMemory()
        let (workout, squat, _) = makeWorkoutFixture()
        var session = WorkoutSession(workout: workout, epoch: 1)
        try session.start(at: t0)
        _ = try session.recordSet(exerciseID: squat.id, setIndex: 0, value: .reps(5), at: t0)
        try await store.save(session)

        let rogue = SetEntry(
            exerciseID: squat.id, performedSlug: "barbell-squat", setIndex: 0,
            value: .reps(9), recordedAt: t0
        )
        let sessionID = session.id
        await #expect(throws: (any Error).self) {
            try await store.writer.write { db in
                try SetEntryRecord(entry: rogue, sessionID: sessionID).insert(db)
            }
        }
    }

    // MARK: Outbox constraints & ordering

    @Test func idempotencyKeyIsUniqueInTheDatabase() async throws {
        let store = try GRDBStore.inMemory()
        let key = UUID()
        let aggregate = UUID()
        try await store.enqueue(op(aggregate: aggregate, seq: 0, key: key))
        await #expect(throws: (any Error).self) {
            try await store.enqueue(op(aggregate: aggregate, seq: 1, key: key))
        }
    }

    @Test func aggregateSequenceIsUniqueAndOrdered() async throws {
        let store = try GRDBStore.inMemory()
        let a = UUID(), b = UUID()
        // Interleaved enqueue across aggregates, out-of-order write order within b.
        try await store.enqueue(op(aggregate: a, seq: 0))
        try await store.enqueue(op(aggregate: b, seq: 1))
        try await store.enqueue(op(aggregate: a, seq: 1))
        try await store.enqueue(op(aggregate: b, seq: 0))

        #expect(try await store.operations(inAggregate: a).map(\.sequence) == [0, 1])
        #expect(try await store.operations(inAggregate: b).map(\.sequence) == [0, 1])
        #expect(try await store.nextSequence(forAggregate: a) == 2)

        // Duplicate (aggregate, sequence) violates ordering integrity → rejected.
        await #expect(throws: (any Error).self) {
            try await store.enqueue(op(aggregate: a, seq: 1))
        }
    }

    @Test func pendingScanKeepsEnqueueOrderAndExcludesSettledOperations() async throws {
        let store = try GRDBStore.inMemory()
        let aggregate = UUID()
        var first = op(aggregate: aggregate, seq: 0)
        var second = op(aggregate: aggregate, seq: 1)
        let third = op(aggregate: aggregate, seq: 2)
        try await store.enqueue(first)
        try await store.enqueue(second)
        try await store.enqueue(third)

        first.markInFlight()
        first.markAcknowledged()
        try await store.update(first)
        second.markInFlight() // ambiguous — stays replayable
        try await store.update(second)

        let pending = try await store.pendingOperations()
        #expect(pending.map(\.sequence) == [1, 2])
        #expect(pending.first?.status == .inFlight)

        // Settled rows are excluded from the scan but never deleted.
        let all = try await store.operations(inAggregate: aggregate)
        #expect(all.count == 3)
        #expect(all[0].status == .acknowledged)
    }

    @Test func statusRetryAndErrorMetadataRoundTrip() async throws {
        let store = try GRDBStore.inMemory()
        let aggregate = UUID()
        var rejected = op(aggregate: aggregate, seq: 0)
        rejected.markInFlight()
        rejected.markRetryable(reason: "timeout")
        rejected.markInFlight()
        rejected.markRejected(reason: "validation failed")
        try await store.enqueue(op(aggregate: aggregate, seq: 1)) // unrelated pending
        try await store.update(rejected) // insert-or-update path

        let all = try await store.operations(inAggregate: aggregate)
        let loaded = try #require(all.first { $0.sequence == 0 })
        #expect(loaded.status == .rejected)
        #expect(loaded.attemptCount == 2)
        #expect(loaded.lastError == "validation failed")
        #expect(loaded.idempotencyKey == rejected.idempotencyKey)
    }

    // MARK: Atomicity (ADR-0003)

    @Test func atomicSaveCommitsBothHalves() async throws {
        let store = try GRDBStore.inMemory()
        let (workout, squat, _) = makeWorkoutFixture()
        var session = WorkoutSession(workout: workout, epoch: 1)
        try session.start(at: t0)
        _ = try session.recordSet(exerciseID: squat.id, setIndex: 0, value: .reps(5), at: t0)

        try await store.saveAtomically(
            session: session,
            enqueueing: [op(aggregate: session.id.rawValue, seq: 0)]
        )
        #expect(try await store.session(id: session.id) != nil)
        #expect(try await store.operations(inAggregate: session.id.rawValue).count == 1)
    }

    @Test func injectedFailureBetweenSessionWriteAndEnqueueRollsBackBoth() async throws {
        struct SimulatedCrash: Error {}
        let store = try GRDBStore.inMemory()
        let (workout, _, _) = makeWorkoutFixture()
        var session = WorkoutSession(workout: workout, epoch: 1)
        try session.start(at: t0)

        // Throw INSIDE the transaction, after the session rows, before the outbox rows.
        store.setAtomicWriteHook { throw SimulatedCrash() }
        await #expect(throws: (any Error).self) {
            try await store.saveAtomically(
                session: session,
                enqueueing: [op(aggregate: session.id.rawValue, seq: 0)]
            )
        }
        store.setAtomicWriteHook(nil)

        // The invariant: neither half persisted.
        #expect(try await store.session(id: session.id) == nil)
        #expect(try await store.operations(inAggregate: session.id.rawValue).isEmpty)
        #expect(try await store.pendingOperations().isEmpty)
    }

    // MARK: Audit (ADR-0006)

    @Test func auditEventsPersistWithChainAndOrder() async throws {
        let store = try GRDBStore.inMemory()
        let actor = UUID()
        #expect(try await store.latestHash() == "0") // genesis

        let first = AuditEvent(
            kind: .workoutSessionStarted, actorID: actor,
            subjectDescription: "workoutSession:x", occurredAt: t0,
            previousHash: try await store.latestHash(),
            payload: ["k": "v"]
        )
        try await store.append(first)
        let hashAfterFirst = try await store.latestHash()
        #expect(hashAfterFirst == auditChainHash(of: first))

        let second = AuditEvent(
            kind: .workoutSessionCompleted, actorID: actor,
            subjectDescription: "workoutSession:x", occurredAt: t0.addingTimeInterval(60),
            previousHash: hashAfterFirst
        )
        try await store.append(second)

        let events = try await store.allEvents()
        #expect(events.map(\.kind) == [.workoutSessionStarted, .workoutSessionCompleted])
        #expect(events[1].previousHash == auditChainHash(of: events[0])) // chain intact
        #expect(events[0].payload == ["k": "v"])
    }

    // MARK: Behavioural parity with the reference store (ADR-0002 contract)

    @Test func grdbAndInMemoryStoresAgreeOnCoreContract() async throws {
        // The same script must produce identical observable results on both stores.
        func run(_ sessions: any WorkoutSessionRepository,
                 _ outbox: any SyncOperationStore<SyncOperation>) async throws -> (Int, [Int], Int, String?) {
            let (workout, squat, _) = makeWorkoutFixture()
            var session = WorkoutSession(workout: workout, epoch: 1)
            try session.start(at: t0)
            _ = try session.recordSet(exerciseID: squat.id, setIndex: 0, value: .reps(5), at: t0)
            let aggregate = session.id.rawValue
            let seq0 = try await outbox.nextSequence(forAggregate: aggregate)
            try await outbox.saveAtomically(session: session, enqueueing: [op(aggregate: aggregate, seq: seq0)])
            try await outbox.enqueue(op(aggregate: aggregate, seq: 1))
            let pending = try await outbox.pendingOperations()
            let restored = try await sessions.resumableSession()
            return (
                pending.count,
                try await outbox.operations(inAggregate: aggregate).map(\.sequence),
                try await outbox.nextSequence(forAggregate: aggregate),
                restored?.phase.rawValue
            )
        }
        let memory = InMemorySyncStore()
        let grdb = try GRDBStore.inMemory()
        let memoryResult = try await run(memory, memory)
        let grdbResult = try await run(grdb, grdb)
        #expect(memoryResult == grdbResult)
    }
}
