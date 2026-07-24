import Foundation
import MazidiDomain
import MazidiFoundations
import MazidiPersistence
import MazidiSync

/// Slice-1 application service: drives a client workout session with local-first,
/// crash-safe persistence (ADR-0003). Every mutation writes the session snapshot and its
/// sync operation atomically; audit events accompany consequential transitions (ADR-0006).
public actor WorkoutSessionService {
    public enum ServiceError: Error {
        case noActiveSession
        case programmingUnavailable
        case assignmentNotFound
    }

    private let store: StoreBundle
    private let clock: any AppClock
    private let actorID: UUID

    private var session: WorkoutSession?

    /// Bundles the store roles so one object can satisfy them — the in-memory
    /// reference store and the durable GRDB store both do (one database, one
    /// transaction scope). `programming` is optional: fixture-only compositions
    /// (no assignments) omit it.
    public struct StoreBundle: Sendable {
        public let sessions: any WorkoutSessionRepository
        public let operations: SyncOutboxStore
        public let audit: any AuditEventStore
        public let programming: ProgrammingStore?

        public init(
            sessions: any WorkoutSessionRepository,
            operations: SyncOutboxStore,
            audit: any AuditEventStore,
            programming: ProgrammingStore? = nil
        ) {
            self.sessions = sessions
            self.operations = operations
            self.audit = audit
            self.programming = programming
        }
    }

    public init(store: StoreBundle, clock: any AppClock, actorID: UUID) {
        self.store = store
        self.clock = clock
        self.actorID = actorID
    }

    public var currentSession: WorkoutSession? { session }

    // MARK: - Lifecycle

    /// Load the resumable session after launch/crash (5b: unfinished workout on Today).
    /// Normalises restoration state honestly: a rest whose time fully elapsed while the
    /// app was closed is restored as elapsed (cleared), never restarted (panel 4a).
    public func restoreIfNeeded() async throws -> WorkoutSession? {
        if session == nil {
            session = try await store.sessions.resumableSession()
            if var s = session, let rest = s.activeRest, rest.isFinished(at: clock.now()) {
                s.setActiveRest(nil)
                try await store.sessions.save(s)
                session = s
            }
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

    /// Start a session executing an assignment (ADR-0009): the version snapshot seeds the
    /// session (the assignment itself is never mutated by execution), the assignment
    /// transitions to `started`, and session + assignment + their operations commit in
    /// ONE transaction.
    public func startAssignment(_ assignment: WorkoutAssignment, epoch: Int) async throws -> WorkoutSession {
        guard let programming = store.programming else { throw ServiceError.programmingUnavailable }
        let workout = try assignment.assignedWorkout()
        var newSession = WorkoutSession(workout: workout, epoch: epoch, assignmentID: assignment.id)
        let now = clock.now()
        try newSession.start(at: now)
        var transitioned = assignment
        try transitioned.markStarted()

        let sessionAggregate = newSession.id.rawValue
        let assignmentAggregate = assignment.id.rawValue
        let ops = [
            SyncOperation(
                kind: .workoutSessionStarted,
                aggregateID: sessionAggregate,
                sequence: try await store.operations.nextSequence(forAggregate: sessionAggregate),
                payload: try JSONEncoder().encode(newSession),
                enqueuedAt: now
            ),
            SyncOperation(
                kind: .assignmentStatusChanged,
                aggregateID: assignmentAggregate,
                sequence: try await store.operations.nextSequence(forAggregate: assignmentAggregate),
                payload: try JSONEncoder().encode(transitioned),
                enqueuedAt: now
            ),
        ]
        try await programming.recordAssignmentTransitionAtomically(
            session: newSession, assignment: transitioned, enqueueing: ops
        )
        try await appendAudit(.workoutSessionStarted, subject: "workoutSession:\(newSession.id)")
        try await appendAudit(.assignmentStarted, subject: "assignment:\(assignment.id)")
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

    /// Idempotent: pausing an already-paused session is a no-op, not an error — a client
    /// re-tapping Pause (or a restored paused session) must never see a failure
    /// (KNOWN_ISSUES M3). Other phases still fail loudly via the domain rules.
    public func pause() async throws {
        guard var s = session else { throw ServiceError.noActiveSession }
        if s.phase == .paused { return }
        try s.pause()
        try await store.sessions.save(s)
        session = s
    }

    /// Idempotent: resuming an already-active session is a no-op, not an error — once
    /// sessions survive relaunch a restored session can legitimately still be `.active`
    /// (the app was killed without exiting), and resume must succeed silently
    /// (KNOWN_ISSUES M1). Other phases still fail loudly via the domain rules.
    public func resume() async throws {
        guard var s = session else { throw ServiceError.noActiveSession }
        if s.phase == .active { return }
        try s.resume()
        try await store.sessions.save(s)
        session = s
    }

    /// Persist the client's position for honest restoration (5b). Restoration metadata —
    /// saved with the snapshot, never enqueued as a sync operation.
    public func updateCurrentExercise(_ exerciseID: Identifier<AssignedExercise>?) async throws {
        guard var s = session else { throw ServiceError.noActiveSession }
        s.setCurrentExercise(exerciseID)
        try await store.sessions.save(s)
        session = s
    }

    /// Persist (or clear) the in-progress rest so a relaunch can compute the honest
    /// remaining time from timestamps (panel 4a). Same snapshot-only rule as position.
    public func updateActiveRest(_ rest: RestTimer?) async throws {
        guard var s = session else { throw ServiceError.noActiveSession }
        s.setActiveRest(rest)
        try await store.sessions.save(s)
        session = s
    }

    /// Exit without finishing (5a/5g "nothing lost"): recorded work is kept and the session
    /// stays resumable from Today (5b). Maps to `paused` at the domain layer.
    public func exit() async throws {
        guard var s = session else { throw ServiceError.noActiveSession }
        try s.exitKeepingProgress()
        try await store.sessions.save(s)
        session = s
    }

    /// Discard an unfinished session by explicit user choice (5g). Recorded sets remain
    /// readable history; the abandon transition is enqueued for sync like other mutations.
    public func discard() async throws {
        guard var s = session else { throw ServiceError.noActiveSession }
        try s.abandon()
        try await persist(s, kind: .workoutSessionAbandoned, auditKind: nil)
        session = s
    }

    public func complete() async throws -> WorkoutSession {
        guard var s = session else { throw ServiceError.noActiveSession }
        let now = clock.now()
        try s.complete(at: now)

        // Assignment-linked completion (ADR-0009): session + assignment status +
        // operations in ONE transaction. Duplicate completion (e.g. replay after a
        // relaunch race) is refused by the domain guard — the session still completes,
        // the assignment record is simply left as-is.
        if let assignmentID = s.assignmentID, let programming = store.programming {
            guard var assignment = try await programming.assignment(id: assignmentID) else {
                throw ServiceError.assignmentNotFound
            }
            do {
                try assignment.markCompleted(sessionID: s.id, at: now)
                let sessionAggregate = s.id.rawValue
                let assignmentAggregate = assignment.id.rawValue
                let ops = [
                    SyncOperation(
                        kind: .workoutSessionCompleted,
                        aggregateID: sessionAggregate,
                        sequence: try await store.operations.nextSequence(forAggregate: sessionAggregate),
                        payload: try JSONEncoder().encode(s),
                        enqueuedAt: now
                    ),
                    SyncOperation(
                        kind: .assignmentStatusChanged,
                        aggregateID: assignmentAggregate,
                        sequence: try await store.operations.nextSequence(forAggregate: assignmentAggregate),
                        payload: try JSONEncoder().encode(assignment),
                        enqueuedAt: now
                    ),
                ]
                try await programming.recordAssignmentTransitionAtomically(
                    session: s, assignment: assignment, enqueueing: ops
                )
                try await appendAudit(.workoutSessionCompleted, subject: "workoutSession:\(s.id)")
                try await appendAudit(.assignmentCompleted, subject: "assignment:\(assignment.id)")
            } catch WorkoutAssignment.TransitionError.alreadyCompleted {
                // Idempotent: never double-complete the assignment; persist the session.
                try await persist(s, kind: .workoutSessionCompleted, auditKind: .workoutSessionCompleted)
            }
            session = s
            return s
        }

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

    private func appendAudit(_ kind: AuditEvent.Kind, subject: String) async throws {
        let previous = try await store.audit.latestHash()
        try await store.audit.append(AuditEvent(
            kind: kind,
            actorID: actorID,
            subjectDescription: subject,
            occurredAt: clock.now(),
            previousHash: previous
        ))
    }

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
