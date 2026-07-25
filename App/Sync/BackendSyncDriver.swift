import Foundation
import MazidiAuth
import MazidiFoundations
import MazidiNetworking

/// Thread-safe "session active" flag the sync engines read (sync) as their generation
/// guard. The owning environment flips it false in `invalidate()` (sign-out/switch/
/// revocation), so no work uploads afterwards. Read off the engine actor, hence the lock.
final class SyncActiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func deactivate() { lock.lock(); active = false; lock.unlock() }
}

/// Device-global, non-secret installation id (ADR-0012 §2) — namespaces idempotency and
/// identifies the sender. Lives in device-global UserDefaults, never a per-account table.
enum DeviceInstallation {
    private static let key = "mazidi.device.installation.id"
    static func id(defaults: UserDefaults = .standard) -> DeviceInstallationID {
        if let existing = defaults.string(forKey: key) { return DeviceInstallationID(existing) }
        let minted = UUID().uuidString
        defaults.set(minted, forKey: key)
        return DeviceInstallationID(minted)
    }
}

#if DEBUG
import MazidiPersistenceGRDB
import MazidiSync

/// DEBUG-only in-app sync driver (ADR-0012 §10). Exercises the REAL BackendPushEngine +
/// BackendPullEngine against the deterministic `FakeSyncBackend` — compiled out of Release
/// entirely (the fake is `#if DEBUG`), so it can never be a production path. Generation-
/// guarded: `isActive` is false once the owning environment is invalidated (sign-out /
/// switch / revocation), so no work uploads afterwards. A confirmed transport revocation is
/// routed out via `onRevocation` (the app calls `SessionCoordinator.revocationReported`).
@MainActor
final class BackendSyncDriver {
    let backend = FakeSyncBackend()
    private let store: GRDBStore
    private let context: AuthenticatedRequestContext
    private let push: BackendPushEngine
    private let pull: BackendPullEngine

    /// Set by the session layer to route a confirmed revocation to the SessionCoordinator.
    var onRevocation: (@Sendable @MainActor () -> Void)?

    private(set) var isOnline = true

    init(store: GRDBStore, accountID: AccountID, clock: any AppClock, isActive: @escaping @Sendable () -> Bool) {
        self.store = store
        self.context = AuthenticatedRequestContext(
            accountID: accountID, deviceInstallationID: DeviceInstallation.id(),
            generation: 0, accessToken: { "dev-token" }   // fake ignores it; never a real secret
        )
        self.push = BackendPushEngine(
            outbox: store, syncStore: store, transport: backend, clock: clock,
            isActive: isActive, audit: store, actorID: accountID.stableActorUUID
        )
        self.pull = BackendPullEngine(
            syncStore: store, transport: backend, clock: clock,
            isActive: isActive, audit: store, actorID: accountID.stableActorUUID
        )
    }

    func setOnline(_ value: Bool) async {
        isOnline = value
        await backend.setOnline(value)
        if value { try? await store.clearPendingRetrySchedule() }   // retry-now on reconnect
    }

    /// Drain once: push the outbox, then pull changes. Routes a confirmed revocation.
    @discardableResult
    func drain() async -> BackendPushSummary {
        // Deterministically ensure the dev backend auto-acknowledges (no init race).
        await backend.setAutoAck(true)
        let summary = (try? await push.pushOnce(context: context)) ?? BackendPushSummary()
        _ = try? await pull.pullOnce(context: context)
        if summary.revoked { onRevocation?() }
        return summary
    }
}
#endif
