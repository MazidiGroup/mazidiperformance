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

    #if LOCAL_IDENTITY
    /// The role of the active **local test profile** (ADR-0014), or nil when the session is
    /// not one. Drives the honest local-profile labelling and the role switch.
    private(set) var localProfileRole: RoleClaim?
    #endif

    private(set) var clientEnvironment: ClientEnvironment?
    private(set) var coachEnvironment: CoachEnvironment?

    private let coordinator: SessionCoordinator
    private var observation: Task<Void, Never>?
    private var environmentGeneration: UInt64?

    private let credentialStore: any CredentialStore

    init() {
        let provider: any AuthProviding
        let credentialStore: any CredentialStore
        #if LOCAL_IDENTITY
        // Debug + Staging (the TestFlight configuration): a device-local test profile
        // occupies the provider slot so the app can be opened on a real device while no
        // backend exists (ADR-0014). It is not authentication and the UI never says it is.
        // In DEBUG it also forwards the ADR-0008 §6 fixture identities.
        provider = LocalDeviceAuthProvider(profiles: Self.localProfileStore())
        #elseif DEBUG
        provider = DevelopmentAuthProvider()
        #else
        provider = UnavailableAuthProvider()
        #endif
        #if DEBUG
        credentialStore = Self.developmentCredentialStore() ?? KeychainCredentialStore()
        #else
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

    #if LOCAL_IDENTITY
    /// Storage for the local test profile (ADR-0014). The Keychain is the normal path —
    /// including every Staging/TestFlight build. Under the DEBUG UI-test launch variables
    /// the same Keychain-free seam used for credentials applies, because CI builds the app
    /// unsigned and an unsigned simulator app cannot use the Keychain.
    private static func localProfileStore() -> any LocalDeviceProfileStoring {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let dir = env["MAZIDI_STORE_DIR"] {
            return LocalDeviceProfileFileStore(directory: URL(fileURLWithPath: dir, isDirectory: true))
        }
        if env["MAZIDI_STORE_MODE"] == "ephemeral" {
            return InMemoryLocalDeviceProfileStore()
        }
        #endif
        return KeychainLocalDeviceProfileStore()
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

    #if LOCAL_IDENTITY
    /// Open the app with this device's local test profile in `role` (ADR-0014). Goes
    /// through the ordinary coordinator sign-in — no state machine step is skipped.
    func continueAsLocalProfile(role: RoleClaim) async {
        await coordinator.signIn(.development(identity: LocalDeviceAccount.signInIdentity(for: role)))
    }

    /// Switch the local test profile to the other role. Deliberately implemented as a full
    /// **account switch**: sign out first (generation bump → environments invalidated and
    /// the account database closed) and only then sign in as the other role's account,
    /// which derives its own account-scoped directory. No state crosses the two shells.
    func switchLocalRole(to role: RoleClaim) async {
        guard localProfileRole != nil else { return }
        _ = await coordinator.signOut()
        await continueAsLocalProfile(role: role)
    }
    #endif

    func cancelAuthentication() async { await coordinator.cancelAuthentication() }
    func acknowledgeFailure() async { await coordinator.acknowledgeFailure() }
    func unlock() async { await coordinator.unlock() }

    func signOut() async {
        _ = await coordinator.signOut()
    }

    // MARK: - Phase handling

    private func handle(_ phase: AuthPhase) async {
        let generation = await coordinator.generation
        #if LOCAL_IDENTITY
        // Non-nil only while the active session is a local test profile, so the honest
        // "local test profile" surfaces appear for exactly those sessions and never for a
        // development fixture identity (or a real account, once one can exist).
        localProfileRole = phase.session.flatMap { LocalDeviceAccount(accountID: $0.claims.accountID)?.role }
        #endif

        // Tear down account environments whenever data access ends or the
        // generation moved on (sign-out, switch): audit, close, drop (ADR-0008 §8).
        if !phase.allowsAccountDataAccess || environmentGeneration != generation {
            if let env = clientEnvironment {
                env.invalidate()
                clientEnvironment = nil
            }
            if let env = coachEnvironment {
                env.invalidate()
                coachEnvironment = nil
            }
            if clientEnvironment == nil, coachEnvironment == nil {
                environmentGeneration = nil
            }
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
                // Route a confirmed transport revocation to the coordinator (ADR-0012 §8);
                // the phase stream then tears the environment down and returns to signed-out.
                env.setRevocationHandler { [weak self] in
                    Task { await self?.coordinator.revocationReported(forGeneration: generation) }
                }
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
            if coachEnvironment == nil || environmentGeneration != generation {
                let env = CoachEnvironment(accountID: session.claims.accountID)
                env.setRevocationHandler { [weak self] in
                    Task { await self?.coordinator.revocationReported(forGeneration: generation) }
                }
                coachEnvironment = env
                environmentGeneration = generation
            }
            if coachEnvironment?.storeHealth == .ephemeralFallback {
                route = .storageFailure
            } else {
                route = .coachShell(accountLabel: session.claims.accountID.rawValue)
            }
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
