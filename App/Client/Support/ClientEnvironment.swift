import Foundation
import MazidiDomain
import MazidiFoundations
import MazidiPersistence
import MazidiServices
import MazidiSync

// MARK: - Provider protocols (dependency-injection seams)

/// Resolves client-facing exercise copy by stable slug. Backed by a fixture today; a
/// content-pipeline/CDN-backed implementation drops in behind the same protocol later.
protocol ExerciseContentProviding: Sendable {
    func content(for slug: ExerciseSlug) -> ExerciseContent?
}

/// Resolves poster/clip media URLs by slug. Fixture-backed today (a small representative
/// set is bundled); production resolves against the CDN manifest (asset-cdn-integration.md).
protocol MediaResolving: Sendable {
    func posterURL(for slug: ExerciseSlug) -> URL?
    func clipURL(for slug: ExerciseSlug) -> URL?
}

/// Connectivity control the honest sync UI reads. A fixture toggle stands in for real
/// reachability until the backend exists (R-01/R-02) — clearly a development affordance.
/// Thread-safe (set from the UI, read from the sync engine's actor).
protocol ConnectivityControlling: AnyObject, Sendable {
    var isOnline: Bool { get set }
}

// MARK: - Composition root for the Client slice

/// Wires the Client workout slice to MazidiKit: one local store shared by the session
/// service and the sync engine (single transaction scope, as the GRDB adapter will use),
/// injectable clock, fixture content/media, and a fixture transport whose connectivity is
/// toggleable so the honest offline/sync states can be exercised end-to-end.
///
/// This is the ONLY place fixtures are constructed; views and the view-model receive
/// everything through this object, never reaching for globals.
@MainActor
final class ClientEnvironment {
    let clock: any AppClock
    let content: any ExerciseContentProviding
    let media: any MediaResolving
    let assignedWorkout: AssignedWorkout

    private let store: InMemorySyncStore
    private let transport: FixtureSyncTransport
    let service: WorkoutSessionService
    let syncEngine: SyncEngine

    var connectivity: FixtureSyncTransport { transport }

    init(
        clock: any AppClock = SystemClock(),
        content: any ExerciseContentProviding = FixtureExerciseContentProvider(),
        media: any MediaResolving = BundleMediaResolver(),
        assignedWorkout: AssignedWorkout = ClientFixtures.todaysWorkout
    ) {
        self.clock = clock
        self.content = content
        self.media = media
        self.assignedWorkout = assignedWorkout

        let store = InMemorySyncStore()
        let transport = FixtureSyncTransport()
        self.store = store
        self.transport = transport
        self.service = WorkoutSessionService(
            store: .init(sessions: store, operations: store, audit: store),
            clock: clock,
            actorID: ClientFixtures.devClientActorID
        )
        self.syncEngine = SyncEngine(store: store, transport: transport)
    }

    /// Pending (not-yet-acknowledged) operation count — the truth behind "waiting to sync".
    func pendingOperationCount() async -> Int {
        (try? await store.pendingOperations().count) ?? 0
    }

    func makeWorkoutModel() -> ClientWorkoutModel {
        ClientWorkoutModel(environment: self)
    }
}
