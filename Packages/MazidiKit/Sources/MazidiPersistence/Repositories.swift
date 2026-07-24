import Foundation
import MazidiDomain
import MazidiFoundations

/// Persistence contracts (ADR-0002). The app target provides a GRDB/SQLite implementation;
/// this package ships an in-memory reference implementation used by tests and non-Apple hosts.
/// The GRDB adapter must pass the same contract test suite.

public protocol WorkoutSessionRepository: Sendable {
    func save(_ session: WorkoutSession) async throws
    func session(id: Identifier<WorkoutSession>) async throws -> WorkoutSession?
    /// The single resumable (paused/active/notStarted) session, if any (5b).
    func resumableSession() async throws -> WorkoutSession?
    func allSessions() async throws -> [WorkoutSession]
}

/// The persistence-facing shape of an outbox record. Deliberately minimal so this layer
/// stays free of sync/transport vocabulary: the store needs identity, aggregate ordering,
/// and whether the record still awaits successful replay — nothing about how replay works.
/// The concrete operation type (with its status machine and retry semantics) lives in
/// MazidiSync, which depends on this package, not the other way round.
public protocol OutboxOperation: Sendable, Codable, Identifiable where ID: Hashable & Sendable {
    /// Aggregate identity — replay is strictly ordered within one aggregate.
    var aggregateID: UUID { get }
    /// Monotonic sequence within the aggregate, assigned at enqueue.
    var sequence: Int { get }
    /// True while the record must still be replayed (pending, or ambiguously in flight).
    var awaitingReplay: Bool { get }
}

public protocol SyncOperationStore<Operation>: Sendable {
    associatedtype Operation: OutboxOperation

    /// Atomically persist a session snapshot and enqueue operations — the crash-safety
    /// invariant of ADR-0003: either both are stored or neither is.
    func saveAtomically(session: WorkoutSession, enqueueing operations: [Operation]) async throws
    func enqueue(_ operation: Operation) async throws
    func update(_ operation: Operation) async throws
    func pendingOperations() async throws -> [Operation]
    func operations(inAggregate aggregateID: UUID) async throws -> [Operation]
    func nextSequence(forAggregate aggregateID: UUID) async throws -> Int
}

public protocol AuditEventStore: Sendable {
    func append(_ event: AuditEvent) async throws
    func latestHash() async throws -> String
    func allEvents() async throws -> [AuditEvent]
}

/// Application-level chain hash (ADR-0006). FNV-1a over the stable fields — a
/// dependency-free tamper-evidence hash shared by every store implementation so the
/// chain stays consistent across the in-memory and durable stores; swap for SHA-256
/// (swift-crypto) app-side later. Genesis value is "0".
public func auditChainHash(of event: AuditEvent) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in "\(event.id)|\(event.kind.rawValue)|\(event.previousHash)".utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return String(format: "%016llx", hash)
}

// MARK: - In-memory reference implementation

public actor InMemoryStore<Operation: OutboxOperation>: WorkoutSessionRepository, SyncOperationStore, AuditEventStore {
    private var sessions: [Identifier<WorkoutSession>: WorkoutSession] = [:]
    private var operations: [Operation.ID: Operation] = [:]
    private var operationOrder: [Operation.ID] = []
    private var auditEvents: [AuditEvent] = []

    /// Test hook: when set, the next `saveAtomically` throws after doing nothing —
    /// simulating a crash/power-loss at the transaction boundary.
    private var failNextAtomicWrite = false

    public init() {}

    public func setFailNextAtomicWrite(_ fail: Bool) { failNextAtomicWrite = fail }

    // WorkoutSessionRepository

    public func save(_ session: WorkoutSession) async throws {
        sessions[session.id] = session
    }

    public func session(id: Identifier<WorkoutSession>) async throws -> WorkoutSession? {
        sessions[id]
    }

    public func resumableSession() async throws -> WorkoutSession? {
        sessions.values.first { [.notStarted, .active, .paused].contains($0.phase) }
    }

    public func allSessions() async throws -> [WorkoutSession] {
        Array(sessions.values)
    }

    // SyncOperationStore

    public struct SimulatedCrash: Error {}

    public func saveAtomically(session: WorkoutSession, enqueueing newOperations: [Operation]) async throws {
        if failNextAtomicWrite {
            failNextAtomicWrite = false
            throw SimulatedCrash()
        }
        sessions[session.id] = session
        for op in newOperations {
            operations[op.id] = op
            operationOrder.append(op.id)
        }
    }

    public func enqueue(_ operation: Operation) async throws {
        operations[operation.id] = operation
        operationOrder.append(operation.id)
    }

    public func update(_ operation: Operation) async throws {
        operations[operation.id] = operation
    }

    public func pendingOperations() async throws -> [Operation] {
        operationOrder.compactMap { operations[$0] }
            .filter(\.awaitingReplay)
    }

    public func operations(inAggregate aggregateID: UUID) async throws -> [Operation] {
        operationOrder.compactMap { operations[$0] }
            .filter { $0.aggregateID == aggregateID }
            .sorted { $0.sequence < $1.sequence }
    }

    public func nextSequence(forAggregate aggregateID: UUID) async throws -> Int {
        let existing = operationOrder.compactMap { operations[$0] }
            .filter { $0.aggregateID == aggregateID }
            .map(\.sequence)
            .max()
        return (existing ?? -1) + 1
    }

    // AuditEventStore

    public func append(_ event: AuditEvent) async throws {
        auditEvents.append(event)
    }

    public func latestHash() async throws -> String {
        auditEvents.last.map { auditChainHash(of: $0) } ?? "0"
    }

    public func allEvents() async throws -> [AuditEvent] {
        auditEvents
    }
}
