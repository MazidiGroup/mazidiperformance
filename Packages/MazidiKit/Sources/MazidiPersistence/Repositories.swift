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

/// Coach programming + assignment persistence (ADR-0009). Generic over the outbox
/// operation like `SyncOperationStore`, so every mutating write can commit its queued
/// operations in the same transaction (ADR-0003 invariant).
public protocol ProgrammingRepository<Operation>: Sendable {
    associatedtype Operation: OutboxOperation

    // Templates (coach drafts) & immutable versions
    func saveTemplateAtomically(_ template: WorkoutTemplate, enqueueing operations: [Operation]) async throws
    func template(id: Identifier<WorkoutTemplate>) async throws -> WorkoutTemplate?
    func allTemplates() async throws -> [WorkoutTemplate]
    /// Publication: updated template (bumped version count) + immutable version row +
    /// operations, in one transaction. Versions are never updated afterwards.
    func publishAtomically(
        template: WorkoutTemplate,
        version: WorkoutTemplateVersion,
        enqueueing operations: [Operation]
    ) async throws
    func version(id: Identifier<WorkoutTemplateVersion>) async throws -> WorkoutTemplateVersion?
    func versions(templateID: Identifier<WorkoutTemplate>) async throws -> [WorkoutTemplateVersion]

    // Assignments
    func saveAssignmentAtomically(_ assignment: WorkoutAssignment, enqueueing operations: [Operation]) async throws
    func assignment(id: Identifier<WorkoutAssignment>) async throws -> WorkoutAssignment?
    func allAssignments() async throws -> [WorkoutAssignment]
    /// Assignment lifecycle transition + the session executing it + operations, in one
    /// transaction (start and completion linkage, ADR-0009).
    func recordAssignmentTransitionAtomically(
        session: WorkoutSession,
        assignment: WorkoutAssignment,
        enqueueing operations: [Operation]
    ) async throws
}

/// Coach–Client relationship persistence (ADR-0012 §6). Generic over the outbox operation
/// like the other repositories, so a relationship write commits with its queued operation in
/// one transaction (ADR-0003 invariant).
public protocol RelationshipRepository<Operation>: Sendable {
    associatedtype Operation: OutboxOperation

    func saveRelationshipAtomically(_ relationship: Relationship, enqueueing operations: [Operation]) async throws
    func relationship(id: Identifier<Relationship>) async throws -> Relationship?
    func allRelationships() async throws -> [Relationship]
}

/// An audit event awaiting its chain hash. ADR-0006 requires the event to be written in the
/// same transaction as the action, and the hash chain to be unbroken — which means
/// `previousHash` can only be resolved *inside* that transaction. Callers describe the event;
/// the store links it.
public struct PendingAuditEvent: Sendable, Equatable {
    public let id: Identifier<AuditEvent>
    public let kind: AuditEvent.Kind
    public let actorID: UUID
    public let subjectDescription: String
    public let occurredAt: Date
    public let payload: [String: String]

    public init(
        id: Identifier<AuditEvent> = .init(),
        kind: AuditEvent.Kind,
        actorID: UUID,
        subjectDescription: String,
        occurredAt: Date,
        payload: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.actorID = actorID
        self.subjectDescription = subjectDescription
        self.occurredAt = occurredAt
        self.payload = payload
    }

    /// Link into the chain behind `previousHash`.
    public func linked(previousHash: String) -> AuditEvent {
        AuditEvent(
            id: id, kind: kind, actorID: actorID, subjectDescription: subjectDescription,
            occurredAt: occurredAt, previousHash: previousHash, payload: payload
        )
    }
}

/// Health-data consent persistence (ADR-0013 consent model). Generic over the outbox
/// operation like the other repositories, so a consent decision, its queued sync operation and
/// its audit event commit in ONE transaction (ADR-0003/0006 invariant).
///
/// There is deliberately **no delete API**: consent history is append-only evidence
/// (Art. 7(1)), and withdrawal is a separate, narrower operation that can only stamp
/// `withdrawnAt` on a record already in force.
public protocol HealthDataConsentRepository<Operation>: Sendable {
    associatedtype Operation: OutboxOperation

    /// Append a new grant record. Insert-only: it can never overwrite an existing record.
    func grantConsentAtomically(
        _ record: HealthDataConsent,
        enqueueing operations: [Operation],
        auditing event: PendingAuditEvent
    ) async throws

    /// Close the record in force for `purpose` by stamping `withdrawnAt`. Only that column
    /// changes — `granted_at`, `notice_version` and `purpose` are never rewritten — and the
    /// write is conditional on the record still being in force, so a double withdrawal cannot
    /// silently move the timestamp.
    func withdrawConsentAtomically(
        recordID: Identifier<HealthDataConsent>,
        at withdrawnAt: Date,
        enqueueing operations: [Operation],
        auditing event: PendingAuditEvent
    ) async throws

    /// The full append-only history for this account.
    func consentLedger() async throws -> HealthDataConsentLedger
}

