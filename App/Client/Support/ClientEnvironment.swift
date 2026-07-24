import Foundation
import MazidiDomain
import MazidiFoundations
import MazidiPersistence
import MazidiPersistenceGRDB
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

/// The three store roles one durable database satisfies together (single transaction
/// scope). Both GRDBStore and the in-memory reference store conform.
typealias ClientStore =
    any WorkoutSessionRepository & AuditEventStore & SyncOperationStore<SyncOperation>

// MARK: - Composition root for the Client slice

/// Wires the Client workout slice to MazidiKit. In normal execution the store is the
/// durable GRDB database (ADR-0002/0007); previews and UI tests can request an ephemeral
/// or relocated store through DEBUG-only environment overrides. The sync transport is
/// still a fixture whose connectivity is toggleable (no backend, R-01/R-02).
///
/// This is the ONLY place stores/fixtures are constructed; views and the view-model
/// receive everything through this object, never reaching for globals.
@MainActor
final class ClientEnvironment {
    let clock: any AppClock
    let content: any ExerciseContentProviding
    let media: any MediaResolving
    let assignedWorkout: AssignedWorkout

    private let store: ClientStore
    private let transport: FixtureSyncTransport
    let service: WorkoutSessionService
    let syncEngine: SyncEngine

    var connectivity: FixtureSyncTransport { transport }

    init(
        clock: any AppClock = SystemClock(),
        content: any ExerciseContentProviding = FixtureExerciseContentProvider(),
        media: any MediaResolving = BundleMediaResolver(),
        assignedWorkout: AssignedWorkout = ClientFixtures.todaysWorkout,
        store: ClientStore? = nil
    ) {
        self.clock = clock
        self.content = content
        self.media = media
        self.assignedWorkout = assignedWorkout

        let resolvedStore = store ?? Self.makeStore()
        let transport = FixtureSyncTransport()
        self.store = resolvedStore
        self.transport = transport
        self.service = WorkoutSessionService(
            store: .init(sessions: resolvedStore, operations: resolvedStore, audit: resolvedStore),
            clock: clock,
            actorID: ClientFixtures.devClientActorID
        )
        self.syncEngine = SyncEngine(store: resolvedStore, transport: transport)
    }

    /// Store selection. Durable GRDB in Application Support is the normal path; the
    /// DEBUG-only overrides exist for UI tests and previews:
    /// - `MAZIDI_STORE_MODE=ephemeral` — fresh in-memory database for this process.
    /// - `MAZIDI_STORE_DIR=<path>` — durable database at an explicit directory (the
    ///   relaunch-restoration UI test uses a unique temp directory).
    /// Neither override is compiled into Release builds.
    private static func makeStore() -> ClientStore {
        let log = AppLog(category: "persistence")
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["MAZIDI_STORE_MODE"] == "ephemeral", let ephemeral = try? GRDBStore.inMemory() {
            return ephemeral
        }
        if let dir = env["MAZIDI_STORE_DIR"],
           let relocated = try? GRDBStore.open(directory: URL(fileURLWithPath: dir, isDirectory: true)) {
            return relocated
        }
        #endif
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            return try GRDBStore.open(
                directory: base.appendingPathComponent("MazidiPerformance", isDirectory: true)
            )
        } catch {
            // Unrecoverable open failure (the corrupt-file policy already ran and the
            // damaged files are preserved on disk — MIGRATIONS.md). Keep this launch
            // usable with a clearly-logged in-memory store; nothing is deleted.
            log.error("Durable store unavailable (\(error)); running in-memory for this launch")
            return InMemorySyncStore()
        }
    }

    /// Pending (not-yet-acknowledged) operation count — the truth behind "waiting to sync".
    func pendingOperationCount() async -> Int {
        (try? await store.pendingOperations().count) ?? 0
    }

    func makeWorkoutModel() -> ClientWorkoutModel {
        ClientWorkoutModel(environment: self)
    }
}
