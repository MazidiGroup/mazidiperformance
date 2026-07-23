import Foundation
import MazidiFoundations
import MazidiPersistence

/// Transport abstraction — the real HTTP client (and, until a backend exists, a clearly
/// labelled simulator) implement this. The server contract: apply each idempotency key
/// at most once and return `.acknowledged` on key replay (R-02).
public protocol SyncTransport: Sendable {
    func send(_ operation: SyncOperation) async -> SyncAttemptOutcome
}

/// User-visible sync status (panel 4i): the UI must render these honestly and never
/// claim "synced" while items are pending.
public enum SyncStatus: Sendable, Equatable {
    case idle
    case syncing(remaining: Int)
    case waitingForConnectivity(pending: Int)
    case pausedAuthExpired(pending: Int)
    case attentionNeeded(rejected: Int)
}

/// Replays the durable operation queue: strictly ordered within an aggregate, safe to
/// re-run at any time (idempotency keys make retries harmless), never drops an
/// operation silently (ADR-0003).
public actor SyncEngine {
    private let store: any SyncOperationStore
    private let transport: any SyncTransport
    private let log: AppLog

    public private(set) var status: SyncStatus = .idle

    public init(store: any SyncOperationStore, transport: any SyncTransport, log: AppLog = AppLog(category: "sync")) {
        self.store = store
        self.transport = transport
        self.log = log
    }

    /// Drain pending operations once. Returns the final status. Aggregates are processed
    /// in enqueue order; within an aggregate, a failure stops that aggregate's replay
    /// (ordering guarantee) but other aggregates continue.
    @discardableResult
    public func syncOnce() async throws -> SyncStatus {
        let pending = try await store.pendingOperations()
        guard !pending.isEmpty else {
            status = .idle
            return status
        }
        status = .syncing(remaining: pending.count)

        var rejectedCount = 0
        var sawRetryable = false

        // Group per aggregate, preserving per-aggregate sequence order.
        let grouped = Dictionary(grouping: pending, by: \.aggregateID)
        for (_, ops) in grouped {
            aggregateLoop: for var op in ops.sorted(by: { $0.sequence < $1.sequence }) {
                op.markInFlight()
                try await store.update(op)
                switch await transport.send(op) {
                case .acknowledged:
                    op.markAcknowledged()
                    try await store.update(op)
                case let .retryable(reason):
                    op.markRetryable(reason: reason)
                    try await store.update(op)
                    sawRetryable = true
                    break aggregateLoop // preserve ordering: don't send later ops past a failed one
                case let .terminallyRejected(reason):
                    op.markRejected(reason: reason)
                    try await store.update(op)
                    log.error("Operation \(op.id) terminally rejected: \(reason)")
                    rejectedCount += 1
                    break aggregateLoop // later ops in this aggregate may depend on it — park and surface
                case .authExpired:
                    op.markRetryable(reason: "auth expired")
                    try await store.update(op)
                    let stillPending = try await store.pendingOperations().count
                    status = .pausedAuthExpired(pending: stillPending)
                    return status
                }
            }
        }

        let remaining = try await store.pendingOperations().count
        if rejectedCount > 0 {
            status = .attentionNeeded(rejected: rejectedCount)
        } else if sawRetryable {
            status = .waitingForConnectivity(pending: remaining)
        } else {
            status = remaining == 0 ? .idle : .syncing(remaining: remaining)
        }
        return status
    }
}
