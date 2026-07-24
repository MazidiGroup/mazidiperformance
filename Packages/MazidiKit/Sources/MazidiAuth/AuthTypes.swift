import Foundation

/// Stable, opaque account identity issued by the authentication provider (the "subject").
/// Never an email address or display name; safe to hash, never shown raw in paths/logs.
public struct AccountID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Top-level role claims a session may carry. Exactly one of coach/client is expected;
/// anything else is routed to a safe error state (ADR-0008 §7).
public enum RoleClaim: String, Sendable, Codable, Hashable, CaseIterable {
    case coach
    case client
}

/// Validated claims attached to a session by the provider.
public struct SessionClaims: Sendable, Codable, Equatable {
    public let accountID: AccountID
    public let roles: Set<RoleClaim>

    public init(accountID: AccountID, roles: Set<RoleClaim>) {
        self.accountID = accountID
        self.roles = roles
    }

    /// The single routable role, or nil when missing/conflicting (safe error state).
    public var routableRole: RoleClaim? {
        roles.count == 1 ? roles.first : nil
    }
}

/// Non-secret session descriptor used across state/UI. Tokens are NOT here — they live
/// only in the credential store (SECURITY_BOUNDARIES.md).
public struct AuthSession: Sendable, Codable, Equatable {
    public let claims: SessionClaims
    public let issuedAt: Date
    public let accessTokenExpiresAt: Date
    /// When the user last actively authenticated (for recent-reauth requirements).
    public let lastAuthenticatedAt: Date

    public init(
        claims: SessionClaims,
        issuedAt: Date,
        accessTokenExpiresAt: Date,
        lastAuthenticatedAt: Date
    ) {
        self.claims = claims
        self.issuedAt = issuedAt
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
    }

    public func isAccessTokenExpired(at now: Date) -> Bool { now >= accessTokenExpiresAt }

    /// Near-expiry window in which `ensureValidSession` refreshes proactively.
    public func isNearExpiry(at now: Date, window: TimeInterval = 120) -> Bool {
        now >= accessTokenExpiresAt.addingTimeInterval(-window)
    }
}

/// Secret material — Keychain-only. `description` redacts token bodies so accidental
/// interpolation can never leak them into logs or test output.
public struct AuthCredentials: Sendable, Equatable, Codable, CustomStringConvertible {
    public let accountID: AccountID
    public let accessToken: String
    public let refreshToken: String
    public let accessTokenExpiresAt: Date

    public init(
        accountID: AccountID,
        accessToken: String,
        refreshToken: String,
        accessTokenExpiresAt: Date
    ) {
        self.accountID = accountID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
    }

    public var description: String {
        "AuthCredentials(account: \(accountID), accessToken: <redacted:\(accessToken.count)ch>, refreshToken: <redacted>, expires: \(accessTokenExpiresAt))"
    }
}

/// Typed authentication failures. Provider-internal detail stays in `underlyingDebug`
/// (never user-facing); user copy comes from the app layer per state.
public enum AuthError: Error, Sendable, Equatable {
    case invalidCredentials
    case networkUnavailable
    case providerUnavailable
    /// The provider rejected the refresh token — reauthentication required.
    case refreshRejected
    /// The provider reports this session/account as revoked.
    case revoked
    case credentialStorage(CredentialStoreError)
    case internalInconsistency(String)
}
