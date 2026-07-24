import Foundation
import Observation
import MazidiAuth
import MazidiFoundations

/// App-side owner of the `SessionCoordinator` (ADR-0008). Translates `AuthPhase` into a
/// routable surface, builds the account-scoped `ClientEnvironment` on sign-in, and tears
/// it down (closing the database) on sign-out/switch — keyed by the coordinator's
/// generation so stale environments are never reused across accounts.
@MainActor
@Observable
final class SessionModel {
    /// What the root shows. Derived from `AuthPhase` + role claims + storage health.
    enum Route: Equatable {
        case signedOut(pendingRemoteRevocation: Bool)
        case authenticating
        case authenticationFailed(message: String)
        case clientShell
        case coachShell(accountLabel: String)
        /// Missing/conflicting role claims — safe error surface (ADR-0008 §7).
        case roleError(reason: String)
        /// The account database could not open durably — never presented as normal
        /// signed-in data access.
        case storageFailure
        case signingOut
        case locked
        case revoked
    }

    private(set) var route: Route = .signedOut(pendingRemoteRevocation: false)
    /// True while the session is valid only locally (offline restore / unreachable
    /// refresh) — shells show honest local-only wording where relevant.
    private(set) var isOfflineAuthenticated = false

    private(set) var clientEnvironment: ClientEnvironment?

    private let coordinator: SessionCoordinator
    private var observation: Task<Void, Never>?
    private var environmentGeneration: UInt64?

    private let credentialStore: any CredentialStore

    init() {
        let provider: any AuthProviding
        let credentialStore: any CredentialStore
        #if DEBUG
        provider = DevelopmentAuthProvider()
        credentialStore = Self.developmentCredentialStore() ?? KeychainCredentialStore()
        #else
        provider = UnavailableAuthProvider()
        credentialStore = KeychainCredentialStore()
        #endif
        self.credentialStore = credentialStore
        self.coordinator = SessionCoordinator(
            provider: provider,
            credentials: credentialStore
        )
    }

    #if DEBUG
    /// UI-test credential storage (never Release). CI builds the app unsigned, so the
    /// Keychain is unavailable; under explicit UI-test configuration we substitute a
    /// Keychain-free store keyed to the SAME launch variables that scope the database:
    /// - `MAZIDI_STORE_DIR=<base>` — file-backed store in that unique per-test directory,
    ///   so a development session survives termination (relaunch/account-switch journeys).
    /// - `MAZIDI_STORE_MODE=ephemeral` — in-memory store (fresh per process; sign-in works
    ///   without the Keychain, no cross-launch restoration needed).
    /// Returns nil for normal Debug runs, which then use the real Keychain.
    private static func developmentCredentialStore() -> (any CredentialStore)? {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["MAZIDI_STORE_DIR"] {
            return DevelopmentFileCredentialStore(directory: URL(fileURLWithPath: dir, isDirectory: true))
        }
        if env["MAZIDI_STORE_MODE"] == "ephemeral" {
            return InMemoryCredentialStore()
        }
        return nil
    }
    #endif

    func start() async {
        guard observation == nil else { return }
        #if DEBUG
        // Deterministic start for UI tests: forget any stored development session so a
        // journey always begins signed out. DEBUG-only; Release ignores the variable.
        if ProcessInfo.processInfo.environment["MAZIDI_AUTH_RESET"] == "1",
           let stored = try? await credentialStore.loadCurrent() {
            try? await credentialStore.delete(for: stored.accountID)
        }
        #endif
        let coordinator = coordinator
        observation = Task { [weak self] in
            for await phase in await coordinator.phases() {
                await self?.handle(phase)
            }
        }
        await coordinator.restoreOnLaunch()
    }

    // MARK: - Intents

    func signIn(devIdentity: String) async {
        await coordinator.signIn(.development(identity: devIdentity))
    }

    func cancelAuthentication() async { await coordinator.cancelAuthentication() }
    func acknowledgeFailure() async { await coordinator.acknowledgeFailure() }
    func unlock() async { await coordinator.unlock() }

    func signOut() async {
        _ = await coordinator.signOut()
    }

    // MARK: - Phase handling

    private func handle(_ phase: AuthPhase) async {
        let generation = await coordinator.generation

        // Tear down the account environment whenever data access ends or the
        // generation moved on (sign-out, switch): audit, close, drop (ADR-0008 §8).
        if let env = clientEnvironment,
           !phase.allowsAccountDataAccess || environmentGeneration != generation {
            env.invalidate()
            clientEnvironment = nil
            environmentGeneration = nil
        }

        switch phase {
        case let .signedOut(pending):
            isOfflineAuthenticated = false
            route = .signedOut(pendingRemoteRevocation: pending)
        case .authenticating:
            route = .authenticating
        case let .authenticationFailed(error):
            route = .authenticationFailed(message: Self.message(for: error))
        case .signingOut:
            route = .signingOut
        case .locked:
            route = .locked
        case .revoked:
            isOfflineAuthenticated = false
            route = .revoked
        case let .authenticated(session), let .refreshing(session):
            isOfflineAuthenticated = false
            routeForSession(session, generation: generation)
        case let .offlineAuthenticated(session), let .sessionExpired(session),
             let .reauthenticationRequired(session):
            isOfflineAuthenticated = true
            routeForSession(session, generation: generation)
        }
    }

    private func routeForSession(_ session: AuthSession, generation: UInt64) {
        guard let role = session.claims.routableRole else {
            route = .roleError(
                reason: session.claims.roles.isEmpty
                    ? "This account has no role assigned yet."
                    : "This account's roles conflict."
            )
            return
        }
        switch role {
        case .client:
            if clientEnvironment == nil || environmentGeneration != generation {
                let env = ClientEnvironment(accountID: session.claims.accountID)
                clientEnvironment = env
                environmentGeneration = generation
            }
            // A signed-in user whose durable store could not open is NOT presented as
            // normally signed in with data access (ADR-0008).
            if clientEnvironment?.storeHealth == .ephemeralFallback {
                route = .storageFailure
            } else {
                route = .clientShell
            }
        case .coach:
            // Coach data surfaces arrive in later phases; the shell itself carries no
            // account-scoped store yet. Label shows the fixture identity in DEBUG.
            route = .coachShell(accountLabel: session.claims.accountID.rawValue)
        }
    }

    private static func message(for error: AuthError) -> String {
        switch error {
        case .invalidCredentials:
            return "That sign-in didn't work. Check the details and try again."
        case .networkUnavailable:
            return "No connection. Try again when you're back online."
        case .providerUnavailable:
            return "Sign-in isn't available yet — it arrives with the backend service."
        case .refreshRejected, .revoked:
            return "Your session ended. Please sign in again."
        case .credentialStorage:
            return "Secure storage is unavailable on this device right now."
        case .internalInconsistency:
            return "Something went wrong. Please try again."
        }
    }
}
