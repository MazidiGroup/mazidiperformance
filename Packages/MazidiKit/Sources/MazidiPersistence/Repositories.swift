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

public protocol SyncOperationStore: Sendable {
    /// Atomically persist a session snapshot and enqueue operations — the crash-safety
    /// invariant of ADR-0003: either both are stored or neither is.
    func saveAtomically(session: WorkoutSession, enqueueing operations: [SyncOperation]) async throws
    func enqueue(_ operation: SyncOperation) async throws
    func update(_ operation: SyncOperation) async throws
    func pendingOperations() async throws -> [SyncOperation]
    func operations(inAggregate aggregateID: UUID) async throws -> [SyncOperation]
    func nextSequence(forAggregate aggregateID: UUID) async throws -> Int
}

public protocol AuditEventStore: Sendable {
    func append(_ event: AuditEvent) async throws
    func latestHash() async throws -> String
    func allEvents() async throws -> [AuditEvent]
}

// MARK: - In-memory reference implementation

public actor InMemoryStore: WorkoutSessionRepository, SyncOperationStore, AuditEventStore {
    private var sessions: [Identifier<WorkoutSession>: WorkoutSession] = [:]
    private var operations: [Identifier<SyncOperation>: SyncOperation] = [:]
    private var operationOrder: [Identifier<SyncOperation>] = []
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

    public func saveAtomically(session: WorkoutSession, enqueueing newOperations: [SyncOperation]) async throws {
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

    public func enqueue(_ operation: SyncOperation) async throws {
        operations[operation.id] = operation
        operationOrder.append(operation.id)
    }

    public func update(_ operation: SyncOperation) async throws {
        operations[operation.id] = operation
    }

    public func pendingOperations() async throws -> [SyncOperation] {
        operationOrder.compactMap { operations[$0] }
            .filter { $0.status == .pending || $0.status == .inFlight }
    }

    public func operations(inAggregate aggregateID: UUID) async throws -> [SyncOperation] {
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
        auditEvents.last.map { chainHash(of: $0) } ?? "0"
    }

    public func allEvents() async throws -> [AuditEvent] {
        auditEvents
    }

    /// Application-level chain hash (ADR-0006). FNV-1a over the stable fields — a
    /// dependency-free tamper-evidence hash; swap for SHA-256 (swift-crypto) app-side.
    private func chainHash(of event: AuditEvent) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(event.id)|\(event.kind.rawValue)|\(event.previousHash)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
