import Foundation
import MazidiDomain
import MazidiFoundations
import MazidiPersistence
import MazidiSync

/// Slice-1 application service: drives a client workout session with local-first,
/// crash-safe persistence (ADR-0003). Every mutation writes the session snapshot and its
/// sync operation atomically; audit events accompany consequential transitions (ADR-0006).
public actor WorkoutSessionService {
    public enum ServiceError: Error { case noActiveSession }

    private let store: InMemoryStoreBundle
    private let clock: any AppClock
    private let actorID: UUID

    private var session: WorkoutSession?

    /// Bundles the three store roles so one object can satisfy them (as InMemoryStore does;
    /// the GRDB adapter will too — one database, one transaction scope).
    public struct InMemoryStoreBundle: Sendable {
        public let sessions: any WorkoutSessionRepository
        public let operations: SyncOutboxStore
        public let audit: any AuditEventStore

        public init(
            sessions: any WorkoutSessionRepository,
            operations: SyncOutboxStore,
            audit: any AuditEventStore
        ) {
            self.sessions = sessions
            self.operations = operations
            self.audit = audit
        }
    }

    public init(store: InMemoryStoreBundle, clock: any AppClock, actorID: UUID) {
        self.store = store
        self.clock = clock
        self.actorID = actorID
    }

    public var currentSession: WorkoutSession? { session }

    // MARK: - Lifecycle

    /// Load the resumable session after launch/crash (5b: unfinished workout on Today).
    public func restoreIfNeeded() async throws -> WorkoutSession? {
        if session == nil {
            session = try await store.sessions.resumableSession()
        }
        return session
    }

    public func start(workout: AssignedWorkout, epoch: Int) async throws -> WorkoutSession {
        var newSession = WorkoutSession(workout: workout, epoch: epoch)
        let now = clock.now()
        try newSession.start(at: now)
        try await persist(newSession, kind: .workoutSessionStarted, auditKind: .workoutSessionStarted)
        session = newSession
        return newSession
    }

    public func recordSet(
        exerciseID: Identifier<AssignedExercise>,
        setIndex: Int,
        value: SetEntry.Value,
        rpe: Double? = nil
    ) async throws -> SetEntry {
        guard var s = session else { throw ServiceError.noActiveSession }
        let entry = try s.recordSet(
            exerciseID: exerciseID, setIndex: setIndex, value: value, rpe: rpe, at: clock.now()
        )
        try await persist(s, kind: .setRecorded, auditKind: nil, idempotencyKey: entry.idempotencyKey)
        session = s
        return entry
    }

    public func swapExercise(_ exerciseID: Identifier<AssignedExercise>, to alternative: ExerciseSlug) async throws {
        guard var s = session else { throw ServiceError.noActiveSession }
        try s.swapExercise(exerciseID, to: alternative)
        try await persist(s, kind: .exerciseSwapped, auditKind: .exerciseSwapped)
        session = s
    }

    public func pause() async throws {
        guard var s = session else { throw ServiceError.noActiveSession }
        try s.pause()
        try await store.sessions.save(s)
        session = s
    }

    public func resume() async throws {
        guard var s = session else { throw ServiceError.noActiveSession }
        try s.resume()
        try await store.sessions.save(s)
        session = s
    }

    public func complete() async throws -> WorkoutSession {
        guard var s = session else { throw ServiceError.noActiveSession }
        try s.complete(at: clock.now())
        try await persist(s, kind: .workoutSessionCompleted, auditKind: .workoutSessionCompleted)
        session = s
        return s
    }

    /// Apply a newer server epoch (one-device rule, 5f). The local session becomes
    /// read-only recoverable; its data is preserved and stays queryable.
    public func applyServerEpoch(_ epoch: Int) async throws {
        guard var s = session else { return }
        let before = s.phase
        s.markSuperseded(byEpoch: epoch)
        if s.phase != before {
            try await persist(s, kind: .workoutSessionAbandoned, auditKind: .workoutSessionSuperseded)
        }
        session = s
    }

    // MARK: - Atomic persist + enqueue

    private func persist(
        _ s: WorkoutSession,
        kind: SyncOperation.Kind,
        auditKind: AuditEvent.Kind?,
        idempotencyKey: UUID = UUID()
    ) async throws {
        let aggregateID = s.id.rawValue
        let sequence = try await store.operations.nextSequence(forAggregate: aggregateID)
        let payload = try JSONEncoder().encode(s)
        let op = SyncOperation(
            kind: kind,
            aggregateID: aggregateID,
            sequence: sequence,
            idempotencyKey: idempotencyKey,
            payload: payload,
            enqueuedAt: clock.now()
        )
        try await store.operations.saveAtomically(session: s, enqueueing: [op])
        if let auditKind {
            let previous = try await store.audit.latestHash()
            try await store.audit.append(AuditEvent(
                kind: auditKind,
                actorID: actorID,
                subjectDescription: "workoutSession:\(s.id)",
                occurredAt: clock.now(),
                previousHash: previous
            ))
        }
    }
}
