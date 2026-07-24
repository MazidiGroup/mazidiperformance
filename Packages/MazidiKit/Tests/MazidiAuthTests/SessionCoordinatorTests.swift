import Foundation
import Testing
import MazidiFoundations
@testable import MazidiAuth

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

/// Scriptable provider: deterministic results, optional artificial delay gates so tests
/// can order interleavings without sleeps.
private actor ScriptedProvider: AuthProviding {
    enum Behaviour {
        case succeed(roles: Set<RoleClaim>, account: String, ttl: TimeInterval)
        case fail(AuthError)
    }

    var signInBehaviour: Behaviour = .succeed(roles: [.client], account: "acct-1", ttl: 3600)
    var refreshBehaviour: Behaviour = .succeed(roles: [.client], account: "acct-1", ttl: 3600)
    var revocationAnswer: RevocationCheck = .unknown
    var signOutError: AuthError?
    private(set) var signOutCalls = 0
    private(set) var refreshCalls = 0
    /// When set, sign-in/refresh suspend until `release()` — for interleaving tests.
    private var gate: CheckedContinuation<Void, Never>?
    private var gated = false
    let clock: FixedClock

    init(clock: FixedClock) { self.clock = clock }

    func set(signIn: Behaviour? = nil, refresh: Behaviour? = nil, revocation: RevocationCheck? = nil, signOutError: AuthError?? = nil) {
        if let signIn { signInBehaviour = signIn }
        if let refresh { refreshBehaviour = refresh }
        if let revocation { revocationAnswer = revocation }
        if let signOutError { self.signOutError = signOutError }
    }

    func gateNextCall() { gated = true }

    func release() {
        gate?.resume()
        gate = nil
        gated = false
    }

    private func waitIfGated() async {
        if gated {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in gate = c }
        }
    }

    private func session(for behaviour: Behaviour) throws -> ProviderSession {
        switch behaviour {
        case let .fail(error):
            throw error
        case let .succeed(roles, account, ttl):
            let now = clock.now()
            let id = AccountID(account)
            return ProviderSession(
                claims: SessionClaims(accountID: id, roles: roles),
                credentials: AuthCredentials(
                    accountID: id,
                    accessToken: "token-\(UUID().uuidString)",
                    refreshToken: "refresh-\(UUID().uuidString)",
                    accessTokenExpiresAt: now.addingTimeInterval(ttl)
                ),
                authenticatedAt: now
            )
        }
    }

    func signIn(_ request: SignInRequest) async throws -> ProviderSession {
        await waitIfGated()
        return try session(for: signInBehaviour)
    }

    func refresh(refreshToken: String, accountID: AccountID) async throws -> ProviderSession {
        refreshCalls += 1
        await waitIfGated()
        return try session(for: refreshBehaviour)
    }

    func restore(credentials: AuthCredentials) async throws -> RestoredSession {
        switch revocationAnswer {
        case .revoked: throw AuthError.revoked
        case .active:
            return RestoredSession(
                claims: SessionClaims(accountID: credentials.accountID, roles: [.client]),
                rotatedCredentials: nil, validatedRemotely: true
            )
        case .unknown:
            return RestoredSession(
                claims: SessionClaims(accountID: credentials.accountID, roles: [.client]),
                rotatedCredentials: nil, validatedRemotely: false
            )
        }
    }

    func signOut(accessToken: String, accountID: AccountID) async throws {
        signOutCalls += 1
        if let signOutError { throw signOutError }
    }

    func checkRevocation(accountID: AccountID) async -> RevocationCheck { revocationAnswer }
}

private func makeStack(clock: FixedClock = FixedClock(t0)) -> (SessionCoordinator, ScriptedProvider, InMemoryCredentialStore, FixedClock) {
    let provider = ScriptedProvider(clock: clock)
    let store = InMemoryCredentialStore()
    let coordinator = SessionCoordinator(provider: provider, credentials: store, clock: clock)
    return (coordinator, provider, store, clock)
}

@Suite struct SessionCoordinatorTests {
    @Test func signInSuccessStoresCredentialsAndAuthenticates() async throws {
        let (coordinator, _, store, _) = makeStack()
        let phase = await coordinator.signIn(.development(identity: "dev-client-001"))
        guard case let .authenticated(session) = phase else {
            Issue.record("expected authenticated, got \(phase)"); return
        }
        #expect(session.claims.routableRole == .client)
        let stored = try await store.loadCurrent()
        #expect(stored?.accountID == session.claims.accountID)
    }

    @Test func signInFailureLandsInFailedStateWithoutCredentials() async throws {
        let (coordinator, provider, store, _) = makeStack()
        await provider.set(signIn: .fail(.invalidCredentials))
        let phase = await coordinator.signIn(.development(identity: "nope"))
        #expect(phase == .authenticationFailed(.invalidCredentials))
        #expect(try await store.loadCurrent() == nil)
        await coordinator.acknowledgeFailure()
        #expect(await coordinator.phase == .signedOut(pendingRemoteRevocation: false))
    }

