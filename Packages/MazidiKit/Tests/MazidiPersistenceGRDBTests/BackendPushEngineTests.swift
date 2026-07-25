import Foundation
import Testing
import MazidiAuth
import MazidiDomain
import MazidiFoundations
import MazidiNetworking
import MazidiPersistence
import MazidiSync
@testable import MazidiPersistenceGRDB

@Suite struct BackendPushEngineTests {
    private let account = AccountID("dev-client-001")
    private let device = DeviceInstallationID("device-1")
    private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

    private func context() -> AuthenticatedRequestContext {
        AuthenticatedRequestContext(accountID: account, deviceInstallationID: device, generation: 1, accessToken: { "token" })
    }

    /// A fresh in-memory GRDB store that is BOTH the outbox and the BackendSyncStore, so
    /// applyPushResults updates the same rows the engine drained (as in production).
    private func makeStore() throws -> GRDBStore { try GRDBStore.inMemory() }

    private func engine(_ store: GRDBStore, _ backend: FakeSyncBackend,
                        clock: FixedClock, random: @escaping @Sendable () -> Double = { 0 },
                        config: BackendPushConfig = BackendPushConfig()) -> BackendPushEngine {
        BackendPushEngine(outbox: store, syncStore: store, transport: backend, clock: clock, random: random, config: config)
    }

    private func enqueue(_ store: GRDBStore, aggregate: UUID = UUID(), sequence: Int = 0, kind: SyncOperation.Kind = .assignmentCreated) async throws -> SyncOperation {
        let op = SyncOperation(kind: kind, aggregateID: aggregate, sequence: sequence, payload: Data("p".utf8), enqueuedAt: t0)
        try await store.enqueue(op)
        return op
    }

    private func pending(_ store: GRDBStore) async throws -> [SyncOperation] { try await store.pendingOperations() }

    // (b) Idempotent retry: a retried op reuses the SAME mutation id — no duplicate.
    @Test func idempotentRetryReusesTheSameMutationIDAndAcknowledgesOnce() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        let op = try await enqueue(store)
        let mid = MutationID(IdempotencyKey(op.idempotencyKey))

        await backend.setPushResult(.needsRetry(TransportRetry(retryAfter: nil)), for: mid)
        _ = try await engine(store, backend, clock: clock).pushOnce(context: context())
        #expect(try await pending(store).first?.status == .pending)         // still queued
        #expect(try await store.remoteRecordState(entityType: "workoutAssignment", localID: op.aggregateID.uuidString) == nil)

        clock.advance(by: 1000)                                             // past backoff
        await backend.setPushResult(.applied(ServerRecordVersion(1)), for: mid)
        _ = try await engine(store, backend, clock: clock).pushOnce(context: context())

