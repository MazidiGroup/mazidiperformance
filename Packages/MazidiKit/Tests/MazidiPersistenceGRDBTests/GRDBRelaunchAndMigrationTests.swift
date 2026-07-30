import Foundation
import Testing
import GRDB
@testable import MazidiPersistenceGRDB
import MazidiDomain
import MazidiFoundations
import MazidiPersistence
import MazidiServices
import MazidiSync

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

/// Unique on-disk location per test — production files are never touched (MIGRATIONS.md).
private func temporaryStoreDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("mazidi-grdb-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

/// Scriptable transport (mirrors the sync test double): pops outcomes; models the R-02
/// server idempotency-key store so replayed keys acknowledge without re-applying.
private actor ScriptedTransport: SyncTransport {
    private var script: [SyncAttemptOutcome]
    private(set) var sent: [SyncOperation] = []
    private var acknowledgedKeys: Set<UUID> = []

    init(script: [SyncAttemptOutcome]) { self.script = script }

    func send(_ operation: SyncOperation) async -> SyncAttemptOutcome {
        sent.append(operation)
        if acknowledgedKeys.contains(operation.idempotencyKey) { return .acknowledged }
        let outcome = script.isEmpty ? .acknowledged : script.removeFirst()
        if case .acknowledged = outcome { acknowledgedKeys.insert(operation.idempotencyKey) }
        return outcome
    }

    var uniqueAcknowledgedKeys: Int { acknowledgedKeys.count }
}

/// Fails every send for one aggregate (retryable), acknowledges all others — independent
/// of the engine's unspecified cross-aggregate processing order.
private actor FailingAggregateTransport: SyncTransport {
    private let failing: UUID
    private(set) var sent: [SyncOperation] = []

    init(failing: UUID) { self.failing = failing }

    func send(_ operation: SyncOperation) async -> SyncAttemptOutcome {
        sent.append(operation)
        return operation.aggregateID == failing ? .retryable("timeout") : .acknowledged
    }
}

private func makeService(store: GRDBStore, clock: FixedClock) -> WorkoutSessionService {
    WorkoutSessionService(
        store: .init(sessions: store, operations: store, audit: store),
        clock: clock,
        actorID: UUID(uuidString: "00000000-0000-0000-0000-0000C11E7700")!
    )
}

@Suite struct GRDBRelaunchTests {
    // MARK: Empty database + repeated launches

    @Test func emptyDatabaseStartupAndRepeatedLaunchesAreStable() async throws {
        let dir = temporaryStoreDirectory()
        // Launch 1: empty database — no resumable session, nothing pending.
        do {
            let store = try GRDBStore.open(directory: dir)
            #expect(try await store.resumableSession() == nil)
            #expect(try await store.pendingOperations().isEmpty)
            #expect(try await store.latestHash() == "0")
        }
        // Launches 2 and 3: reopening is idempotent (migrations already applied).
        for _ in 0..<2 {
            let store = try GRDBStore.open(directory: dir)
            #expect(try await store.resumableSession() == nil)
        }
    }

    // MARK: Full workout relaunch journey through the real service

    @Test func exitedSessionSurvivesRelaunchWithSetsSwapPositionAndRest() async throws {
        let dir = temporaryStoreDirectory()
        let clock = FixedClock(t0)
        let (workout, squat, chopper) = makeWorkoutFixture()
        var sessionID: Identifier<WorkoutSession>?

        // "Launch 1": start, record, swap, note position + rest, exit. Store goes away
        // with the scope — like process termination.
        do {
            let store = try GRDBStore.open(directory: dir)
            let service = makeService(store: store, clock: clock)
            let session = try await service.start(workout: workout, epoch: 1)
            sessionID = session.id
            _ = try await service.recordSet(exerciseID: chopper.id, setIndex: 0, value: .time(seconds: 40))
            _ = try await service.recordSet(exerciseID: squat.id, setIndex: 0, value: .repsAndLoad(reps: 6, loadKg: 80))
            try await service.swapExercise(squat.id, to: "kettlebell-sumo-deadlift")
            try await service.updateCurrentExercise(squat.id)
            try await service.updateActiveRest(RestTimer(durationSeconds: 120, startedAt: clock.now()))
            try await service.exit()
        }

        // "Launch 2", 30 seconds later: everything restores; rest continues honestly.
        clock.advance(by: 30)
        do {
            let store = try GRDBStore.open(directory: dir)
            let service = makeService(store: store, clock: clock)
            let restored = try #require(try await service.restoreIfNeeded())
            #expect(restored.id == sessionID)
            #expect(restored.phase == .paused)
            #expect(restored.setEntries.count == 2)
            #expect(restored.swaps == [squat.id: "kettlebell-sumo-deadlift"])
            #expect(restored.currentExerciseID == squat.id)
            #expect(restored.activeRest?.remainingSeconds(at: clock.now()) == 90)

            // Duplicate prevention survives relaunch: same (exercise, set index) refused.
            try await service.resume()
            await #expect(throws: (any Error).self) {
                _ = try await service.recordSet(exerciseID: squat.id, setIndex: 0, value: .reps(9))
            }
            // The next honest index still works.
            _ = try await service.recordSet(exerciseID: squat.id, setIndex: 1, value: .repsAndLoad(reps: 6, loadKg: 82.5))
        }
    }

    @Test func restThatElapsedWhileClosedRestoresAsElapsed() async throws {
        let dir = temporaryStoreDirectory()
        let clock = FixedClock(t0)
        let (workout, _, chopper) = makeWorkoutFixture()
        do {
            let store = try GRDBStore.open(directory: dir)
            let service = makeService(store: store, clock: clock)
            _ = try await service.start(workout: workout, epoch: 1)
            _ = try await service.recordSet(exerciseID: chopper.id, setIndex: 0, value: .time(seconds: 40))
            try await service.updateActiveRest(RestTimer(durationSeconds: 45, startedAt: clock.now()))
            try await service.exit()
        }
        clock.advance(by: 600) // long after the rest finished
        do {
            let store = try GRDBStore.open(directory: dir)
            let service = makeService(store: store, clock: clock)
            let restored = try #require(try await service.restoreIfNeeded())
            #expect(restored.activeRest == nil) // elapsed, not restarted
            #expect(restored.setEntries.count == 1) // and no data lost
        }
    }

    @Test func completedAndAbandonedSessionsAreNotResumableAfterRelaunch() async throws {
        let dir = temporaryStoreDirectory()
        let clock = FixedClock(t0)
        let (workout, _, chopper) = makeWorkoutFixture()
        do {
            let store = try GRDBStore.open(directory: dir)
            let service = makeService(store: store, clock: clock)
            _ = try await service.start(workout: workout, epoch: 1)
            _ = try await service.recordSet(exerciseID: chopper.id, setIndex: 0, value: .time(seconds: 40))
            _ = try await service.complete()
        }
        do {
            let store = try GRDBStore.open(directory: dir)
            let service = makeService(store: store, clock: clock)
            #expect(try await service.restoreIfNeeded() == nil)

            // A discarded session is equally non-resumable after another relaunch.
            _ = try await service.start(workout: workout, epoch: 2)
            try await service.discard()
        }
        do {
            let store = try GRDBStore.open(directory: dir)
            let service = makeService(store: store, clock: clock)
            #expect(try await service.restoreIfNeeded() == nil)
            // History rows are preserved, not deleted.
            #expect(try await store.allSessions().count == 2)
        }
    }

    // MARK: Outbox recovery across relaunch (ADR-0003)

    @Test func pendingAndInFlightOperationsReplayAfterRelaunchWithSameKeys() async throws {
        let dir = temporaryStoreDirectory()
        let aggregate = UUID()
        let keys = [UUID(), UUID(), UUID()]
        do {
            let store = try GRDBStore.open(directory: dir)
            for (seq, key) in keys.enumerated() {
                try await store.enqueue(op(aggregate: aggregate, seq: seq, key: key))
            }
            // Op 0 acknowledged; op 1 in flight when the "app died"; op 2 pending.
            var ops = try await store.operations(inAggregate: aggregate)
            ops[0].markInFlight(); ops[0].markAcknowledged()
            try await store.update(ops[0])
            ops[1].markInFlight()
            try await store.update(ops[1])
        }
        // Relaunch: engine drains — acknowledged op NOT resent; 1 and 2 replay in order
        // with their original idempotency keys.
        do {
            let store = try GRDBStore.open(directory: dir)
            let transport = ScriptedTransport(script: [])
            let engine = SyncEngine(store: store, transport: transport)
            let status = try await engine.syncOnce()
            #expect(status == .idle)
            let sent = await transport.sent
            #expect(sent.map(\.sequence) == [1, 2])
            #expect(sent.map(\.idempotencyKey) == [keys[1], keys[2]])
            let all = try await store.operations(inAggregate: aggregate)
            #expect(all.allSatisfy { $0.status == .acknowledged })
        }
    }

    @Test func rejectedOperationsStayParkedAcrossRelaunch() async throws {
        let dir = temporaryStoreDirectory()
        let aggregate = UUID()
        do {
            let store = try GRDBStore.open(directory: dir)
            try await store.enqueue(op(aggregate: aggregate, seq: 0))
            try await store.enqueue(op(aggregate: aggregate, seq: 1))
            let transport = ScriptedTransport(script: [.terminallyRejected("validation failed")])
            let engine = SyncEngine(store: store, transport: transport)
            let status = try await engine.syncOnce()
            #expect(status == .attentionNeeded(rejected: 1))
        }
        do {
            let store = try GRDBStore.open(directory: dir)
            let all = try await store.operations(inAggregate: aggregate)
            #expect(all[0].status == .rejected)          // parked, visible
            #expect(all[0].lastError == "validation failed")
            #expect(all[1].status == .pending)           // dependent op still waiting

            // The parked operation is not silently retried; the dependent one replays.
            let transport = ScriptedTransport(script: [])
            let engine = SyncEngine(store: store, transport: transport)
            _ = try await engine.syncOnce()
            let sent = await transport.sent
            #expect(sent.map(\.sequence) == [1])
        }
    }

    @Test func authExpiryStateIsReconstructedHonestlyAfterRelaunch() async throws {
        let dir = temporaryStoreDirectory()
        let aggregate = UUID()
        do {
            let store = try GRDBStore.open(directory: dir)
            for seq in 0..<2 { try await store.enqueue(op(aggregate: aggregate, seq: seq)) }
            let transport = ScriptedTransport(script: [.authExpired])
            let engine = SyncEngine(store: store, transport: transport)
            let status = try await engine.syncOnce()
            #expect(status == .pausedAuthExpired(pending: 2))
        }
        // Relaunch while still signed out: the queue reports paused again — never synced.
        do {
            let store = try GRDBStore.open(directory: dir)
            let transport = ScriptedTransport(script: [.authExpired])
            let engine = SyncEngine(store: store, transport: transport)
            let status = try await engine.syncOnce()
            #expect(status == .pausedAuthExpired(pending: 2))
        }
        // Re-auth on a later launch: everything drains with original ordering.
        do {
            let store = try GRDBStore.open(directory: dir)
            let transport = ScriptedTransport(script: [])
            let engine = SyncEngine(store: store, transport: transport)
            #expect(try await engine.syncOnce() == .idle)
            let sent = await transport.sent
            #expect(sent.map(\.sequence) == [0, 1])
        }
    }

    @Test func multipleAggregatesReplayIndependentlyAfterRelaunch() async throws {
        let dir = temporaryStoreDirectory()
        let a = UUID(), b = UUID()
        do {
            let store = try GRDBStore.open(directory: dir)
            try await store.enqueue(op(aggregate: a, seq: 0))
            try await store.enqueue(op(aggregate: b, seq: 0))
            try await store.enqueue(op(aggregate: a, seq: 1))
        }
        do {
            let store = try GRDBStore.open(directory: dir)
            // Aggregate a fails retryably; b must still drain (independence), and a's
            // later op must NOT be sent past its failed predecessor (ordering). The
            // failure targets the aggregate, not a call position — cross-aggregate
            // processing order is deliberately unspecified.
            let transport = FailingAggregateTransport(failing: a)
            let engine = SyncEngine(store: store, transport: transport)
            _ = try await engine.syncOnce()
            let sent = await transport.sent
            let aSent = sent.filter { $0.aggregateID == a }.map(\.sequence)
            let bSent = sent.filter { $0.aggregateID == b }.map(\.sequence)
            #expect(aSent == [0])   // halted at the failure, seq 1 never sent past it
            #expect(bSent == [0])   // unaffected aggregate drained
            let bOps = try await store.operations(inAggregate: b)
            #expect(bOps.allSatisfy { $0.status == .acknowledged })
        }
    }

    @Test func auditChainSurvivesRelaunch() async throws {
        let dir = temporaryStoreDirectory()
        let actor = UUID()
        var expectedHash = "0"
        do {
            let store = try GRDBStore.open(directory: dir)
            let event = AuditEvent(
                kind: .workoutSessionStarted, actorID: actor,
                subjectDescription: "workoutSession:y", occurredAt: t0, previousHash: "0"
            )
            try await store.append(event)
            expectedHash = auditChainHash(of: event)
        }
        do {
            let store = try GRDBStore.open(directory: dir)
            #expect(try await store.latestHash() == expectedHash)
            // New events chain onto the persisted head after relaunch.
            let next = AuditEvent(
                kind: .workoutSessionCompleted, actorID: actor,
                subjectDescription: "workoutSession:y",
                occurredAt: t0.addingTimeInterval(10),
                previousHash: try await store.latestHash()
            )
            try await store.append(next)
            let events = try await store.allEvents()
            #expect(events.count == 2)
            #expect(events[1].previousHash == expectedHash)
        }
    }
}