    @Test func restoreWithRemoteValidationAuthenticates() async throws {
        let (coordinator, provider, store, clock) = makeStack()
        try await store.save(AuthCredentials(
            accountID: AccountID("acct-1"), accessToken: "a", refreshToken: "r",
            accessTokenExpiresAt: clock.now().addingTimeInterval(3600)
        ))
        await provider.set(revocation: .active)
        await coordinator.restoreOnLaunch()
        guard case .authenticated = await coordinator.phase else {
            Issue.record("expected authenticated, got \(await coordinator.phase)"); return
        }
    }

    @Test func restoreOfflineLandsInOfflineAuthenticated() async throws {
        let (coordinator, _, store, clock) = makeStack()
        try await store.save(AuthCredentials(
            accountID: AccountID("acct-1"), accessToken: "a", refreshToken: "r",
            accessTokenExpiresAt: clock.now().addingTimeInterval(3600)
        ))
        await coordinator.restoreOnLaunch() // provider answers .unknown → not validated remotely
        guard case .offlineAuthenticated = await coordinator.phase else {
            Issue.record("expected offlineAuthenticated, got \(await coordinator.phase)"); return
        }
    }

    @Test func restoreWithNothingStoredStaysSignedOut() async {
        let (coordinator, _, _, _) = makeStack()
        await coordinator.restoreOnLaunch()
        #expect(await coordinator.phase == .signedOut(pendingRemoteRevocation: false))
    }

    @Test func restoreOfRevokedCredentialsSurfacesRevokedAndDeletesThem() async throws {
        let (coordinator, provider, store, clock) = makeStack()
        let creds = AuthCredentials(
            accountID: AccountID("acct-1"), accessToken: "a", refreshToken: "r",
            accessTokenExpiresAt: clock.now().addingTimeInterval(3600)
        )
        try await store.save(creds)
        await provider.set(revocation: .revoked)
        await coordinator.restoreOnLaunch()
        guard case .revoked = await coordinator.phase else {
            Issue.record("expected revoked, got \(await coordinator.phase)"); return
        }
        #expect(try await store.loadCurrent() == nil)
    }

    @Test func refreshNearExpiryRenewsSession() async throws {
        let (coordinator, provider, _, clock) = makeStack()
        await provider.set(signIn: .succeed(roles: [.client], account: "acct-1", ttl: 100))
        await coordinator.signIn(.development(identity: "x"))
        clock.advance(by: 50) // inside the 120s near-expiry window
        let phase = await coordinator.ensureValidSession()
        guard case let .authenticated(session) = phase else {
            Issue.record("expected authenticated, got \(phase)"); return
        }
        #expect(!session.isNearExpiry(at: clock.now()))
        #expect(await provider.refreshCalls == 1)
    }

    @Test func freshSessionSkipsRefresh() async {
        let (coordinator, provider, _, _) = makeStack()
        await coordinator.signIn(.development(identity: "x"))
        _ = await coordinator.ensureValidSession()
        #expect(await provider.refreshCalls == 0)
    }

    @Test func refreshUnreachableGoesOfflineNotSignedOut() async {
        let (coordinator, provider, _, clock) = makeStack()
        await provider.set(signIn: .succeed(roles: [.client], account: "acct-1", ttl: 100),
                           refresh: .fail(.networkUnavailable))
        await coordinator.signIn(.development(identity: "x"))
        clock.advance(by: 50)
        let phase = await coordinator.ensureValidSession()
        guard case .offlineAuthenticated = phase else {
            Issue.record("expected offlineAuthenticated, got \(phase)"); return
        }
    }

    @Test func refreshRejectedRequiresReauthentication() async {
        let (coordinator, provider, _, clock) = makeStack()
        await provider.set(signIn: .succeed(roles: [.client], account: "acct-1", ttl: 100),
                           refresh: .fail(.refreshRejected))
        await coordinator.signIn(.development(identity: "x"))
        clock.advance(by: 50)
        let phase = await coordinator.ensureValidSession()
        guard case .reauthenticationRequired = phase else {
            Issue.record("expected reauthenticationRequired, got \(phase)"); return
        }
    }

    @Test func expiryReachedWithoutRefreshMarksSessionExpired() async {
        let (coordinator, provider, _, clock) = makeStack()
        await provider.set(signIn: .succeed(roles: [.client], account: "acct-1", ttl: 100),
                           refresh: .fail(.networkUnavailable))
        await coordinator.signIn(.development(identity: "x"))
        clock.advance(by: 500) // past expiry
        _ = await coordinator.ensureValidSession()
        // Refresh unreachable + clock past expiry → honest expired state.
        guard case .sessionExpired = await coordinator.phase else {
            Issue.record("expected sessionExpired, got \(await coordinator.phase)"); return
        }
    }

    @Test func concurrentRefreshersShareOneInFlightRefresh() async {
        let (coordinator, provider, _, clock) = makeStack()
        await provider.set(signIn: .succeed(roles: [.client], account: "acct-1", ttl: 100))
        await coordinator.signIn(.development(identity: "x"))
        clock.advance(by: 50)
        async let a = coordinator.ensureValidSession()
        async let b = coordinator.ensureValidSession()
        async let c = coordinator.ensureValidSession()
        _ = await (a, b, c)
        #expect(await provider.refreshCalls == 1) // deduplicated
    }