        #expect(try await pending(store).isEmpty)                          // acknowledged → out of queue
        let seen = await backend.pushedMutationIDs
        #expect(seen == [mid, mid])                                        // same deterministic id both times
    }

    // (b/j) Success removes the op in the SAME transaction that records the server version.
    @Test func acknowledgementRemovesOpAndRecordsServerVersionAtomically() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        let op = try await enqueue(store)
        await backend.setPushResult(.applied(ServerRecordVersion(7)), for: MutationID(IdempotencyKey(op.idempotencyKey)))
        _ = try await engine(store, backend, clock: clock).pushOnce(context: context())

        #expect(try await pending(store).isEmpty)                          // op gone from replay
        let remote = try #require(try await store.remoteRecordState(entityType: "workoutAssignment", localID: op.aggregateID.uuidString))
        #expect(remote.serverVersion == 7)                                 // version recorded together
    }

    // Partial acknowledgement: applied / rejected / retry in one batch.
    @Test func partialBatchAcknowledgement() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        let a = try await enqueue(store); let b = try await enqueue(store); let c = try await enqueue(store)
        await backend.setPushResult(.applied(ServerRecordVersion(1)), for: MutationID(IdempotencyKey(a.idempotencyKey)))
        await backend.setPushResult(.rejected(.validationFailed("bad")), for: MutationID(IdempotencyKey(b.idempotencyKey)))
        await backend.setPushResult(.needsRetry(TransportRetry(retryAfter: nil)), for: MutationID(IdempotencyKey(c.idempotencyKey)))

        let summary = try await engine(store, backend, clock: clock).pushOnce(context: context())
        #expect(summary.attempted == 3)
        #expect(summary.acknowledged == 1)
        #expect(summary.deadLettered == 1)
        #expect(summary.retried == 1)
        #expect(!summary.transportFailed)

        // a acknowledged (out), b dead-lettered (parked, present), c pending.
        let stillPending = try await pending(store).map(\.aggregateID)
        #expect(!stillPending.contains(a.aggregateID))
        #expect(stillPending.contains(c.aggregateID))
        let rejected = try await store.operations(inAggregate: b.aggregateID)
        #expect(rejected.first?.status == .rejected)                       // permanent → dead-letter, not dropped
        #expect(rejected.first?.lastError?.contains("validation failed") == true)
    }

    // (permanent) Dead-lettered ops are never deleted.
    @Test func permanentRejectionIsParkedNotDropped() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        let op = try await enqueue(store)
        await backend.setPushResult(.rejected(.forbidden), for: MutationID(IdempotencyKey(op.idempotencyKey)))
        _ = try await engine(store, backend, clock: clock).pushOnce(context: context())
        let row = try await store.operations(inAggregate: op.aggregateID).first
        #expect(row?.status == .rejected)
        #expect(try await pending(store).isEmpty)                          // not pending, but still present
        #expect(row != nil)
    }

    // Stale/unknown ack is a safe no-op: no result for our mutation → keep queued.
    @Test func missingAckKeepsOperationQueuedSafely() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        let op = try await enqueue(store)
        // Configure a result for an UNKNOWN mutation id only; our op gets no ack entry.
        await backend.setPushResult(.applied(ServerRecordVersion(9)), for: MutationID(IdempotencyKey(UUID())))
        let summary = try await engine(store, backend, clock: clock).pushOnce(context: context())
        #expect(summary.retried == 1)
        #expect(try await pending(store).first?.status == .pending)        // never assumed applied
        #expect(try await store.remoteRecordState(entityType: "workoutAssignment", localID: op.aggregateID.uuidString) == nil)
    }

    // Retry-after honored exactly (overrides exponential).
    @Test func serverRetryAfterIsHonoredExactly() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        let op = try await enqueue(store)
        await backend.setPushResult(.needsRetry(TransportRetry(retryAfter: 90)), for: MutationID(IdempotencyKey(op.idempotencyKey)))
        _ = try await engine(store, backend, clock: clock).pushOnce(context: context())
        let row = try #require(try await store.operations(inAggregate: op.aggregateID).first)
        #expect(row.nextAttemptAt == t0.addingTimeInterval(90))
    }

    // Exponential backoff with the injected clock (no sleeps), jitter disabled (random=0).
    @Test func exponentialBackoffUsesInjectedClockDeterministically() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        let op = try await enqueue(store)
        let mid = MutationID(IdempotencyKey(op.idempotencyKey))
        await backend.setPushResult(.needsRetry(TransportRetry(retryAfter: nil)), for: mid)

        // Drain 1: attempt 1 → base(2) * 2^0 = 2s.
        _ = try await engine(store, backend, clock: clock).pushOnce(context: context())
        #expect(try await store.operations(inAggregate: op.aggregateID).first?.nextAttemptAt == t0.addingTimeInterval(2))

        // Drain 2 after it becomes due: attempt 2 → 2 * 2^1 = 4s.
        clock.advance(by: 2)
        _ = try await engine(store, backend, clock: clock).pushOnce(context: context())
        #expect(try await store.operations(inAggregate: op.aggregateID).first?.nextAttemptAt == clock.now().addingTimeInterval(4))
    }

    // Bounded work per drain.
    @Test func batchSizeLimitBoundsWorkPerDrain() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        for _ in 0..<3 { _ = try await enqueue(store) }                    // 3 aggregates
        for id in [UUID()] { _ = id }                                      // (noop)
        let config = BackendPushConfig(maxBatchSize: 2)
        // Everything the fake sees → applied.
        // (Configure lazily by defaulting: unconfigured → no ack → retried; so configure all.)
        for op in try await pending(store) {
            await backend.setPushResult(.applied(ServerRecordVersion(1)), for: MutationID(IdempotencyKey(op.idempotencyKey)))
        }
        let summary = try await engine(store, backend, clock: clock, config: config).pushOnce(context: context())
        #expect(summary.attempted == 2)                                    // only 2 uploaded
        #expect(try await pending(store).count == 1)                       // one left for the next drain
    }

    // Per-aggregate ordering: only the earliest op of an aggregate is sent per drain.
    @Test func perAggregateOrderingSendsEarliestFirst() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        let aggregate = UUID()
        let first = try await enqueue(store, aggregate: aggregate, sequence: 0)
        _ = try await enqueue(store, aggregate: aggregate, sequence: 1)
        await backend.setPushResult(.applied(ServerRecordVersion(1)), for: MutationID(IdempotencyKey(first.idempotencyKey)))

        let summary = try await engine(store, backend, clock: clock).pushOnce(context: context())
        #expect(summary.attempted == 1)                                    // sequence 1 not sent past sequence 0
        let seen = await backend.pushedMutationIDs
        #expect(seen == [MutationID(IdempotencyKey(first.idempotencyKey))])
    }

    // Whole-batch transport failure re-queues with backoff (retry-after honored); nothing dropped.
    @Test func transportFailureRequeuesAllWithBackoff() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        let op = try await enqueue(store)
        await backend.setPushError(.rateLimited(RateLimit(retryAfter: 30)))
        let summary = try await engine(store, backend, clock: clock).pushOnce(context: context())
        #expect(summary.transportFailed)
        #expect(summary.retried == 1)
        let row = try #require(try await store.operations(inAggregate: op.aggregateID).first)
        #expect(row.status == .pending)
        #expect(row.nextAttemptAt == t0.addingTimeInterval(30))            // retry-after honored
    }
}
