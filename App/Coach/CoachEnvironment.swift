import Foundation
import MazidiAuth
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
    let operations: SyncOutboxStore
    let audit: any AuditEventStore

    init<S>(_ store: S)
        where S: ProgrammingRepository, S: SyncOperationStore, S: AuditEventStore,
              S.Operation == SyncOperation {
        self.programming = store
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
    let store: CoachStore
    let storeHealth: ClientEnvironment.StoreHealth

    private let closeStore: () -> Void
    private(set) var isInvalidated = false

    init(
        accountID: AccountID,
        clock: any AppClock = SystemClock(),
        content: any ExerciseContentProviding = FixtureExerciseContentProvider()
    ) {
        self.accountID = accountID
        self.clock = clock
        self.content = content

        let log = AppLog(category: "persistence")
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["MAZIDI_STORE_MODE"] == "ephemeral", let ephemeral = try? GRDBStore.inMemory() {
            self.store = CoachStore(ephemeral)
            self.storeHealth = .intentionallyEphemeral
            self.closeStore = { try? ephemeral.close() }
            return
        }
        #endif
        do {
            let base = try Self.storeBase()
            let grdb = try GRDBStore.open(
                directory: AccountDatabasePath.directory(base: base, accountID: accountID)
            )
            self.store = CoachStore(grdb)
            switch grdb.recovery {
            case .normal:
                self.storeHealth = .durable
            case let .recoveredAfterQuarantine(path, _):
                self.storeHealth = .recoveredAfterQuarantine(quarantinedPath: path)
            }
            self.closeStore = { try? grdb.close() }
        } catch {
            log.error("Durable coach store unavailable (\(error)); in-memory fallback")
            let fallback = InMemorySyncStore()
            self.store = CoachStore(fallback)
            self.storeHealth = .ephemeralFallback
            self.closeStore = {}
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
        closeStore()
    }

    func makeModel() -> CoachProgrammingModel {
        CoachProgrammingModel(environment: self)
    }
}