    @Test func signOutClearsCredentialsAndConfirmsRemote() async throws {
        let (coordinator, provider, store, _) = makeStack()
        await coordinator.signIn(.development(identity: "x"))
        let phase = await coordinator.signOut()
        #expect(phase == .signedOut(pendingRemoteRevocation: false))
        #expect(try await store.loadCurrent() == nil)
        #expect(await provider.signOutCalls == 1)
    }

    @Test func offlineSignOutIsHonestAboutPendingRemoteRevocation() async throws {
        let (coordinator, provider, store, _) = makeStack()
        await provider.set(signOutError: AuthError.networkUnavailable)
        await coordinator.signIn(.development(identity: "x"))
        let phase = await coordinator.signOut()
        // Local credentials are gone, but remote revocation is NOT claimed.
        #expect(phase == .signedOut(pendingRemoteRevocation: true))
        #expect(try await store.loadCurrent() == nil)
    }

    @Test func delayedSignInResultAfterCancellationIsDiscarded() async throws {
        let (coordinator, provider, store, _) = makeStack()
        await provider.gateNextCall() // the provider will hang until released
        let pending = Task { await coordinator.signIn(.development(identity: "x")) }
        while await coordinator.phase != .authenticating { await Task.yield() }

        // The user abandons the hung attempt: generation bumps, back to signed out.
        await coordinator.cancelAuthentication()
        #expect(await coordinator.phase == .signedOut(pendingRemoteRevocation: false))

        // The provider finally answers — a stale success that must be discarded:
        // no session is resurrected and no credentials are written.
        await provider.release()
        _ = await pending.value
        #expect(await coordinator.phase == .signedOut(pendingRemoteRevocation: false))
        #expect(try await store.loadCurrent() == nil)
    }

    @Test func delayedRefreshAfterSignOutCannotReactivateSession() async throws {
        let (coordinator, provider, store, clock) = makeStack()
        await provider.set(signIn: .succeed(roles: [.client], account: "acct-1", ttl: 100))
        await coordinator.signIn(.development(identity: "x"))
        clock.advance(by: 50)
        await provider.gateNextCall() // refresh will suspend
        let refreshTask = Task { await coordinator.ensureValidSession() }
        // Wait until the refresh is actually in flight (phase == refreshing).
        while true {
            if case .refreshing = await coordinator.phase { break }
            await Task.yield()
        }
        // Sign out while the refresh hangs: generation bumps, credentials cleared.
        _ = await coordinator.signOut()
        #expect(await coordinator.phase == .signedOut(pendingRemoteRevocation: false))
        await provider.release() // stale refresh completes now
        _ = await refreshTask.value
        // The stale refresh result must NOT reactivate the session or rewrite creds.
        #expect(await coordinator.phase == .signedOut(pendingRemoteRevocation: false))
        #expect(try await store.loadCurrent() == nil)
    }

    @Test func revocationDiscoveredOnReconnectSignsSessionOut() async throws {
        let (coordinator, provider, store, _) = makeStack()
        await coordinator.signIn(.development(identity: "x"))
        await provider.set(revocation: .revoked)
        await coordinator.checkRevocationAfterReconnect()
        guard case .revoked = await coordinator.phase else {
            Issue.record("expected revoked, got \(await coordinator.phase)"); return
        }
        #expect(try await store.loadCurrent() == nil)
    }

    @Test func unknownRevocationAnswerChangesNothing() async {
        let (coordinator, provider, _, _) = makeStack()
        await coordinator.signIn(.development(identity: "x"))
        await provider.set(revocation: .unknown)
        await coordinator.checkRevocationAfterReconnect()
        guard case .authenticated = await coordinator.phase else {
            Issue.record("expected authenticated, got \(await coordinator.phase)"); return
        }
    }

    @Test func rapidSignInSignOutCyclesStayConsistent() async throws {
        let (coordinator, _, store, _) = makeStack()
        for _ in 0..<5 {
            let signedIn = await coordinator.signIn(.development(identity: "x"))
            guard case .authenticated = signedIn else {
                Issue.record("cycle failed to authenticate: \(signedIn)"); return
            }
            let signedOut = await coordinator.signOut()
            #expect(signedOut == .signedOut(pendingRemoteRevocation: false))
        }
        #expect(try await store.loadCurrent() == nil)
        let finalGeneration = await coordinator.generation
        #expect(finalGeneration == 10) // 5 sign-ins + 5 sign-outs, strictly monotonic
    }

    @Test func lockAndUnlockRoundTrip() async {
        let (coordinator, _, _, _) = makeStack()
        await coordinator.signIn(.development(identity: "x"))
        await coordinator.lock()
        guard case .locked = await coordinator.phase else {
            Issue.record("expected locked"); return
        }
        #expect(await coordinator.phase.allowsAccountDataAccess == false)
        await coordinator.unlock()
        guard case .authenticated = await coordinator.phase else {
            Issue.record("expected authenticated after unlock"); return
        }
    }
}
