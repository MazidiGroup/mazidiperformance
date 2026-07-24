import Foundation
import MazidiAuth
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
/// scope). All three handles reference the SAME underlying store instance — the generic
/// initializer is the only way to build one, so the roles can never be split across
/// different databases. Held as separate existentials rather than a protocol composition
/// because the CI-pinned Swift 6.1 compiler (Xcode 16.4) rejects parameterized protocols
/// inside compositions (`… & SyncOperationStore<SyncOperation>`), while plain
/// parameterized existentials like `SyncOutboxStore` compile on both toolchains.
struct ClientStore {
    let sessions: any WorkoutSessionRepository
    let operations: SyncOutboxStore
    let audit: any AuditEventStore
    let programming: ProgrammingStore

    init<S>(_ store: S)
        where S: WorkoutSessionRepository, S: AuditEventStore,
              S: SyncOperationStore, S: ProgrammingRepository,
              S.Operation == SyncOperation {
        self.sessions = store
        self.operations = store
        self.audit = store
        self.programming = store
    }
}

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
    /// Typed health of the store this launch (from GRDBStore.RecoveryCondition). The UI
    /// must consume this so a fresh-after-quarantine or fallback store is never presented
    /// as a normal empty state.
    enum StoreHealth: Equatable {
        /// Durable database opened normally — genuine first launch or existing data.
        case durable
        /// A damaged database was quarantined (preserved at the path, never deleted) and
        /// this launch runs on a fresh replacement. Must be surfaced to the user.
        case recoveredAfterQuarantine(quarantinedPath: String)
        /// DEBUG-only intentional ephemeral store (UI tests, previews). Expected; silent.
        case intentionallyEphemeral
        /// The durable store was unrecoverable this launch; running in-memory. Workouts
        /// recorded now will NOT survive relaunch — must be surfaced to the user.
        case ephemeralFallback
    }

    let clock: any AppClock
    let content: any ExerciseContentProviding
    let media: any MediaResolving
    let assignedWorkout: AssignedWorkout
    let storeHealth: StoreHealth

    private let store: ClientStore
    private let transport: FixtureSyncTransport
    let service: WorkoutSessionService
    let syncEngine: SyncEngine

    var connectivity: FixtureSyncTransport { transport }

    /// The authenticated account this environment serves.
    let accountID: AccountID
    private let closeStore: () -> Void
    private(set) var isInvalidated = false

    init(
        accountID: AccountID,
        clock: any AppClock = SystemClock(),
        content: any ExerciseContentProviding = FixtureExerciseContentProvider(),
        media: any MediaResolving = BundleMediaResolver(),
        assignedWorkout: AssignedWorkout = ClientFixtures.todaysWorkout,
        store: ClientStore? = nil
    ) {
        self.accountID = accountID
        self.clock = clock
        self.content = content
        self.media = media
        self.assignedWorkout = assignedWorkout

        let (resolvedStore, health, close) = store.map { ($0, StoreHealth.durable, {}) }
            ?? Self.makeStore(accountID: accountID)
        self.storeHealth = health
        self.closeStore = close
        let transport = FixtureSyncTransport()
        self.store = resolvedStore
        self.transport = transport
        self.service = WorkoutSessionService(
            store: .init(
                sessions: resolvedStore.sessions,
                operations: resolvedStore.operations,
                audit: resolvedStore.audit,
                programming: resolvedStore.programming
            ),
            clock: clock,
            // Deterministic per-account actor identity (never the raw account ID).
            actorID: accountID.stableActorUUID
        )
        self.syncEngine = SyncEngine(store: resolvedStore.operations, transport: transport)
    }

    /// Sign-out/switch teardown (ADR-0008 §8): best-effort local audit record, then close
    /// the database so every later repository call throws — account data becomes
    /// unreachable through this environment. Idempotent.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        let store = store
        let actorID = accountID.stableActorUUID
        let close = closeStore
        let clock = clock
        Task {
            // Non-sensitive security event in the account's own audit chain.
            if let previous = try? await store.audit.latestHash() {
                try? await store.audit.append(AuditEvent(
                    kind: .signedOut,
                    actorID: actorID,
                    subjectDescription: "session:this-device",
                    occurredAt: clock.now(),
                    previousHash: previous
                ))
            }
            close()
        }
    }

    /// Store selection (ADR-0008 §4): durable GRDB in the ACCOUNT-SCOPED directory
    /// `Application Support/MazidiPerformance/accounts/<hash>/` is the normal path.
    /// The legacy pre-identity database directly under `MazidiPerformance/` is never
    /// opened for an account (SECURITY_BOUNDARIES.md legacy policy). DEBUG-only
    /// overrides for UI tests and previews:
    /// - `MAZIDI_STORE_MODE=ephemeral` — fresh in-memory database for this process.
    /// - `MAZIDI_STORE_DIR=<base>` — account-scoped store under an explicit BASE
    ///   directory (isolation for relaunch/account-switch UI tests).
    /// Neither override is compiled into Release builds.
    private static func makeStore(accountID: AccountID) -> (ClientStore, StoreHealth, () -> Void) {
        let log = AppLog(category: "persistence")
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["MAZIDI_STORE_MODE"] == "ephemeral", let ephemeral = try? GRDBStore.inMemory() {
            return (ClientStore(ephemeral), .intentionallyEphemeral, { try? ephemeral.close() })
        }
        if let dir = env["MAZIDI_STORE_DIR"] {
            let base = URL(fileURLWithPath: dir, isDirectory: true)
            if let relocated = try? GRDBStore.open(
                directory: AccountDatabasePath.directory(base: base, accountID: accountID)
            ) {
                return (ClientStore(relocated), Self.health(of: relocated), { try? relocated.close() })
            }
        }
        #endif
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("MazidiPerformance", isDirectory: true)
            let store = try GRDBStore.open(
                directory: AccountDatabasePath.directory(base: base, accountID: accountID)
            )
            return (ClientStore(store), Self.health(of: store), { try? store.close() })
        } catch {
            // Unrecoverable open failure (the corrupt-file policy already ran and the
            // damaged files are preserved on disk — MIGRATIONS.md). The session layer
            // routes this to the storage-failure surface — never normal signed-in
            // data access (ADR-0008).
            log.error("Durable account store unavailable (\(error)); in-memory fallback")
            return (ClientStore(InMemorySyncStore()), .ephemeralFallback, {})
        }
    }

    private static func health(of store: GRDBStore) -> StoreHealth {
        switch store.recovery {
        case .normal:
            return .durable
        case let .recoveredAfterQuarantine(quarantinedPath, _):
            return .recoveredAfterQuarantine(quarantinedPath: quarantinedPath)
        }
    }

    /// Pending (not-yet-acknowledged) operation count — the truth behind "waiting to sync".
    func pendingOperationCount() async -> Int {
        (try? await store.operations.pendingOperations().count) ?? 0
    }

    /// Assignment reads for this client's account (ADR-0009). The account-scoped
    /// database only ever contains this client's assignments; the filter is defence in
    /// depth against relayed rows addressed elsewhere.
    func openAssignments() async -> [WorkoutAssignment] {
        let all = (try? await store.programming.allAssignments()) ?? []
        return all.filter {
            $0.assigneeAccountRef == accountID.rawValue
                && ($0.status == .queued || $0.status == .started)
        }
    }

    func makeWorkoutModel() -> ClientWorkoutModel {
        ClientWorkoutModel(environment: self)
    }
}
