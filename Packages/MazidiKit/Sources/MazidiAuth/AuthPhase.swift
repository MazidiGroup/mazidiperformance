import Foundation

/// The authentication/session state machine (ADR-0008 §2). Explicit states — never a
/// Boolean — with every legal transition defined by the pure reducer below. The
/// `SessionCoordinator` actor is the only writer; illegal events are ignored (state
/// unchanged) and reported to the caller for logging.
public enum AuthPhase: Sendable, Equatable {
    /// No session. `pendingRemoteRevocation` is true after an offline sign-out whose
    /// server-side revocation could not be delivered — shown honestly, never claimed
    /// as remotely confirmed.
    case signedOut(pendingRemoteRevocation: Bool)
    case authenticating
    case authenticated(AuthSession)
    /// A refresh is in flight for the current session (still usable meanwhile).
    case refreshing(AuthSession)
    /// Previously valid session, currently unreachable provider — local-only, honest.
    case offlineAuthenticated(AuthSession)
    /// Access token expired and refresh has not succeeded; local data remains readable,
    /// server-validated actions are gated (SECURITY_BOUNDARIES.md offline policy).
    case sessionExpired(AuthSession)
    /// The provider rejected the refresh token — the user must sign in again.
    case reauthenticationRequired(AuthSession)
    case signingOut(AuthSession)
    /// Local lock surface (13c). Policy/biometrics deferred; the state is modelled so
    /// the wiring exists (KNOWN_ISSUES).
    case locked(AuthSession)
    case authenticationFailed(AuthError)
    /// Remote revocation discovered (provider report or reconnect check).
    case revoked(SessionClaims)

    /// The session, in any state that has one.
    public var session: AuthSession? {
        switch self {
        case let .authenticated(s), let .refreshing(s), let .offlineAuthenticated(s),
             let .sessionExpired(s), let .reauthenticationRequired(s),
             let .signingOut(s), let .locked(s):
            return s
        case .signedOut, .authenticating, .authenticationFailed, .revoked:
            return nil
        }
    }

    /// True when account-scoped data may be presented (ADR-0008 offline policy: expired
    /// and reauth-required still permit reading local data; signingOut/locked/revoked do
    /// not present data).
    public var allowsAccountDataAccess: Bool {
        switch self {
        case .authenticated, .refreshing, .offlineAuthenticated, .sessionExpired,
             .reauthenticationRequired:
            return true
        case .signedOut, .authenticating, .signingOut, .locked,
             .authenticationFailed, .revoked:
            return false
        }
    }
}

/// Every input the machine reacts to.
public enum AuthEvent: Sendable, Equatable {
    case signInStarted
    case signInSucceeded(AuthSession)
    case signInFailed(AuthError)
    /// The user abandoned an in-flight sign-in attempt.
    case signInCancelled
    case restoreSucceeded(AuthSession, validatedRemotely: Bool)
    case restoreFoundNothing
    /// Launch restore found stored credentials that the provider reports as revoked.
    case restoreFoundRevoked(SessionClaims)
    case refreshStarted
    case refreshSucceeded(AuthSession)
    /// Unreachable ≠ rejected: unreachable keeps the session (offline), rejected
    /// requires reauthentication.
    case refreshUnreachable
    case refreshRejected
    case expiryReached
    case signOutStarted
    case signOutCompleted(remoteConfirmed: Bool)
    case lockRequested
    case unlockSucceeded
    case revocationDiscovered
    case retryFromFailure
}

public extension AuthPhase {
    /// Pure, deterministic transition function. Returns the next state, or nil when the
    /// event is illegal in the current state (caller keeps the state and may log).
    func reduced(by event: AuthEvent) -> AuthPhase? {
        switch (self, event) {
        // Sign-in
        case (.signedOut, .signInStarted),
             (.authenticationFailed, .signInStarted),
             (.reauthenticationRequired, .signInStarted),
             (.revoked, .signInStarted):
            return .authenticating
        case let (.authenticating, .signInSucceeded(session)):
            return .authenticated(session)
        case let (.authenticating, .signInFailed(error)):
            return .authenticationFailed(error)
        case (.authenticating, .signInCancelled):
            return .signedOut(pendingRemoteRevocation: false)
        case (.authenticationFailed, .retryFromFailure):
            return .signedOut(pendingRemoteRevocation: false)

        // Restoration (launch)
        case let (.signedOut, .restoreSucceeded(session, validatedRemotely)):
            return validatedRemotely ? .authenticated(session) : .offlineAuthenticated(session)
        case (.signedOut, .restoreFoundNothing):
            return self
        case let (.signedOut, .restoreFoundRevoked(claims)):
            return .revoked(claims)

        // Refresh
        case let (.authenticated(s), .refreshStarted),
             let (.offlineAuthenticated(s), .refreshStarted),
             let (.sessionExpired(s), .refreshStarted):
            return .refreshing(s)
        case let (.refreshing, .refreshSucceeded(fresh)):
            return .authenticated(fresh)
        // Unreachable keeps the session in the honest offline state; the coordinator
        // separately emits `.expiryReached` when the injected clock says so (the reducer
        // itself is clock-free and pure).
        case let (.refreshing(s), .refreshUnreachable):
            return .offlineAuthenticated(s)
        case let (.refreshing(s), .refreshRejected):
            return .reauthenticationRequired(s)

        // Expiry
        case let (.authenticated(s), .expiryReached),
             let (.offlineAuthenticated(s), .expiryReached):
            return .sessionExpired(s)

        // Sign-out (legal from any session-holding state)
        case let (.authenticated(s), .signOutStarted),
             let (.refreshing(s), .signOutStarted),
             let (.offlineAuthenticated(s), .signOutStarted),
             let (.sessionExpired(s), .signOutStarted),
             let (.reauthenticationRequired(s), .signOutStarted),
             let (.locked(s), .signOutStarted):
            return .signingOut(s)
        case let (.signingOut, .signOutCompleted(remoteConfirmed)):
            return .signedOut(pendingRemoteRevocation: !remoteConfirmed)

        // Lock
        case let (.authenticated(s), .lockRequested),
             let (.offlineAuthenticated(s), .lockRequested):
            return .locked(s)
        case let (.locked(s), .unlockSucceeded):
            return .authenticated(s)

        // Revocation discovery (any session-holding state)
        case let (.authenticated(s), .revocationDiscovered),
             let (.refreshing(s), .revocationDiscovered),
             let (.offlineAuthenticated(s), .revocationDiscovered),
             let (.sessionExpired(s), .revocationDiscovered),
             let (.reauthenticationRequired(s), .revocationDiscovered),
             let (.locked(s), .revocationDiscovered):
            return .revoked(s.claims)

        default:
            return nil
        }
    }
}
