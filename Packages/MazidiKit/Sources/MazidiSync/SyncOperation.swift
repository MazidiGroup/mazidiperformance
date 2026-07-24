import Foundation
import MazidiFoundations
import MazidiNetworking
import MazidiPersistence

/// A durable, replayable mutation record (ADR-0003). Enqueued in the same local transaction
/// as the optimistic state change it describes; replayed in per-aggregate order; applied
/// by the server at most once per idempotency key.
public struct SyncOperation: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case workoutSessionStarted
        case setRecorded
        case exerciseSwapped
        case workoutSessionCompleted
        case workoutSessionAbandoned
        case auditEventAppended
        // Coach programming (ADR-0009): aggregate = template id
        case templateDraftSaved
        case templatePublished
        // Assignments (ADR-0009): aggregate = assignment id
        case assignmentCreated
        case assignmentStatusChanged
    }

    public enum Status: String, Sendable, Codable {
        /// Waiting to be sent (or retried).
        case pending
        /// Sent, awaiting response — after crash, ambiguous ops are safe to resend (idempotent).
        case inFlight
        /// Server acknowledged.
        case acknowledged
        /// Server rejected terminally (validation/authz). Parked, user-visible, never dropped silently.
        case rejected
    }

    public let id: Identifier<SyncOperation>
    public let kind: Kind
    /// Aggregate identity — replay is strictly ordered within one aggregate.
    public let aggregateID: UUID
    /// Monotonic sequence within the aggregate, assigned at enqueue.
    public let sequence: Int
    public let idempotencyKey: UUID
    public let payload: Data
    public let enqueuedAt: Date

    public private(set) var status: Status
    public private(set) var attemptCount: Int
    public private(set) var lastError: String?
    /// Earliest time this operation may be retried (backoff scheduling, ADR-0012 §9).
    /// Nil means "due now". Persisted in `outbox_operation.next_attempt_at`.
    public private(set) var nextAttemptAt: Date?

    public init(
        id: Identifier<SyncOperation> = .init(),
        kind: Kind,
        aggregateID: UUID,
        sequence: Int,
        idempotencyKey: UUID = UUID(),
        payload: Data,
        enqueuedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.aggregateID = aggregateID
        self.sequence = sequence
        self.idempotencyKey = idempotencyKey
        self.payload = payload
        self.enqueuedAt = enqueuedAt
        self.status = .pending
        self.attemptCount = 0
        self.lastError = nil
        self.nextAttemptAt = nil
    }

    /// The typed entity this operation concerns (ADR-0012 §2) — derived from `kind`, so no
    /// column parsing is needed to route or build the mutation envelope.
    public var entityType: SyncEntityType {
        switch kind {
        case .workoutSessionStarted, .workoutSessionCompleted, .workoutSessionAbandoned:
            return .workoutSession
        case .setRecorded: return .setEntry
        case .exerciseSwapped: return .exerciseSwap
        case .auditEventAppended: return .auditEvent
        case .templateDraftSaved, .templatePublished: return .workoutTemplate
        case .assignmentCreated, .assignmentStatusChanged: return .workoutAssignment
        }
    }

    /// Persistence-restoration initializer (ADR-0007): reconstructs an operation in an
    /// arbitrary durable state (status, attempts, last error). Not for feature code —
    /// state changes go through the mark* methods.
    public init(
        restoring id: Identifier<SyncOperation>,
        kind: Kind,
        aggregateID: UUID,
        sequence: Int,
        idempotencyKey: UUID,
        payload: Data,
        enqueuedAt: Date,
        status: Status,
        attemptCount: Int,
        lastError: String?,
        nextAttemptAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.aggregateID = aggregateID
        self.sequence = sequence
        self.idempotencyKey = idempotencyKey
        self.payload = payload
        self.enqueuedAt = enqueuedAt
        self.status = status
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.nextAttemptAt = nextAttemptAt
    }

    public mutating func markInFlight() {
        status = .inFlight
        attemptCount += 1
    }

    public mutating func markAcknowledged() { status = .acknowledged }

    public mutating func markRejected(reason: String) {
        status = .rejected
        lastError = reason
    }

    /// Retryable failure: return to pending, keep the same idempotency key (retry safety).
    public mutating func markRetryable(reason: String) {
        status = .pending
        lastError = reason
    }

    /// Schedule a backoff retry: pending, same idempotency key, not due until `at`
    /// (ADR-0012 §9). Deterministic — the delay is computed by the engine from the injected
    /// clock + injected randomness, never a `sleep`.
    public mutating func scheduleRetry(reason: String, at nextAttempt: Date) {
        status = .pending
        lastError = reason
        nextAttemptAt = nextAttempt
    }

    /// True when the operation is pending and due (no scheduled backoff in the future).
    public func isDue(at now: Date) -> Bool {
        status == .pending && (nextAttemptAt.map { $0 <= now } ?? true)
    }
}

/// The persistence layer stores outbox records generically (`OutboxOperation`); this is
/// the sync layer supplying its concrete record type. `awaitingReplay` covers in-flight
/// ops too: after a crash, ambiguous sends are safe to replay (idempotency keys).
extension SyncOperation: OutboxOperation {
    public var awaitingReplay: Bool { status == .pending || status == .inFlight }
}

/// Concrete composition boundary: the outbox store as the sync and service layers use it.
public typealias SyncOutboxStore = any SyncOperationStore<SyncOperation>

/// The in-memory reference store specialised to the concrete operation type — what tests
/// and non-Apple hosts construct.
public typealias InMemorySyncStore = InMemoryStore<SyncOperation>

/// Concrete composition boundary for coach programming persistence (ADR-0009).
public typealias ProgrammingStore = any ProgrammingRepository<SyncOperation>

/// Outcome classification for a transport attempt.
public enum SyncAttemptOutcome: Sendable, Equatable {
    case acknowledged
    /// Network error, timeout, 5xx — retry with backoff, same key.
    case retryable(String)
    /// Validation/authorization failure — park the operation, surface to the user.
    case terminallyRejected(String)
    /// Session expired — pause the queue until re-authentication.
    case authExpired
}
