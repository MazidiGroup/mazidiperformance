import Foundation
import MazidiFoundations

/// A performed set, matching the prescription type (7d/7j). Append-only fact:
/// once recorded it is never mutated in place — corrections append a superseding entry.
public struct SetEntry: Sendable, Codable, Equatable, Identifiable {
    public enum Value: Sendable, Codable, Equatable {
        case repsAndLoad(reps: Int, loadKg: Double)
        case reps(Int)
        case time(seconds: Int)
        case distance(metres: Int)
    }

    public let id: Identifier<SetEntry>
    public let exerciseID: Identifier<AssignedExercise>
    /// Slug actually performed (differs from the assigned slug after an approved swap).
    public let performedSlug: ExerciseSlug
    public let setIndex: Int
    public let value: Value
    public let rpe: Double?
    public let recordedAt: Date
    /// Idempotency key for sync (ADR-0003): server applies each key at most once.
    public let idempotencyKey: UUID

    public init(
        id: Identifier<SetEntry> = .init(),
        exerciseID: Identifier<AssignedExercise>,
        performedSlug: ExerciseSlug,
        setIndex: Int,
        value: Value,
        rpe: Double? = nil,
        recordedAt: Date,
        idempotencyKey: UUID = UUID()
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.performedSlug = performedSlug
        self.setIndex = setIndex
        self.value = value
        self.rpe = rpe
        self.recordedAt = recordedAt
        self.idempotencyKey = idempotencyKey
    }
}

public enum WorkoutSessionError: Error, Equatable {
    case invalidTransition(from: WorkoutSession.Phase, action: String)
    case swapNotApproved(ExerciseSlug)
    case unknownExercise(Identifier<AssignedExercise>)
    case duplicateSet(exercise: Identifier<AssignedExercise>, setIndex: Int)
    case sessionReadOnly
}

/// The client workout session state machine (panels 3d, 5a, 5b, 5f, 5g).
///
/// Phases: notStarted → active ⇄ paused → completed | abandoned,
/// plus supersededReadOnly — entered when another device takes over (one-device rule,
/// panel 5f). A superseded session's recorded sets remain readable and recoverable;
/// they are never silently discarded.
public struct WorkoutSession: Sendable, Codable, Equatable {
    public enum Phase: String, Sendable, Codable {
        case notStarted, active, paused, completed, abandoned, supersededReadOnly
    }

    public let id: Identifier<WorkoutSession>
    public let workout: AssignedWorkout
    /// Server-issued session epoch for the one-device rule. A session with a lower epoch
    /// than the server's current epoch is superseded.
    public let epoch: Int

    public private(set) var phase: Phase
    public private(set) var startedAt: Date?
    public private(set) var completedAt: Date?
    public private(set) var setEntries: [SetEntry]
    /// Approved swaps applied this session: assigned exercise → performed slug.
    public private(set) var swaps: [Identifier<AssignedExercise>: ExerciseSlug]

    public init(
        id: Identifier<WorkoutSession> = .init(),
        workout: AssignedWorkout,
        epoch: Int
    ) {
        self.id = id
        self.workout = workout
        self.epoch = epoch
        self.phase = .notStarted
        self.setEntries = []
        self.swaps = [:]
    }

    // MARK: - Lifecycle

    public mutating func start(at date: Date) throws {
        guard phase == .notStarted else {
            throw WorkoutSessionError.invalidTransition(from: phase, action: "start")
        }
        phase = .active
        startedAt = date
    }

    public mutating func pause() throws {
        guard phase == .active else {
            throw WorkoutSessionError.invalidTransition(from: phase, action: "pause")
        }
        phase = .paused
    }

    public mutating func resume() throws {
        guard phase == .paused else {
            throw WorkoutSessionError.invalidTransition(from: phase, action: "resume")
        }
        phase = .active
    }

    /// Exit without finishing (5a/5g): recorded work is kept; the session can be resumed
    /// later from Today (5b). Exiting maps to `paused` — "nothing lost".
    public mutating func exitKeepingProgress() throws {
        switch phase {
        case .active: phase = .paused
        case .paused: break
        default: throw WorkoutSessionError.invalidTransition(from: phase, action: "exit")
        }
    }

