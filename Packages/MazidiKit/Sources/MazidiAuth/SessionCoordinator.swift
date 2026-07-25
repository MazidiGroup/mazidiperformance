import Foundation
import MazidiFoundations

/// Drives the `AuthPhase` machine (ADR-0008). The single writer of session state:
/// - splits provider results into state (claims) and Keychain (secrets),
/// - protects against stale async results with a monotonically increasing **generation**
///   (bumped on every sign-in attempt, sign-out, and switch — results carrying an old
///   generation are discarded, so a delayed provider response can never reactivate a
///   session or leak into another account),
/// - deduplicates concurrent refreshes into one in-flight task,
/// - evaluates expiry against the injected clock only (deterministic tests).
public actor SessionCoordinator {
    public private(set) var phase: AuthPhase = .signedOut(pendingRemoteRevocation: false)
    /// Session generation. Everything account-scoped the app builds is tagged with this;
    /// the app tears down on change (stale-task protection, ADR-0008 §8).
    public private(set) var generation: UInt64 = 0

    private let provider: any AuthProviding
    private let credentials: any CredentialStore
    private let clock: any AppClock
    private let log: AppLog
    private var refreshInFlight: Task<AuthPhase, Never>?
    private var observers: [UUID: AsyncStream<AuthPhase>.Continuation] = [:]

    public init(
        provider: any AuthProviding,
        credentials: any CredentialStore,
        clock: any AppClock = SystemClock(),
        log: AppLog = AppLog(category: "auth")
    ) {
        self.provider = provider
        self.credentials = credentials
        self.clock = clock
        self.log = log
    }

    // MARK: - Observation

    /// Phase stream for the app root. Emits the current phase immediately, then changes.
    public func phases() -> AsyncStream<AuthPhase> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(phase)
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func apply(_ event: AuthEvent) {
        guard let next = phase.reduced(by: event) else {
            log.error("Ignored illegal auth event \(event) in phase \(phase)")
            return
        }
        phase = next
        for continuation in observers.values { continuation.yield(next) }
    }

    // MARK: - Launch restoration

    /// Restore a previous session from stored credentials. Offline restore lands in
    /// `offlineAuthenticated` (honest local-only); no credentials leaves `signedOut`.
    public func restoreOnLaunch() async {
        guard case .signedOut = phase else { return }
        let stored: AuthCredentials?
        do {
            stored = try await credentials.loadCurrent()
        } catch {
            log.error("Credential store unavailable during restore: \(error)")
            apply(.restoreFoundNothing)
            return
        }
        guard let stored else {
            apply(.restoreFoundNothing)
            return
        }
        let myGeneration = generation
        do {
            let restored = try await provider.restore(credentials: stored)
            guard generation == myGeneration else { return } // stale (signed out meanwhile)
            if let rotated = restored.rotatedCredentials {
                try? await credentials.save(rotated)
            }
            let session = AuthSession(
                claims: restored.claims,
                issuedAt: stored.accessTokenExpiresAt,
                accessTokenExpiresAt: (restored.rotatedCredentials ?? stored).accessTokenExpiresAt,
                lastAuthenticatedAt: stored.accessTokenExpiresAt
            )
            apply(.restoreSucceeded(session, validatedRemotely: restored.validatedRemotely))
            evaluateExpiry()
        } catch AuthError.revoked {
            guard generation == myGeneration else { return }
            try? await credentials.delete(for: stored.accountID)
            apply(.restoreFoundRevoked(SessionClaims(accountID: stored.accountID, roles: [])))
        } catch {
            guard generation == myGeneration else { return }
            log.error("Restore failed; remaining signed out")
            apply(.restoreFoundNothing)
        }
    }

    // MARK: - Sign-in

    @discardableResult
    public func signIn(_ request: SignInRequest) async -> AuthPhase {
        generation &+= 1
        let myGeneration = generation
        apply(.signInStarted)
        do {
            let result = try await provider.signIn(request)
            guard generation == myGeneration else { return phase } // stale: discarded
            try await credentials.save(result.credentials)
            let session = AuthSession(
                claims: result.claims,
                issuedAt: result.authenticatedAt,
                accessTokenExpiresAt: result.credentials.accessTokenExpiresAt,
                lastAuthenticatedAt: result.authenticatedAt
            )
            apply(.signInSucceeded(session))
        } catch let error as AuthError {
            guard generation == myGeneration else { return phase }
            apply(.signInFailed(error))
        } catch let error as CredentialStoreError {
            guard generation == myGeneration else { return phase }
            apply(.signInFailed(.credentialStorage(error)))
        } catch {
            guard generation == myGeneration else { return phase }
            apply(.signInFailed(.internalInconsistency(String(describing: type(of: error)))))
        }
        return phase
    }

    /// Acknowledge a sign-in failure and return to the signed-out surface.
    public func acknowledgeFailure() { apply(.retryFromFailure) }

    /// Abandon an in-flight sign-in. Bumps the generation so the provider's eventual
    /// (stale) answer is discarded — it can never authenticate a session the user
    /// already walked away from.
    public func cancelAuthentication() {
        guard case .authenticating = phase else { return }
        generation &+= 1
        apply(.signInCancelled)
    }

    // MARK: - Refresh & expiry

    /// Ensure the session is valid, refreshing when near expiry. Concurrent callers
    /// share one in-flight refresh (deduplication).
    @discardableResult
    public func ensureValidSession() async -> AuthPhase {
        if let inFlight = refreshInFlight { return await inFlight.value }
        evaluateExpiry()
        guard let session = phase.session else { return phase }
        guard session.isNearExpiry(at: clock.now()) else { return phase }
        let task = Task { await self.performRefresh() }
        refreshInFlight = task
        let result = await task.value
        refreshInFlight = nil
        return result
    }

    private func performRefresh() async -> AuthPhase {
        guard let session = phase.session else { return phase }
        let myGeneration = generation
        let accountID = session.claims.accountID
        let stored: AuthCredentials
        do {
            stored = try await credentials.load(for: accountID)
        } catch {
            apply(.refreshStarted)
            apply(.refreshRejected) // no refresh token = must reauthenticate
            return phase
        }
        apply(.refreshStarted)
        do {
            let fresh = try await provider.refresh(refreshToken: stored.refreshToken, accountID: accountID)
            // Stale refresh results must never reactivate a session after sign-out or
            // account switch (ADR-0008 §9).
            guard generation == myGeneration else { return phase }
            try await credentials.save(fresh.credentials)
            let renewed = AuthSession(
                claims: fresh.claims,
                issuedAt: fresh.authenticatedAt,
                accessTokenExpiresAt: fresh.credentials.accessTokenExpiresAt,
                lastAuthenticatedAt: session.lastAuthenticatedAt
            )
            apply(.refreshSucceeded(renewed))
        } catch AuthError.networkUnavailable {
            guard generation == myGeneration else { return phase }
            apply(.refreshUnreachable)
            evaluateExpiry()
        } catch AuthError.revoked {
            guard generation == myGeneration else { return phase }
            try? await credentials.delete(for: accountID)
            apply(.revocationDiscovered)
        } catch {
            guard generation == myGeneration else { return phase }
            apply(.refreshRejected)
        }
        return phase
    }

    /// Emit `.expiryReached` when the injected clock has passed the token expiry.
    public func evaluateExpiry() {
        if let session = phase.session, session.isAccessTokenExpired(at: clock.now()) {
            apply(.expiryReached)
        }
    }

    /// Reconnect hook: ask the provider whether we were revoked while away. `.unknown`
    /// changes nothing (never fabricated into certainty).
    public func checkRevocationAfterReconnect() async {
        guard let session = phase.session else { return }
        let myGeneration = generation
        let check = await provider.checkRevocation(accountID: session.claims.accountID)
        guard generation == myGeneration else { return }
        if check == .revoked {
            try? await credentials.delete(for: session.claims.accountID)
            apply(.revocationDiscovered)
        }
    }

    /// The backend sync transport reported this session **confirmed revoked**
    /// (`TransportError.revoked` / `RevocationState.revoked`; ADR-0012 §8). Only call this
    /// for a CONFIRMED revocation — never for `.unknown` (offline can never claim current
    /// revocation knowledge). Generation-guarded: a delayed response carrying a prior
    /// session's generation is ignored, so it can never revoke the now-active session. On a
    /// confirmed match this bumps the generation (invalidating outstanding work so no pending
    /// mutation uploads afterwards), deletes credentials, and moves to `.revoked` — the app
    /// then closes the account database on the phase/generation change (existing sign-out
    /// boundary). No "sign out everywhere" is claimed (that needs real backend support).
    @discardableResult
    public func revocationReported(forGeneration reportedGeneration: UInt64) async -> AuthPhase {
        guard reportedGeneration == generation, let session = phase.session else { return phase }
        generation &+= 1
        try? await credentials.delete(for: session.claims.accountID)
        apply(.revocationDiscovered)
        return phase
    }

    // MARK: - Sign-out

    /// Full sign-out sequence (SECURITY_BOUNDARIES.md): state → provider revocation
    /// (best-effort) → credential deletion → completion with honest remote status.
    /// The app layer closes the account database on the phase/generation change.
    @discardableResult
    public func signOut() async -> AuthPhase {
        guard let session = phase.session else { return phase }
        generation &+= 1 // immediately invalidates all outstanding async results
        apply(.signOutStarted)
        let accountID = session.claims.accountID
        var remoteConfirmed = false
        if let stored = try? await credentials.load(for: accountID) {
            do {
                try await provider.signOut(accessToken: stored.accessToken, accountID: accountID)
                remoteConfirmed = true
            } catch {
                log.error("Remote sign-out undeliverable; completing locally")
            }
        }
        try? await credentials.delete(for: accountID)
        apply(.signOutCompleted(remoteConfirmed: remoteConfirmed))
        return phase
    }

    // MARK: - Lock

    public func lock() { apply(.lockRequested) }
    public func unlock() { apply(.unlockSucceeded) }
}
