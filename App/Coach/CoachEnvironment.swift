import Foundation
import MazidiAuth
import MazidiContent
import MazidiDomain
import MazidiFoundations
import MazidiPersistence
import MazidiPersistenceGRDB
import MazidiServices
import MazidiSync

/// The store roles the Coach shell needs, all referencing ONE underlying account-scoped
/// database (same construction discipline as `ClientStore`; Swift 6.1-safe existentials).
struct CoachStore {
    let programming: ProgrammingStore
    let relationships: RelationshipStore
    let operations: SyncOutboxStore
    let audit: any AuditEventStore

    init<S>(_ store: S)
        where S: ProgrammingRepository, S: RelationshipRepository, S: SyncOperationStore, S: AuditEventStore,
              S.Operation == SyncOperation {
        self.programming = store
        self.relationships = store
        self.operations = store
        self.audit = store
    }
}

/// Composition root for the Coach shell (ADR-0009). Owns the coach's account-scoped
/// durable store; constructed only from a validated coach session and torn down on
/// sign-out/switch exactly like the client environment (ADR-0008 §8).
@MainActor
final class CoachEnvironment {
    let accountID: AccountID
    let clock: any AppClock
    let content: any ExerciseContentProviding
    /// Catalogue-backed search/filter/preview store for the exercise picker (ADR-0011 §1),
    /// joined to the client-content draft for name/alias search.
    let catalogueStore: ExerciseCatalogueStore
    /// Composed media resolver for picker/preview posters (bundled tier resolves the
    /// representative set; the rest show the honest name+icon fallback).
    let media: any MediaResolving
    let store: CoachStore
    let storeHealth: ClientEnvironment.StoreHealth

    /// Generation guard shared with the sync engines; flipped false on invalidate().
    private let activeFlag = SyncActiveFlag()
    /// DEBUG-only driver exercising the real BackendPushEngine + BackendPullEngine against
    /// the fake backend (nil in Release / on an in-memory fallback store). Replaces the
    /// interim SyncEngine drain — closes finding #3 with the actual push/pull machinery.
    #if DEBUG
    private(set) var syncDriver: BackendSyncDriver?
    #endif

    private let closeStore: () -> Void
    private(set) var isInvalidated = false

    init(
        accountID: AccountID,
        clock: any AppClock = SystemClock(),
        content: CatalogueContentProvider = CatalogueContentProvider()
    ) {
        self.accountID = accountID
        self.clock = clock
        self.content = content
        let library = CatalogueLibrary()
        self.catalogueStore = library.catalogueStore(naming: content)
        self.media = library.mediaResolver()

        let log = AppLog(category: "persistence")
        let resolved: (store: CoachStore, health: ClientEnvironment.StoreHealth, close: () -> Void, grdb: GRDBStore?)
        #if DEBUG
        if ProcessInfo.processInfo.environment["MAZIDI_STORE_MODE"] == "ephemeral", let ephemeral = try? GRDBStore.inMemory() {
            resolved = (CoachStore(ephemeral), .intentionallyEphemeral, { try? ephemeral.close() }, ephemeral)
        } else {
            resolved = Self.durableStore(accountID: accountID, log: log)
        }
        #else
        resolved = Self.durableStore(accountID: accountID, log: log)
        #endif
        self.store = resolved.store
        self.storeHealth = resolved.health
        self.closeStore = resolved.close

        #if DEBUG
        if let grdb = resolved.grdb {
            let flag = activeFlag
            self.syncDriver = BackendSyncDriver(store: grdb, accountID: accountID, clock: clock, isActive: { flag.isActive })
        }
        #endif
    }

    private static func durableStore(accountID: AccountID, log: AppLog) -> (store: CoachStore, health: ClientEnvironment.StoreHealth, close: () -> Void, grdb: GRDBStore?) {
        do {
            let base = try Self.storeBase()
            let grdb = try GRDBStore.open(directory: AccountDatabasePath.directory(base: base, accountID: accountID))
            let health: ClientEnvironment.StoreHealth
            switch grdb.recovery {
            case .normal: health = .durable
            case let .recoveredAfterQuarantine(path, _): health = .recoveredAfterQuarantine(quarantinedPath: path)
            }
            return (CoachStore(grdb), health, { try? grdb.close() }, grdb)
        } catch {
            log.error("Durable coach store unavailable (\(error)); in-memory fallback")
            return (CoachStore(InMemorySyncStore()), .ephemeralFallback, {}, nil)
        }
    }

    /// Base directory for account-scoped stores (DEBUG override via MAZIDI_STORE_DIR —
    /// the same variable the client uses, so UI tests share one isolated base).
    nonisolated static func storeBase() throws -> URL {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["MAZIDI_STORE_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        #endif
        return try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("MazidiPerformance", isDirectory: true)
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        activeFlag.deactivate()   // stop the sync engines before closing (generation guard)
        closeStore()
    }

    /// Drain the coach outbox (draft/publish/assignment/relationship operations) through the
    /// real push/pull engines (DEBUG fake backend). Generation-guarded via `activeFlag`,
    /// torn down on sign-out/switch. Inert in Release (no fake) — ops stay queued honestly.
    func drainOutbox() async {
        guard !isInvalidated else { return }
        #if DEBUG
        await syncDriver?.drain()
        #endif
    }

    /// Route a confirmed transport revocation to the session layer (ADR-0012 §8). DEBUG only.
    func setRevocationHandler(_ handler: @escaping @Sendable @MainActor () -> Void) {
        #if DEBUG
        syncDriver?.onRevocation = handler
        #endif
    }

    /// Pending (not-yet-acknowledged) outbox count — the truth behind the honest status.
    func pendingCount() async -> Int {
        (try? await store.operations.pendingOperations().count) ?? 0
    }

    var isOnline: Bool {
        #if DEBUG
        syncDriver?.isOnline ?? false
        #else
        false
        #endif
    }

    func makeModel() -> CoachProgrammingModel {
        CoachProgrammingModel(environment: self)
    }
}
