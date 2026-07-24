import Foundation
import Testing
@testable import MazidiSync
import MazidiPersistence
import MazidiFoundations

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

/// Scriptable transport: pops the next outcome per call; records every send.
/// Also models a server idempotency-key store: keys already acknowledged return
/// `.acknowledged` on replay regardless of the script — mirroring the R-02 contract.
private actor ScriptedTransport: SyncTransport {
    private var script: [SyncAttemptOutcome]
    private(set) var sent: [SyncOperation] = []
    private var acknowledgedKeys: Set<UUID> = []

    init(script: [SyncAttemptOutcome]) { self.script = script }

    func send(_ operation: SyncOperation) async -> SyncAttemptOutcome {
        sent.append(operation)
        if acknowledgedKeys.contains(operation.idempotencyKey) {
            return .acknowledged // server-side duplicate prevention by key
        }
        let outcome = script.isEmpty ? .acknowledged : script.removeFirst()
        if case .acknowledged = outcome {
            acknowledgedKeys.insert(operation.idempotencyKey)
        }
        return outcome
    }

    var sentCount: Int { sent.count }
    var uniqueAcknowledgedKeys: Int { acknowledgedKeys.count }
}

private func op(aggregate: UUID, seq: Int, key: UUID = UUID()) -> SyncOperation {
    SyncOperation(
        kind: .setRecorded,
        aggregateID: aggregate,
        sequence: seq,
        idempotencyKey: key,
        payload: Data("payload-\(seq)".utf8),
        enqueuedAt: t0
    )
}

@Suite struct SyncEngineTests {
    @Test func drainsQueueInAggregateOrder() async throws {
        let store = InMemorySyncStore()
        let aggregate = UUID()
        for seq in 0..<3 { try await store.enqueue(op(aggregate: aggregate, seq: seq)) }
        let transport = ScriptedTransport(script: [])
        let engine = SyncEngine(store: store, transport: transport)

        let status = try await engine.syncOnce()
        #expect(status == .idle)
        let sent = await transport.sent
        #expect(sent.map(\.sequence) == [0, 1, 2])
        let pending = try await store.pendingOperations()
        #expect(pending.isEmpty)
    }

    @Test func retryableFailureHaltsAggregateAndPreservesOrder() async throws {
        let store = InMemorySyncStore()
        let aggregate = UUID()
        for seq in 0..<3 { try await store.enqueue(op(aggregate: aggregate, seq: seq)) }
        // First op succeeds, second hits a network error.
        let transport = ScriptedTransport(script: [.acknowledged, .retryable("timeout")])
        let engine = SyncEngine(store: store, transport: transport)

        let status = try await engine.syncOnce()
        #expect(status == .waitingForConnectivity(pending: 2))
        // Op 2 must NOT have been sent past the failed op 1.
        let sent = await transport.sent
        #expect(sent.map(\.sequence) == [0, 1])

        // Reconnection: second pass drains the rest in order.
        let status2 = try await engine.syncOnce()
        #expect(status2 == .idle)
        let allSent = await transport.sent
        #expect(allSent.map(\.sequence) == [0, 1, 1, 2])
    }

    @Test func retryReusesSameIdempotencyKey() async throws {
        let store = InMemorySyncStore()
        let aggregate = UUID()
        let key = UUID()
        try await store.enqueue(op(aggregate: aggregate, seq: 0, key: key))
        let transport = ScriptedTransport(script: [.retryable("offline"), .acknowledged])
        let engine = SyncEngine(store: store, transport: transport)

        _ = try await engine.syncOnce()
        _ = try await engine.syncOnce()
        let sent = await transport.sent
        #expect(sent.count == 2)
        #expect(Set(sent.map(\.idempotencyKey)) == [key]) // retry safety: identical key
    }

    @Test func crashRecoveryResendIsDeduplicatedByServerKeyStore() async throws {
        // Simulates: op sent, server acknowledged, but the client crashed before
        // persisting the ack — op stays inFlight and is resent on next launch.
        let store = InMemorySyncStore()
        let aggregate = UUID()
        let key = UUID()
        var o = op(aggregate: aggregate, seq: 0, key: key)
        try await store.enqueue(o)
        let transport = ScriptedTransport(script: [])
        let engine = SyncEngine(store: store, transport: transport)
        _ = try await engine.syncOnce() // acked server-side

        // Client "lost" the ack: force status back as a fresh launch would see inFlight.
        o.markInFlight()
        try await store.update(o)
        _ = try await engine.syncOnce() // resend happens

        let acknowledged = await transport.uniqueAcknowledgedKeys
        #expect(acknowledged == 1) // server applied the write exactly once
    }

    @Test func terminalRejectionParksOperationAndSurfacesStatus() async throws {
        let store = InMemorySyncStore()
        let aggregate = UUID()
        try await store.enqueue(op(aggregate: aggregate, seq: 0))
        try await store.enqueue(op(aggregate: aggregate, seq: 1))
        let transport = ScriptedTransport(script: [.terminallyRejected("validation failed")])
        let engine = SyncEngine(store: store, transport: transport)

        let status = try await engine.syncOnce()
        #expect(status == .attentionNeeded(rejected: 1))
        // The rejected op is parked (not pending, not dropped); the dependent op waits.
        let inAggregate = try await store.operations(inAggregate: aggregate)
        #expect(inAggregate[0].status == .rejected)
        #expect(inAggregate[0].lastError == "validation failed")
        #expect(inAggregate[1].status == .pending)
    }

    @Test func authExpiryPausesQueueWithoutLosingOperations() async throws {
        let store = InMemorySyncStore()
        let aggregate = UUID()
        for seq in 0..<2 { try await store.enqueue(op(aggregate: aggregate, seq: seq)) }
        let transport = ScriptedTransport(script: [.authExpired])
        let engine = SyncEngine(store: store, transport: transport)

        let status = try await engine.syncOnce()
        #expect(status == .pausedAuthExpired(pending: 2))
        // After "re-auth", everything still replays.
        let status2 = try await engine.syncOnce()
        #expect(status2 == .idle)
    }

    @Test func independentAggregatesDoNotBlockEachOther() async throws {
        let store = InMemorySyncStore()
        let a = UUID(), b = UUID()
        // Enqueue interleaved: a0 (will fail), b0 (should still be attempted).
        try await store.enqueue(op(aggregate: a, seq: 0))
        try await store.enqueue(op(aggregate: b, seq: 0))
        let transport = ScriptedTransport(script: [.retryable("timeout"), .acknowledged])
        let engine = SyncEngine(store: store, transport: transport)

        _ = try await engine.syncOnce()
        let sent = await transport.sent
        // Both aggregates attempted despite a's failure.
        #expect(Set(sent.map(\.aggregateID)) == [a, b])
    }
}
