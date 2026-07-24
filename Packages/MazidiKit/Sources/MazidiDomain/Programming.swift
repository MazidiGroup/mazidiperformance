import Foundation
import MazidiFoundations

// Coach programming domain (ADR-0009): mutable drafts, immutable published versions,
// assignments that freeze what was prescribed. Foundation-only; account ownership is
// implicit in account-scoped databases, so no auth types appear here.

// MARK: - Set prescription (type-aware, unsupported-safe)

/// The coach-authored target for an exercise's sets. Mirrors the execution engine's
/// `Prescription` cases and adds `.unsupported`: a combination the engine cannot run yet
/// stays representable and visible instead of being coerced into the wrong type.
/// Publishing (not drafting) requires every exercise to be executable.
public enum SetPrescription: Sendable, Codable, Equatable {
    case repsAndLoad(sets: Int, reps: ClosedRange<Int>, loadKg: Double?)
    case repsOnly(sets: Int, reps: ClosedRange<Int>)
    case timed(sets: Int, seconds: Int)
    case distance(sets: Int, metres: Int)
    case effort(sets: Int, targetRPE: Double)
    /// Anything the execution engine can't run yet (e.g. mixed per-set schemes).
    case unsupported(description: String)

    public var isExecutable: Bool {
        if case .unsupported = self { return false }
        return true
    }

    public var setCount: Int {
        switch self {
        case let .repsAndLoad(sets, _, _), let .repsOnly(sets, _), let .timed(sets, _),
             let .distance(sets, _), let .effort(sets, _):
            return sets
        case .unsupported:
            return 0
        }
    }

    /// Map to the execution engine's prescription. Nil only for `.unsupported`.
    public var executionPrescription: Prescription? {
        switch self {
        case let .repsAndLoad(sets, reps, loadKg): return .repsAndLoad(sets: sets, reps: reps, loadKg: loadKg)
        case let .repsOnly(sets, reps): return .repsOnly(sets: sets, reps: reps)
        case let .timed(sets, seconds): return .timed(sets: sets, seconds: seconds)
        case let .distance(sets, metres): return .distance(sets: sets, metres: metres)
        case let .effort(sets, targetRPE): return .effort(sets: sets, targetRPE: targetRPE)
        case .unsupported: return nil
        }
    }
}

// MARK: - Prescribed exercise

public struct PrescribedExercise: Sendable, Codable, Equatable, Identifiable {
    public let id: Identifier<PrescribedExercise>
    public var slug: ExerciseSlug
    /// Explicit order within the workout (reorderable in the editor).
    public var order: Int
    public var prescription: SetPrescription
    public var restSeconds: Int
    /// Optional tempo notation (e.g. "3-1-1-0"); execution treats it as coaching text (MVP).
    public var tempo: String?
    /// Optional RIR/RPE annotation shown alongside the target (MVP: informational).
    public var effortAnnotation: String?
    public var coachNotes: String?
    /// Coach-ordered approved substitutions (7e).
    public var approvedAlternatives: [ExerciseSlug]

    public init(
        id: Identifier<PrescribedExercise> = .init(),
        slug: ExerciseSlug,
        order: Int,
        prescription: SetPrescription,
        restSeconds: Int = 90,
        tempo: String? = nil,
        effortAnnotation: String? = nil,
        coachNotes: String? = nil,
        approvedAlternatives: [ExerciseSlug] = []
    ) {
        self.id = id
        self.slug = slug
        self.order = order
        self.prescription = prescription
        self.restSeconds = restSeconds
        self.tempo = tempo
        self.effortAnnotation = effortAnnotation
        self.coachNotes = coachNotes
        self.approvedAlternatives = approvedAlternatives
    }
}

// MARK: - Template content (shared by draft, version, assignment snapshot)

public struct WorkoutTemplateContent: Sendable, Codable, Equatable {
    public var title: String
    /// Always kept sorted by `order`; `normalizedOrder()` reasserts contiguous ordering.
    public var exercises: [PrescribedExercise]