    public mutating func complete(at date: Date) throws {
        guard phase == .active || phase == .paused else {
            throw WorkoutSessionError.invalidTransition(from: phase, action: "complete")
        }
        phase = .completed
        completedAt = date
    }

    /// Discard an unfinished session by explicit user choice (5g option). Recorded sets
    /// stay in the struct (history readable); phase blocks further writes.
    public mutating func abandon() throws {
        guard phase == .active || phase == .paused else {
            throw WorkoutSessionError.invalidTransition(from: phase, action: "abandon")
        }
        phase = .abandoned
    }

    /// One-device rule (5f): a newer epoch elsewhere supersedes this session.
    /// Completed/abandoned sessions are history and are NOT retroactively superseded.
    public mutating func markSuperseded(byEpoch newerEpoch: Int) {
        guard newerEpoch > epoch else { return }
        guard phase == .notStarted || phase == .active || phase == .paused else { return }
        phase = .supersededReadOnly
    }

    // MARK: - Recording work

    public var isWritable: Bool { phase == .active }

    /// Record a performed set. Duplicate (exercise, setIndex) submissions are rejected —
    /// duplicate prevention at the domain layer, before sync-level idempotency.
    public mutating func recordSet(
        exerciseID: Identifier<AssignedExercise>,
        setIndex: Int,
        value: SetEntry.Value,
        rpe: Double? = nil,
        at date: Date
    ) throws -> SetEntry {
        guard isWritable else {
            if phase == .supersededReadOnly { throw WorkoutSessionError.sessionReadOnly }
            throw WorkoutSessionError.invalidTransition(from: phase, action: "recordSet")
        }
        guard let assigned = workout.allExercises.first(where: { $0.id == exerciseID }) else {
            throw WorkoutSessionError.unknownExercise(exerciseID)
        }
        guard !setEntries.contains(where: { $0.exerciseID == exerciseID && $0.setIndex == setIndex }) else {
            throw WorkoutSessionError.duplicateSet(exercise: exerciseID, setIndex: setIndex)
        }
        let entry = SetEntry(
            exerciseID: exerciseID,
            performedSlug: swaps[exerciseID] ?? assigned.slug,
            setIndex: setIndex,
            value: value,
            rpe: rpe,
            recordedAt: date
        )
        setEntries.append(entry)
        return entry
    }

    /// Swap to a coach-approved alternative (4b/7e/7h). Only listed alternatives are allowed;
    /// sets already recorded keep the slug they were performed with.
    public mutating func swapExercise(
        _ exerciseID: Identifier<AssignedExercise>,
        to alternative: ExerciseSlug
    ) throws {
        guard isWritable else {
            if phase == .supersededReadOnly { throw WorkoutSessionError.sessionReadOnly }
            throw WorkoutSessionError.invalidTransition(from: phase, action: "swap")
        }
        guard let assigned = workout.allExercises.first(where: { $0.id == exerciseID }) else {
            throw WorkoutSessionError.unknownExercise(exerciseID)
        }
        guard assigned.approvedAlternatives.contains(alternative) else {
            throw WorkoutSessionError.swapNotApproved(alternative)
        }
        swaps[exerciseID] = alternative
    }

    /// Revert a swap back to the originally assigned exercise.
    public mutating func revertSwap(_ exerciseID: Identifier<AssignedExercise>) throws {
        guard isWritable else {
            if phase == .supersededReadOnly { throw WorkoutSessionError.sessionReadOnly }
            throw WorkoutSessionError.invalidTransition(from: phase, action: "revertSwap")
        }
        swaps[exerciseID] = nil
    }

    // MARK: - Progress

    public func completedSetCount(for exerciseID: Identifier<AssignedExercise>) -> Int {
        setEntries.filter { $0.exerciseID == exerciseID }.count
    }

    public var isEveryPrescribedSetRecorded: Bool {
        workout.allExercises.allSatisfy { completedSetCount(for: $0.id) >= $0.prescription.setCount }
    }
}
