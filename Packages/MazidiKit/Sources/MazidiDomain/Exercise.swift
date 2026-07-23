import Foundation
import MazidiFoundations

/// Review status of client-facing copy. The draft badge is a product rule
/// (`functional-rules.md`, exercise content): draft content is always labelled
/// "DRAFT COPY · PENDING REVIEW" and can never be presented as approved in code paths
/// that haven't received an explicit approved status from the content pipeline.
public enum ContentStatus: String, Sendable, Codable {
    case draftRequiresHumanReview = "draft_requires_human_review"
    case approved
}

/// Client-visible exercise copy — sourced from the client-content layer, keyed by stable slug.
/// Vendor/source text is never shown raw; `useCases` from source metadata stays internal.
public struct ExerciseContent: Sendable, Codable, Equatable {
    public let slug: ExerciseSlug
    public let displayName: String
    public let aliases: [String]
    public let clientDescription: String
    public let clientInstructions: [String]
    public let clientMistakes: [String]
    public let clientBenefits: [String]
    public let defaultCue: String
    public let contentStatus: ContentStatus
    public let reviewFlags: [String]

    public init(
        slug: ExerciseSlug,
        displayName: String,
        aliases: [String] = [],
        clientDescription: String = "",
        clientInstructions: [String] = [],
        clientMistakes: [String] = [],
        clientBenefits: [String] = [],
        defaultCue: String = "",
        contentStatus: ContentStatus = .draftRequiresHumanReview,
        reviewFlags: [String] = []
    ) {
        self.slug = slug
        self.displayName = displayName
        self.aliases = aliases
        self.clientDescription = clientDescription
        self.clientInstructions = clientInstructions
        self.clientMistakes = clientMistakes
        self.clientBenefits = clientBenefits
        self.defaultCue = defaultCue
        self.contentStatus = contentStatus
        self.reviewFlags = reviewFlags
    }
}

/// Type-aware prescription (panels 7d/7j): each exercise type prescribes different fields.
public enum Prescription: Sendable, Codable, Equatable {
    case repsAndLoad(sets: Int, reps: ClosedRange<Int>, loadKg: Double?)
    case repsOnly(sets: Int, reps: ClosedRange<Int>)
    case timed(sets: Int, seconds: Int)
    case distance(sets: Int, metres: Int)
    /// Effort-based, e.g. "3 sets to RPE 8".
    case effort(sets: Int, targetRPE: Double)

    public var setCount: Int {
        switch self {
        case let .repsAndLoad(sets, _, _),
             let .repsOnly(sets, _),
             let .timed(sets, _),
             let .distance(sets, _),
             let .effort(sets, _):
            return sets
        }
    }
}

/// One exercise as assigned inside a workout, with coach cue and ordered approved alternatives (7e).
public struct AssignedExercise: Sendable, Codable, Equatable, Identifiable {
    public let id: Identifier<AssignedExercise>
    public let slug: ExerciseSlug
    public let prescription: Prescription
    public let coachCue: String?
    /// Coach-ordered alternatives; a client may swap only to one of these (4b/7h).
    public let approvedAlternatives: [ExerciseSlug]
    public let restSeconds: Int

    public init(
        id: Identifier<AssignedExercise> = .init(),
        slug: ExerciseSlug,
        prescription: Prescription,
        coachCue: String? = nil,
        approvedAlternatives: [ExerciseSlug] = [],
        restSeconds: Int = 90
    ) {
        self.id = id
        self.slug = slug
        self.prescription = prescription
        self.coachCue = coachCue
        self.approvedAlternatives = approvedAlternatives
        self.restSeconds = restSeconds
    }
}

/// A workout as assigned to a client: warm-up / main / cool-down sections (slice-1 scope).
public struct AssignedWorkout: Sendable, Codable, Equatable, Identifiable {
    public enum Section: String, Sendable, Codable, CaseIterable {
        case warmUp, main, coolDown
    }

    public let id: Identifier<AssignedWorkout>
    public let title: String
    public let programmeVersion: Int
    public let sections: [Section: [AssignedExercise]]

    public init(
        id: Identifier<AssignedWorkout> = .init(),
        title: String,
        programmeVersion: Int,
        sections: [Section: [AssignedExercise]]
    ) {
        self.id = id
        self.title = title
        self.programmeVersion = programmeVersion
        self.sections = sections
    }

    public var allExercises: [AssignedExercise] {
        Section.allCases.flatMap { sections[$0] ?? [] }
    }
}
