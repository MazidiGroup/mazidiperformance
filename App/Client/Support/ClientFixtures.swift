import Foundation
import MazidiDomain
import MazidiFoundations
import MazidiSync

// ─────────────────────────────────────────────────────────────────────────────
//  FIXTURES — development stand-ins used until backend/content services exist
//  (R-01 auth, R-02 sync, content pipeline). Everything here is clearly labelled
//  and lives behind the provider protocols in ClientEnvironment; no production
//  code path assumes any of it is real.
// ─────────────────────────────────────────────────────────────────────────────

enum ClientFixtures {
    /// Dev-only actor id for audit records while real auth (R-01) is absent.
    static let devClientActorID = UUID(uuidString: "00000000-0000-0000-0000-0000C11E7700")!

    /// A representative assigned workout covering multiple prescription types (7d/7j) and
    /// an exercise with coach-approved alternatives (7e). Slugs match bundled media +
    /// client-content fixtures so the real copy and posters render.
    static let todaysWorkout: AssignedWorkout = {
        let warmUp = AssignedExercise(
            slug: "band-wood-chopper",
            prescription: .timed(sets: 2, seconds: 40),
            coachCue: "Easy pace — this is a primer, not a set.",
            restSeconds: 45
        )
        let squat = AssignedExercise(
            slug: "barbell-squat",
            prescription: .repsAndLoad(sets: 3, reps: 5...8, loadKg: 80),
            coachCue: "Brace before you unrack. Stop 1–2 reps shy of failure.",
            approvedAlternatives: ["kettlebell-sumo-deadlift", "barbell-rack-pull"],
            restSeconds: 120
        )
        let row = AssignedExercise(
            slug: "barbell-bent-over-row",
            prescription: .repsAndLoad(sets: 3, reps: 8...10, loadKg: 60),
            coachCue: "Lead with the elbows; keep the ribs down.",
            approvedAlternatives: ["dumbbell-row-bilateral"],
            restSeconds: 90
        )
        let press = AssignedExercise(
            slug: "barbell-high-incline-bench-press",
            prescription: .effort(sets: 3, targetRPE: 8),
            coachCue: "Take each set to about an 8 — two in reserve.",
            restSeconds: 90
        )
        let facePull = AssignedExercise(
            slug: "cable-seated-rope-face-pull",
            prescription: .repsOnly(sets: 2, reps: 12...15),
            coachCue: "Slow and strict — no body english.",
            restSeconds: 60
        )
        return AssignedWorkout(
            title: "Lower A · Week 9",
            programmeVersion: 1,
            sections: [
                .warmUp: [warmUp],
                .main: [squat, row, press],
                .coolDown: [facePull],
            ]
        )
    }()
}

/// Loads client-facing copy from the bundled `exercise-content.json` fixture (a subset of
/// the client-content layer). Vendor/source text is never shown; only the client layer.
struct FixtureExerciseContentProvider: ExerciseContentProviding {
    private let bySlug: [ExerciseSlug: ExerciseContent]

    init() {
        guard
            let url = Bundle.main.url(forResource: "exercise-content", withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle.main.url(forResource: "exercise-content", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([ExerciseContent].self, from: data)
        else {
            bySlug = [:]
            return
        }
        bySlug = Dictionary(uniqueKeysWithValues: decoded.map { ($0.slug, $0) })
    }

    func content(for slug: ExerciseSlug) -> ExerciseContent? { bySlug[slug] }
}

/// Resolves a small representative set of bundled posters (all 8 fixture slugs) and clips
/// (2 slugs). Missing media returns nil so the UI shows its name+icon fallback (7i) —
/// exactly the production behaviour for an un-cached clip.
struct BundleMediaResolver: MediaResolving {
    func posterURL(for slug: ExerciseSlug) -> URL? {
        Bundle.main.url(forResource: slug.rawValue, withExtension: "webp", subdirectory: "Media/posters")
            ?? Bundle.main.url(forResource: slug.rawValue, withExtension: "webp")
    }

    func clipURL(for slug: ExerciseSlug) -> URL? {
        Bundle.main.url(forResource: slug.rawValue, withExtension: "mp4", subdirectory: "Media/clips")
            ?? Bundle.main.url(forResource: slug.rawValue, withExtension: "mp4")
    }
}

/// FIXTURE transport for the SyncEngine. Connectivity is toggleable so the honest
/// offline → waiting → synced states (4i) can be driven in-app and in UI tests. When
/// "online" it acknowledges (mirroring the R-02 idempotent server); when "offline" it
/// returns a retryable failure, leaving operations durably queued — never dropped.
final class FixtureSyncTransport: SyncTransport, ConnectivityControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _isOnline: Bool

    init(isOnline: Bool = true) { _isOnline = isOnline }

    var isOnline: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isOnline }
        set { lock.lock(); _isOnline = newValue; lock.unlock() }
    }

    func send(_ operation: SyncOperation) async -> SyncAttemptOutcome {
        isOnline ? .acknowledged : .retryable("No connection")
    }
}
