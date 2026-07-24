import Foundation
import Testing
@testable import MazidiAuth

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

func makeSession(
    roles: Set<RoleClaim> = [.client],
    account: String = "acct-1",
    expiresIn: TimeInterval = 3600
) -> AuthSession {
    AuthSession(
        claims: SessionClaims(accountID: AccountID(account), roles: roles),
        issuedAt: t0,
        accessTokenExpiresAt: t0.addingTimeInterval(expiresIn),
        lastAuthenticatedAt: t0
    )
}

@Suite struct AuthPhaseReducerTests {
    let session = makeSession()

    @Test func fullSignInLifecycle() {
        var phase = AuthPhase.signedOut(pendingRemoteRevocation: false)
        phase = phase.reduced(by: .signInStarted)!
        #expect(phase == .authenticating)
        phase = phase.reduced(by: .signInSucceeded(session))!
        #expect(phase == .authenticated(session))
        phase = phase.reduced(by: .signOutStarted)!
        #expect(phase == .signingOut(session))
        phase = phase.reduced(by: .signOutCompleted(remoteConfirmed: true))!
        #expect(phase == .signedOut(pendingRemoteRevocation: false))
    }

    @Test func offlineSignOutIsReportedAsPendingRemoteRevocation() {
        var phase = AuthPhase.signingOut(session)
        phase = phase.reduced(by: .signOutCompleted(remoteConfirmed: false))!
        #expect(phase == .signedOut(pendingRemoteRevocation: true))
    }

    @Test func signInFailureAndRetry() {
        var phase = AuthPhase.authenticating
        phase = phase.reduced(by: .signInFailed(.invalidCredentials))!
        #expect(phase == .authenticationFailed(.invalidCredentials))
        // Retry path 1: acknowledge back to signed out.
        #expect(phase.reduced(by: .retryFromFailure) == .signedOut(pendingRemoteRevocation: false))
        // Retry path 2: straight into a new attempt.
        #expect(phase.reduced(by: .signInStarted) == .authenticating)
    }

    @Test func restoreOutcomes() {
        let signedOut = AuthPhase.signedOut(pendingRemoteRevocation: false)
        #expect(signedOut.reduced(by: .restoreSucceeded(session, validatedRemotely: true)) == .authenticated(session))
        #expect(signedOut.reduced(by: .restoreSucceeded(session, validatedRemotely: false)) == .offlineAuthenticated(session))
        #expect(signedOut.reduced(by: .restoreFoundNothing) == signedOut)
        #expect(signedOut.reduced(by: .restoreFoundRevoked(session.claims)) == .revoked(session.claims))
    }

    @Test func refreshOutcomes() {
        let fresh = makeSession(expiresIn: 7200)
        var phase = AuthPhase.authenticated(session)
        phase = phase.reduced(by: .refreshStarted)!
        #expect(phase == .refreshing(session))
        #expect(phase.reduced(by: .refreshSucceeded(fresh)) == .authenticated(fresh))
        #expect(phase.reduced(by: .refreshUnreachable) == .offlineAuthenticated(session))
        #expect(phase.reduced(by: .refreshRejected) == .reauthenticationRequired(session))
    }

    @Test func expiryFromAuthenticatedAndOffline() {
        #expect(AuthPhase.authenticated(session).reduced(by: .expiryReached) == .sessionExpired(session))
        #expect(AuthPhase.offlineAuthenticated(session).reduced(by: .expiryReached) == .sessionExpired(session))
    }

    @Test func expiredSessionCanRefreshOrSignOut() {
        let expired = AuthPhase.sessionExpired(session)
        #expect(expired.reduced(by: .refreshStarted) == .refreshing(session))
        #expect(expired.reduced(by: .signOutStarted) == .signingOut(session))
    }

    @Test func reauthenticationRequiredAllowsNewSignInAndSignOut() {
        let reauth = AuthPhase.reauthenticationRequired(session)
        #expect(reauth.reduced(by: .signInStarted) == .authenticating)
        #expect(reauth.reduced(by: .signOutStarted) == .signingOut(session))
    }

    @Test func lockAndUnlock() {
        var phase = AuthPhase.authenticated(session)
        phase = phase.reduced(by: .lockRequested)!
        #expect(phase == .locked(session))
        #expect(phase.reduced(by: .unlockSucceeded) == .authenticated(session))
        #expect(phase.reduced(by: .signOutStarted) == .signingOut(session))
    }

    @Test func revocationDiscoveredFromEverySessionHoldingState() {
        let holders: [AuthPhase] = [
            .authenticated(session), .refreshing(session), .offlineAuthenticated(session),
            .sessionExpired(session), .reauthenticationRequired(session), .locked(session),
        ]
        for phase in holders {
            #expect(phase.reduced(by: .revocationDiscovered) == .revoked(session.claims))
        }
        // Revoked allows a fresh sign-in.
        #expect(AuthPhase.revoked(session.claims).reduced(by: .signInStarted) == .authenticating)
    }

    @Test func illegalEventsLeaveStateUnchanged() {
        // A delayed sign-in result after sign-out must not resurrect a session.
        #expect(AuthPhase.signedOut(pendingRemoteRevocation: false)
            .reduced(by: .signInSucceeded(session)) == nil)
        // A stale refresh result with no refresh in flight is illegal.
        #expect(AuthPhase.authenticated(session).reduced(by: .refreshSucceeded(session)) == nil)
        // Sign-out cannot complete when not signing out.
        #expect(AuthPhase.authenticated(session).reduced(by: .signOutCompleted(remoteConfirmed: true)) == nil)
        // Cannot sign out with no session.
        #expect(AuthPhase.signedOut(pendingRemoteRevocation: false).reduced(by: .signOutStarted) == nil)
    }

    @Test func dataAccessPolicyPerState() {
        #expect(AuthPhase.authenticated(session).allowsAccountDataAccess)
        #expect(AuthPhase.refreshing(session).allowsAccountDataAccess)
        #expect(AuthPhase.offlineAuthenticated(session).allowsAccountDataAccess)
        #expect(AuthPhase.sessionExpired(session).allowsAccountDataAccess)
        #expect(AuthPhase.reauthenticationRequired(session).allowsAccountDataAccess)
        #expect(!AuthPhase.signedOut(pendingRemoteRevocation: false).allowsAccountDataAccess)
        #expect(!AuthPhase.signingOut(session).allowsAccountDataAccess)
        #expect(!AuthPhase.locked(session).allowsAccountDataAccess)
        #expect(!AuthPhase.revoked(session.claims).allowsAccountDataAccess)
        #expect(!AuthPhase.authenticating.allowsAccountDataAccess)
        #expect(!AuthPhase.authenticationFailed(.invalidCredentials).allowsAccountDataAccess)
    }

    @Test func roleClaimRouting() {
        #expect(SessionClaims(accountID: AccountID("a"), roles: [.client]).routableRole == .client)
        #expect(SessionClaims(accountID: AccountID("a"), roles: [.coach]).routableRole == .coach)
        #expect(SessionClaims(accountID: AccountID("a"), roles: []).routableRole == nil)
        #expect(SessionClaims(accountID: AccountID("a"), roles: [.coach, .client]).routableRole == nil)
    }
}
