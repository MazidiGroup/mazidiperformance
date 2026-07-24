import Foundation

/// What a provider returns from sign-in/refresh: claims + fresh secret material.
/// The coordinator splits it — claims into state, secrets into the credential store.
public struct ProviderSession: Sendable, Equatable {
    public let claims: SessionClaims
    public let credentials: AuthCredentials
    public let authenticatedAt: Date

    public init(claims: SessionClaims, credentials: AuthCredentials, authenticatedAt: Date) {
        self.claims = claims
        self.credentials = credentials
        self.authenticatedAt = authenticatedAt
    }
}

/// Provider-neutral sign-in request. Development identities use `.development(id:)`;
/// production requests (password/OAuth/passkey) are added with the provider ADR — the
/// coordinator does not change when they are.
public enum SignInRequest: Sendable, Equatable {
    /// DEBUG-only deterministic identity, e.g. "dev-client-001". Rejected by any
    /// non-development provider.
    case development(identity: String)
    case emailPassword(email: String, password: String)
}

/// The provider-neutral authentication boundary (ADR-0008 §1). No provider SDK types
/// cross it. All calls are async and may throw `AuthError` only.
public protocol AuthProviding: Sendable {
    /// Authenticate and mint a session.
    func signIn(_ request: SignInRequest) async throws -> ProviderSession

    /// Exchange a refresh token for a fresh session. Throws `.refreshRejected` when the
    /// token is no longer acceptable, `.networkUnavailable` when unreachable, `.revoked`
    /// when the provider reports revocation.
    func refresh(refreshToken: String, accountID: AccountID) async throws -> ProviderSession

    /// Validate stored credentials on launch (session restoration). Providers that
    /// cannot check remotely (offline, or the dev provider) validate locally and
    /// honestly report `validatedRemotely: false`.
    func restore(credentials: AuthCredentials) async throws -> RestoredSession

    /// Best-effort server-side sign-out/revocation. Throws `.networkUnavailable` when it
    /// cannot be delivered — the coordinator then reports local-only sign-out honestly.
    func signOut(accessToken: String, accountID: AccountID) async throws

    /// Ask whether the account's sessions were revoked while we were away (used on
    /// reconnect). Providers without revocation infrastructure return `.unknown` — the
    /// coordinator must not fabricate certainty from it.
    func checkRevocation(accountID: AccountID) async -> RevocationCheck
}

public struct RestoredSession: Sendable, Equatable {
    public let claims: SessionClaims
    /// Fresh credentials if the provider rotated them during restore; nil keeps stored.
    public let rotatedCredentials: AuthCredentials?
    public let validatedRemotely: Bool

    public init(claims: SessionClaims, rotatedCredentials: AuthCredentials?, validatedRemotely: Bool) {
        self.claims = claims
        self.rotatedCredentials = rotatedCredentials
        self.validatedRemotely = validatedRemotely
    }
}

public enum RevocationCheck: Sendable, Equatable {
    case active
    case revoked
    /// The provider cannot answer (offline / no backend). Never treated as revoked and
    /// never presented as verified-active.
    case unknown
}
