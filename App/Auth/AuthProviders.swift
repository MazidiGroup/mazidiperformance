import Foundation
import MazidiAuth

/// Release-mode provider slot: no production authentication backend exists yet (R-01),
/// and none is fabricated. Every operation fails typed; the signed-out screen explains
/// honestly that sign-in arrives with the backend contract.
struct UnavailableAuthProvider: AuthProviding {
    func signIn(_ request: SignInRequest) async throws -> ProviderSession {
        throw AuthError.providerUnavailable
    }

    func refresh(refreshToken: String, accountID: AccountID) async throws -> ProviderSession {
        throw AuthError.providerUnavailable
    }

    func restore(credentials: AuthCredentials) async throws -> RestoredSession {
        throw AuthError.providerUnavailable
    }

    func signOut(accessToken: String, accountID: AccountID) async throws {
        // Local sign-out always succeeds; there is no server to notify yet. Reported
        // as not-remotely-confirmed by the coordinator (pendingRemoteRevocation).
        throw AuthError.providerUnavailable
    }

    func checkRevocation(accountID: AccountID) async -> RevocationCheck { .unknown }
}

#if DEBUG
/// FIXTURE — deterministic development identities for DEBUG builds, previews and UI
/// tests only (ADR-0008 §6). This type does not exist in Release builds; there are no
/// production credentials here, and dev tokens (prefix "dev.") are only ever accepted
/// by this provider.
struct DevelopmentAuthProvider: AuthProviding {
    /// Stable test identities. Two client accounts exist so account-switch isolation
    /// is testable; identifiers are fixture-labelled and never real users.
    static let identities: [String: Set<RoleClaim>] = [
        "dev-client-001": [.client],
        "dev-client-002": [.client],
        "dev-coach-001": [.coach],
        // Deliberately broken fixtures for the safe-error-state journeys:
        "dev-no-role": [],
        "dev-conflicted": [.coach, .client],
    ]

    private let tokenLifetime: TimeInterval = 3600

    private func mint(identity: String, roles: Set<RoleClaim>) -> ProviderSession {
        let account = AccountID(identity)
        let now = Date()
        return ProviderSession(
            claims: SessionClaims(accountID: account, roles: roles),
            credentials: AuthCredentials(
                accountID: account,
                accessToken: "dev.access.\(identity).\(UUID().uuidString)",
                refreshToken: "dev.refresh.\(identity).\(UUID().uuidString)",
                accessTokenExpiresAt: now.addingTimeInterval(tokenLifetime)
            ),
            authenticatedAt: now
        )
    }

    func signIn(_ request: SignInRequest) async throws -> ProviderSession {
        guard case let .development(identity) = request else {
            throw AuthError.providerUnavailable // dev provider only mints dev identities
        }
        guard let roles = Self.identities[identity] else {
            throw AuthError.invalidCredentials
        }
        return mint(identity: identity, roles: roles)
    }

    func refresh(refreshToken: String, accountID: AccountID) async throws -> ProviderSession {
        guard refreshToken.hasPrefix("dev.refresh."),
              let roles = Self.identities[accountID.rawValue] else {
            throw AuthError.refreshRejected
        }
        return mint(identity: accountID.rawValue, roles: roles)
    }

    func restore(credentials: AuthCredentials) async throws -> RestoredSession {
        guard credentials.accessToken.hasPrefix("dev.access."),
              let roles = DevelopmentAuthProvider.identities[credentials.accountID.rawValue] else {
            throw AuthError.invalidCredentials
        }
        // The dev provider validates locally and says so — never "validated remotely".
        return RestoredSession(
            claims: SessionClaims(accountID: credentials.accountID, roles: roles),
            rotatedCredentials: nil,
            validatedRemotely: false
        )
    }

    func signOut(accessToken: String, accountID: AccountID) async throws {
        // Deterministic local success (no server exists); the coordinator records the
        // sign-out as remotely confirmed for dev sessions.
    }

    func checkRevocation(accountID: AccountID) async -> RevocationCheck { .unknown }
}
#endif