    public init(title: String, exercises: [PrescribedExercise] = []) {
        self.title = title
        self.exercises = exercises
    }

    public mutating func normalizeOrder() {
        exercises.sort { $0.order < $1.order }
        for index in exercises.indices { exercises[index].order = index }
    }

    /// Publishability validation: a non-empty title, at least one exercise, every
    /// exercise executable and structurally sane.
    public enum ValidationError: Error, Equatable {
        case emptyTitle
        case noExercises
        case unsupportedPrescription(ExerciseSlug)
        case invalidSetCount(ExerciseSlug)
    }

    public func validateForPublication() -> [ValidationError] {
        var errors: [ValidationError] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append(.emptyTitle) }
        if exercises.isEmpty { errors.append(.noExercises) }
        for exercise in exercises {
            if !exercise.prescription.isExecutable {
                errors.append(.unsupportedPrescription(exercise.slug))
            } else if exercise.prescription.setCount < 1 {
                errors.append(.invalidSetCount(exercise.slug))
            }
        }
        return errors
    }

    /// Convert to the execution model that seeds a `WorkoutSession`. Throws if any
    /// prescription is unexecutable (publication validation prevents this for versions).
    public func assignedWorkout(programmeVersion: Int) throws -> AssignedWorkout {
        var ordered = self
        ordered.normalizeOrder()
        let mapped: [AssignedExercise] = try ordered.exercises.map { exercise in
            guard let prescription = exercise.prescription.executionPrescription else {
                throw MappingError.unsupportedPrescription(exercise.slug)
            }
            // Tempo/effort annotations ride along as coaching text (ADR-0009 MVP rule).
            let noteParts = [exercise.coachNotes, exercise.tempo.map { "Tempo \($0)" },
                             exercise.effortAnnotation].compactMap { $0 }
            return AssignedExercise(
                id: Identifier<AssignedExercise>(exercise.id.rawValue),
                slug: exercise.slug,
                prescription: prescription,
                coachCue: noteParts.isEmpty ? nil : noteParts.joined(separator: " · "),
                approvedAlternatives: exercise.approvedAlternatives,
                restSeconds: exercise.restSeconds
            )
        }
        return AssignedWorkout(
            title: title,
            programmeVersion: programmeVersion,
            sections: [.main: mapped]
        )
    }

    public enum MappingError: Error, Equatable {
        case unsupportedPrescription(ExerciseSlug)
    }
}

// MARK: - Template (mutable draft) & version (immutable)

public struct WorkoutTemplate: Sendable, Codable, Equatable, Identifiable {
    public let id: Identifier<WorkoutTemplate>
    public var draft: WorkoutTemplateContent
    public private(set) var publishedVersionCount: Int
    public var updatedAt: Date

    public init(
        id: Identifier<WorkoutTemplate> = .init(),
        draft: WorkoutTemplateContent,
        publishedVersionCount: Int = 0,
        updatedAt: Date
    ) {
        self.id = id
        self.draft = draft
        self.publishedVersionCount = publishedVersionCount
        self.updatedAt = updatedAt
    }

    /// Snapshot the draft into the next immutable version. The draft stays editable;
    /// the returned version never changes (ADR-0009 immutability rule).
    public mutating func publish(at date: Date) throws -> WorkoutTemplateVersion {
        let errors = draft.validateForPublication()
        guard errors.isEmpty else { throw PublicationError.validationFailed(errors) }
        var frozen = draft
        frozen.normalizeOrder()
        publishedVersionCount += 1
        updatedAt = date
        return WorkoutTemplateVersion(
            templateID: id,
            versionNumber: publishedVersionCount,
            content: frozen,
            publishedAt: date
        )
    }

    public enum PublicationError: Error, Equatable {
        case validationFailed([WorkoutTemplateContent.ValidationError])
    }
}

public struct WorkoutTemplateVersion: Sendable, Codable, Equatable, Identifiable {
    public let id: Identifier<WorkoutTemplateVersion>
    public let templateID: Identifier<WorkoutTemplate>
    public let versionNumber: Int
    public let content: WorkoutTemplateContent
    public let publishedAt: Date