@Suite struct GRDBMigrationTests {
    @Test func initialMigrationCreatesTheDocumentedSchema() async throws {
        let store = try GRDBStore.inMemory()
        let tables = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'grdb_%' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        }
        #expect(tables == ["audit_event", "exercise_swap", "health_data_consent", "outbox_operation",
                           "relationship", "remote_record", "set_entry", "sync_cursor",
                           "template_version", "workout_assignment", "workout_session",
                           "workout_template"])
        let migrated = try await store.writer.read { db in
            try GRDBSchema.migrator().appliedIdentifiers(db)
        }
        #expect(migrated == ["v1-workout-persistence", "v2-coach-programming",
                             "v3-backend-sync-metadata", "v4-health-data-consent"])
    }

    @Test func forwardMigrationToATestFixturePreservesData() async throws {
        let dir = temporaryStoreDirectory()
        let (workout, _, _) = makeWorkoutFixture()
        var session = WorkoutSession(workout: workout, epoch: 1)
        try session.start(at: t0)

        // Open with v1 only and write real data.
        do {
            let store = try GRDBStore.open(directory: dir)
            try await store.save(session)
        }

        // "Next app version": current schema + a test fixture. Forward-only, non-destructive.
        var upgradedMigrator = GRDBSchema.migrator()
        upgradedMigrator.registerMigration("v3-test-fixture") { db in
            try db.alter(table: "workout_session") { t in
                t.add(column: "test_note", .text)
            }
        }
        let migrator = upgradedMigrator
        let url = dir.appendingPathComponent("mazidi-client.sqlite")
        let pool = try DatabasePool(path: url.path)
        try migrator.migrate(pool)
        let upgraded = GRDBStore(writer: pool)

        // Existing data survived the forward migration; both identifiers applied.
        let loaded = try #require(try await upgraded.session(id: session.id))
        #expect(loaded.phase == .active)
        let applied = try await upgraded.writer.read { db in try migrator.appliedIdentifiers(db) }
        #expect(applied == ["v1-workout-persistence", "v2-coach-programming",
                            "v3-backend-sync-metadata", "v4-health-data-consent", "v3-test-fixture"])
    }

    // MARK: Recovery signal — the four conditions are typed and distinguishable

    @Test func firstLaunchAndNormalReopenReportDistinctNormalConditions() async throws {
        let dir = temporaryStoreDirectory()
        // Genuine first launch: no file existed → normal(createdNew: true).
        do {
            let store = try GRDBStore.open(directory: dir)
            #expect(store.recovery == .normal(createdNew: true))
        }
        // Reopening existing data is NOT a first launch → normal(createdNew: false).
        do {
            let store = try GRDBStore.open(directory: dir)
            #expect(store.recovery == .normal(createdNew: false))
        }
    }

    @Test func unopenableDatabaseIsQuarantinedAndReportedNeverSilentlyEmpty() async throws {
        let dir = temporaryStoreDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mazidi-client.sqlite")
        // Not a database: opening must fail, triggering the quarantine policy.
        let originalBytes = Data("this is not a sqlite database".utf8)
        try originalBytes.write(to: url)

        let store = try GRDBStore.open(directory: dir)
        #expect(try await store.resumableSession() == nil) // fresh, usable database

        // The condition is typed — a fresh-after-quarantine store is never .normal.
        guard case let .recoveredAfterQuarantine(quarantinedPath, reason) = store.recovery else {
            Issue.record("Expected recoveredAfterQuarantine, got \(store.recovery)")
            return
        }
        #expect(reason == .unopenable)
        #expect(quarantinedPath.contains(".corrupt-"))

        // The quarantined file was preserved byte-for-byte, never deleted/overwritten.
        #expect(try Data(contentsOf: URL(fileURLWithPath: quarantinedPath)) == originalBytes)
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents.contains("mazidi-client.sqlite"))

        // A later relaunch of the fresh replacement is normal again (existing data).
        let reopened = try GRDBStore.open(directory: dir)
        #expect(reopened.recovery == .normal(createdNew: false))
    }

    @Test func migrationFailureIsQuarantinedWithTheMigrationCategory() async throws {
        let dir = temporaryStoreDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mazidi-client.sqlite")
        // A VALID SQLite file whose contents make the v1 migration fail (table name
        // collision) — opens fine, migrate throws → category .migrationFailed.
        let sabotage = try DatabaseQueue(path: url.path)
        try await sabotage.write { db in
            try db.execute(sql: "CREATE TABLE workout_session (wrong TEXT)")
        }

        let store = try GRDBStore.open(directory: dir)
        guard case let .recoveredAfterQuarantine(quarantinedPath, reason) = store.recovery else {
            Issue.record("Expected recoveredAfterQuarantine, got \(store.recovery)")
            return
        }
        #expect(reason == .migrationFailed)
        #expect(FileManager.default.fileExists(atPath: quarantinedPath))
        // The replacement is fully migrated and usable.
        #expect(try await store.resumableSession() == nil)
        try await store.enqueue(op(aggregate: UUID(), seq: 0))
        #expect(try await store.pendingOperations().count == 1)
    }
}
