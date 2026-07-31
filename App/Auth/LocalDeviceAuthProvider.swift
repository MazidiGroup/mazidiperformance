#if LOCAL_IDENTITY
import Foundation
import MazidiAuth

/// LOCAL TEST PROFILE PROVIDER — **not an authentication provider** (ADR-0014).
///
/// It verifies nothing and proves nothing: it hands the `SessionCoordinator` a
/// device-local identity so the app can be opened and exercised on a real device while no
/// backend exists (R-01). Compiled only under `LOCAL_IDENTITY` (Debug + Staging, the
/// TestFlight configuration). Release keeps `UnavailableAuthProvider`, so an App Store
/// build still cannot get past the signed-out surface by any means.
///
/// Everything else about the session is unchanged and deliberately **not** bypassed: the
/// `AuthPhase` machine, generations, credential storage, account-scoped database
/// derivation and teardown all run exactly as they do for a real provider — this type only
/// occupies the provider slot.
///
/// In DEBUG it also forwards the existing development fixture identities
/// (`dev-client-001`, …) to `DevelopmentAuthProvider`, so the ADR-0008 §6 development and
/// UI-test journeys keep working unchanged. That forwarding does not exist in Staging.
struct LocalDeviceAuthProvider: AuthProviding {
    private let profiles: any LocalDeviceProfileStoring
    #if DEBUG
    /// DEBUG-only passthrough for the deterministic fixture identities (ADR-0008 §6).
    private let developmentProvider = DevelopmentAuthProvider()
    #endif

    init(profiles: any LocalDeviceProfileStoring) {
        self.profiles = profiles
    }

    // MARK: - AuthProviding

    func signIn(_ request: SignInRequest) async throws -> ProviderSession {
        guard case let .development(identity) = request,
              let role = LocalDeviceAccount.requestedRole(fromSignInIdentity: identity) else {
            return try await forwardSignIn(request)
        }
        var profile = try await currentProfile()
        // The chosen role is stored alongside the identity, so the device remembers it.
        if profile.lastSelectedRole != role {
            profile.lastSelectedRole = role
            try await store(profile)
        }
        return mint(LocalDeviceAccount(deviceID: profile.deviceID, role: role))
    }

    func refresh(refreshToken: String, accountID: AccountID) async throws -> ProviderSession {
        guard refreshToken.hasPrefix(LocalDeviceAccount.tokenPrefix),
              let account = LocalDeviceAccount(accountID: accountID) else {
            return try await forwardRefresh(refreshToken: refreshToken, accountID: accountID)
        }
        // Nothing can be "refreshed" locally; re-minting keeps the coordinator's contract
        // satisfied without claiming a server ever answered.
        guard try await currentProfile().deviceID == account.deviceID else {
            throw AuthError.refreshRejected
        }
        return mint(account)
    }

    func restore(credentials: AuthCredentials) async throws -> RestoredSession {
        guard credentials.accessToken.hasPrefix(LocalDeviceAccount.tokenPrefix),
              let account = LocalDeviceAccount(accountID: credentials.accountID) else {
            return try await forwardRestore(credentials: credentials)
        }
        // A stored profile for a different device UUID (restored backup, wiped Keychain)
        // must not open that account's data — it is not this device's profile.
        guard let profile = try await loadProfile(), profile.deviceID == account.deviceID else {
            throw AuthError.invalidCredentials
        }
        // Validated locally, and said so: nothing was checked with a server.
        return RestoredSession(
            claims: SessionClaims(accountID: account.accountID, roles: [account.role]),
            rotatedCredentials: nil,
            validatedRemotely: false
        )
    }

    func signOut(accessToken: String, accountID: AccountID) async throws {
        guard accessToken.hasPrefix(LocalDeviceAccount.tokenPrefix) else {
            try await forwardSignOut(accessToken: accessToken, accountID: accountID)
            return
        }
        // There is no server session to end, so leaving the profile is complete the moment
        // local state is cleared. Returning normally keeps the coordinator from showing the
        // "other devices update when back online" notice, which would be untrue here.
    }

    func checkRevocation(accountID: AccountID) async -> RevocationCheck {
        // No issuer exists, so revocation is unknowable — never fabricated into certainty.
        .unknown
    }

    // MARK: - Minting

    private func mint(_ account: LocalDeviceAccount) -> ProviderSession {
        ProviderSession(
            claims: SessionClaims(accountID: account.accountID, roles: [account.role]),
            credentials: LocalDeviceAccount.localCredentials(for: account),
            authenticatedAt: Date()
        )
    }

    // MARK: - Profile storage

    private func loadProfile() async throws -> LocalDeviceProfile? {
        do {
            return try await profiles.load()
        } catch let error as CredentialStoreError {
            throw AuthError.credentialStorage(error)
        }
    }

    private func currentProfile() async throws -> LocalDeviceProfile {
        do {
            return try await profiles.loadOrCreate()
        } catch let error as CredentialStoreError {
            throw AuthError.credentialStorage(error)
        }
    }

    private func store(_ profile: LocalDeviceProfile) async throws {
        do {
            try await profiles.save(profile)
        } catch let error as CredentialStoreError {
            throw AuthError.credentialStorage(error)
        }
    }

    // MARK: - Development fixture passthrough (DEBUG only)

    private func forwardSignIn(_ request: SignInRequest) async throws -> ProviderSession {
        #if DEBUG
        return try await developmentProvider.signIn(request)
        #else
        throw AuthError.providerUnavailable
        #endif
    }

    private func forwardRefresh(refreshToken: String, accountID: AccountID) async throws -> ProviderSession {
        #if DEBUG
        return try await developmentProvider.refresh(refreshToken: refreshToken, accountID: accountID)
        #else
        throw AuthError.refreshRejected
        #endif
    }

    private func forwardRestore(credentials: AuthCredentials) async throws -> RestoredSession {
        #if DEBUG
        return try await developmentProvider.restore(credentials: credentials)
        #else
        throw AuthError.invalidCredentials
        #endif
    }

    private func forwardSignOut(accessToken: String, accountID: AccountID) async throws {
        #if DEBUG
        try await developmentProvider.signOut(accessToken: accessToken, accountID: accountID)
        #endif
    }
}
#endif