    public init(
        id: Identifier<WorkoutTemplateVersion> = .init(),
        templateID: Identifier<WorkoutTemplate>,
        versionNumber: Int,
        content: WorkoutTemplateContent,
        publishedAt: Date
    ) {
        self.id = id
        self.templateID = templateID
        self.versionNumber = versionNumber
        self.content = content
        self.publishedAt = publishedAt
    }
}

// MARK: - Assignment

/// A published workout assigned to one client. Freezes the version reference AND the
/// content snapshot, so later template edits can never rewrite what was prescribed.
public struct WorkoutAssignment: Sendable, Codable, Equatable, Identifiable {
    /// `queued` = created locally and queued for delivery. Never presented as received —
    /// delivery confirmation requires the future backend (ADR-0009 honesty rule).
    public enum Status: String, Sendable, Codable {
        case queued
        case started
        case completed
        case cancelled
    }

    public let id: Identifier<WorkoutAssignment>
    public let templateID: Identifier<WorkoutTemplate>
    public let versionID: Identifier<WorkoutTemplateVersion>
    public let versionNumber: Int
    public let content: WorkoutTemplateContent
    /// Opaque account reference of the assignee (domain stays auth-framework-free).
    public let assigneeAccountRef: String
    public let assignedAt: Date

    public private(set) var status: Status
    public private(set) var completedSessionID: Identifier<WorkoutSession>?
    public private(set) var completedAt: Date?

    public init(
        id: Identifier<WorkoutAssignment> = .init(),
        version: WorkoutTemplateVersion,
        assigneeAccountRef: String,
        assignedAt: Date
    ) {
        self.id = id
        self.templateID = version.templateID
        self.versionID = version.id
        self.versionNumber = version.versionNumber
        self.content = version.content
        self.assigneeAccountRef = assigneeAccountRef
        self.assignedAt = assignedAt
        self.status = .queued
        self.completedSessionID = nil
        self.completedAt = nil
    }

    /// Persistence-restoration initializer (ADR-0007 pattern).
    public init(
        restoring id: Identifier<WorkoutAssignment>,
        templateID: Identifier<WorkoutTemplate>,
        versionID: Identifier<WorkoutTemplateVersion>,
        versionNumber: Int,
        content: WorkoutTemplateContent,
        assigneeAccountRef: String,
        assignedAt: Date,
        status: Status,
        completedSessionID: Identifier<WorkoutSession>?,
        completedAt: Date?
    ) {
        self.id = id
        self.templateID = templateID
        self.versionID = versionID
        self.versionNumber = versionNumber
        self.content = content
        self.assigneeAccountRef = assigneeAccountRef
        self.assignedAt = assignedAt
        self.status = status
        self.completedSessionID = completedSessionID
        self.completedAt = completedAt
    }

    public enum TransitionError: Error, Equatable {
        case invalid(from: Status, action: String)
        case alreadyCompleted
    }

    public mutating func markStarted() throws {
        guard status == .queued || status == .started else {
            throw TransitionError.invalid(from: status, action: "start")
        }
        status = .started
    }

    /// Idempotent-guarded completion: a completed assignment can never complete again
    /// (relaunch cannot duplicate completion, ADR-0009).
    public mutating func markCompleted(sessionID: Identifier<WorkoutSession>, at date: Date) throws {
        guard status != .completed else { throw TransitionError.alreadyCompleted }
        guard status == .queued || status == .started else {
            throw TransitionError.invalid(from: status, action: "complete")
        }
        status = .completed
        completedSessionID = sessionID
        completedAt = date
    }

    public mutating func markCancelled() throws {
        guard status == .queued || status == .started else {
            throw TransitionError.invalid(from: status, action: "cancel")
        }
        status = .cancelled
    }

    /// The executable workout seeding a session. Versions are validated at publication,
    /// so this only throws for corrupted snapshots.
    public func assignedWorkout() throws -> AssignedWorkout {
        try content.assignedWorkout(programmeVersion: versionNumber)
    }
}