public enum HealthDataConsentStoreError: Error, Equatable, Sendable {
    /// No record with that id, or it is already withdrawn — either way there is nothing in
    /// force to close, and no row is modified.
    case noRecordInForce(Identifier<HealthDataConsent>)
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

public actor InMemoryStore<Operation: OutboxOperation>: WorkoutSessionRepository, SyncOperationStore, AuditEventStore, ProgrammingRepository, RelationshipRepository, HealthDataConsentRepository {
    private var sessions: [Identifier<WorkoutSession>: WorkoutSession] = [:]
    private var operations: [Operation.ID: Operation] = [:]
    private var operationOrder: [Operation.ID] = []
    private var auditEvents: [AuditEvent] = []
    private var templates: [Identifier<WorkoutTemplate>: WorkoutTemplate] = [:]
    private var templateVersions: [Identifier<WorkoutTemplateVersion>: WorkoutTemplateVersion] = [:]
    private var assignments: [Identifier<WorkoutAssignment>: WorkoutAssignment] = [:]
    private var relationships: [Identifier<Relationship>: Relationship] = [:]
    /// Append-only: entries are added and (on withdrawal) closed in place. Never removed.
    private var consentRecords: [HealthDataConsent] = []

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

    // ProgrammingRepository

    private func failIfRequested() throws {
        if failNextAtomicWrite {
            failNextAtomicWrite = false
            throw SimulatedCrash()
        }
    }

    public func saveTemplateAtomically(_ template: WorkoutTemplate, enqueueing newOperations: [Operation]) async throws {
        try failIfRequested()
        templates[template.id] = template
        for op in newOperations { operations[op.id] = op; operationOrder.append(op.id) }
    }

    public func template(id: Identifier<WorkoutTemplate>) async throws -> WorkoutTemplate? { templates[id] }

    public func allTemplates() async throws -> [WorkoutTemplate] {
        templates.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func publishAtomically(
        template: WorkoutTemplate,
        version: WorkoutTemplateVersion,
        enqueueing newOperations: [Operation]
    ) async throws {
        try failIfRequested()
        templates[template.id] = template
        templateVersions[version.id] = version
        for op in newOperations { operations[op.id] = op; operationOrder.append(op.id) }
    }

    public func version(id: Identifier<WorkoutTemplateVersion>) async throws -> WorkoutTemplateVersion? {
        templateVersions[id]
    }

    public func versions(templateID: Identifier<WorkoutTemplate>) async throws -> [WorkoutTemplateVersion] {
        templateVersions.values.filter { $0.templateID == templateID }.sorted { $0.versionNumber < $1.versionNumber }
    }

    public func saveAssignmentAtomically(_ assignment: WorkoutAssignment, enqueueing newOperations: [Operation]) async throws {
        try failIfRequested()
        assignments[assignment.id] = assignment
        for op in newOperations { operations[op.id] = op; operationOrder.append(op.id) }
    }

    public func assignment(id: Identifier<WorkoutAssignment>) async throws -> WorkoutAssignment? {
        assignments[id]
    }

    public func allAssignments() async throws -> [WorkoutAssignment] {
        assignments.values.sorted { $0.assignedAt > $1.assignedAt }
    }

    public func recordAssignmentTransitionAtomically(
        session: WorkoutSession,
        assignment: WorkoutAssignment,
        enqueueing newOperations: [Operation]
    ) async throws {
        try failIfRequested()
        sessions[session.id] = session
        assignments[assignment.id] = assignment
        for op in newOperations { operations[op.id] = op; operationOrder.append(op.id) }
    }

    // RelationshipRepository

    public func saveRelationshipAtomically(_ relationship: Relationship, enqueueing newOperations: [Operation]) async throws {
        try failIfRequested()
        relationships[relationship.id] = relationship
        for op in newOperations { operations[op.id] = op; operationOrder.append(op.id) }
    }

    public func relationship(id: Identifier<Relationship>) async throws -> Relationship? { relationships[id] }

    public func allRelationships() async throws -> [Relationship] {
        relationships.values.sorted { $0.createdAt < $1.createdAt }
    }

    // HealthDataConsentRepository

    public func grantConsentAtomically(
        _ record: HealthDataConsent,
        enqueueing newOperations: [Operation],
        auditing event: PendingAuditEvent
    ) async throws {
        try failIfRequested()
        consentRecords.append(record)
        for op in newOperations { operations[op.id] = op; operationOrder.append(op.id) }
        auditEvents.append(event.linked(previousHash: try await latestHash()))
    }

    public func withdrawConsentAtomically(
        recordID: Identifier<HealthDataConsent>,
        at withdrawnAt: Date,
        enqueueing newOperations: [Operation],
        auditing event: PendingAuditEvent
    ) async throws {
        try failIfRequested()
        guard let index = consentRecords.firstIndex(where: { $0.id == recordID && $0.isInForce }) else {
            throw HealthDataConsentStoreError.noRecordInForce(recordID)
        }
        // Closes the record in place — the array never shrinks, and only `withdrawnAt` moves.
        try consentRecords[index].withdraw(at: withdrawnAt)
        for op in newOperations { operations[op.id] = op; operationOrder.append(op.id) }
        auditEvents.append(event.linked(previousHash: try await latestHash()))
    }

    public func consentLedger() async throws -> HealthDataConsentLedger {
        HealthDataConsentLedger(records: consentRecords)
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
