#if LOCAL_IDENTITY
import Foundation
import MazidiAuth

/// LOCAL TEST PROFILE — **not authentication** (ADR-0014).
///
/// A device-local profile that lets a tester open the app on a real device while no
/// backend exists (R-01). It proves nothing about who is using the phone: there is no
/// password, no server, no verification, and nothing leaves the device. It exists only
/// in builds compiled with `LOCAL_IDENTITY` (Debug and Staging — Staging is the
/// TestFlight configuration); Release keeps `UnavailableAuthProvider` and no part of this
/// file is compiled into it.
///
/// The profile is a single random UUID minted once and kept in the Keychain
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never backed up off-device), plus
/// the role the tester last chose. Same device → same UUID across launches, so the
/// account-scoped database (ADR-0008 §4) is found again on every launch.
struct LocalDeviceProfile: Codable, Equatable, Sendable {
    /// Opaque device-local identifier. Random, carries no personal data, never leaves the
    /// device, and never appears in a path (paths hash it — `AccountDatabasePath`).
    let deviceID: UUID
    /// The role the tester last chose, stored alongside the identity so a switch is
    /// remembered. Authoritative role for a *session* is the one encoded in its account
    /// id; this field records the latest choice.
    var lastSelectedRole: RoleClaim?

    init(deviceID: UUID = UUID(), lastSelectedRole: RoleClaim? = nil) {
        self.deviceID = deviceID
        self.lastSelectedRole = lastSelectedRole
    }
}

/// The account identity a local profile presents to `SessionCoordinator`.
///
/// **One account id per role, not one shared id** (ADR-0014 §4): the coach and client
/// shells of a single device profile get *different* `AccountID`s, so they derive
/// different `AccountDatabasePath` directories, different `stableActorUUID` audit actors,
/// and different credential entries. Role switching is then indistinguishable from an
/// account switch, which is exactly the path the architecture already tests.
struct LocalDeviceAccount: Equatable {
    /// Version-tagged prefix; also the marker that identifies a local-profile account id.
    static let prefix = "local-test-profile.v1"

    let deviceID: UUID
    let role: RoleClaim

    /// `local-test-profile.v1.<uuid>.<role>` — opaque, stable, and role-scoped.
    var accountID: AccountID {
        AccountID("\(Self.prefix).\(deviceID.uuidString.lowercased()).\(role.rawValue)")
    }

    /// Recovers a local account from its id, or nil when the id is not a local profile
    /// (a development fixture id, or a real account id once a backend exists).
    init?(accountID: AccountID) {
        let raw = accountID.rawValue
        guard raw.hasPrefix(Self.prefix + ".") else { return nil }
        let remainder = raw.dropFirst(Self.prefix.count + 1)
        let parts = remainder.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let deviceID = UUID(uuidString: String(parts[0])),
              let role = RoleClaim(rawValue: String(parts[1])) else { return nil }
        self.deviceID = deviceID
        self.role = role
    }

    init(deviceID: UUID, role: RoleClaim) {
        self.deviceID = deviceID
        self.role = role
    }

    // MARK: - Sign-in request encoding

    /// The identity string the app hands `SignInRequest.development(identity:)` to ask
    /// for a local profile in a given role. It carries no device id — the provider is the
    /// only thing that reads (or mints) the device UUID, so no view or view-model ever
    /// handles it.
    static func signInIdentity(for role: RoleClaim) -> String {
        "\(prefix).role.\(role.rawValue)"
    }

    /// The role a `signInIdentity(for:)` string asks for, or nil if it is not one.
    static func requestedRole(fromSignInIdentity identity: String) -> RoleClaim? {
        let marker = "\(prefix).role."
        guard identity.hasPrefix(marker) else { return nil }
        return RoleClaim(rawValue: String(identity.dropFirst(marker.count)))
    }

    // MARK: - Local token material

    /// Prefix for the opaque local tokens. These are **not** credentials: nothing verifies
    /// them and nothing accepts them anywhere but `LocalDeviceAuthProvider` in this build.
    /// The `AuthCredentials` shape is required by the contract, so it is filled honestly
    /// with local-only values rather than fabricated server tokens.
    static let tokenPrefix = "local-test-profile."

    static func localCredentials(for account: LocalDeviceAccount) -> AuthCredentials {
        AuthCredentials(
            accountID: account.accountID,
            accessToken: "\(tokenPrefix)access.\(UUID().uuidString)",
            refreshToken: "\(tokenPrefix)refresh.\(UUID().uuidString)",
            // No token can expire because no issuer exists; a far-future sentinel keeps the
            // coordinator's expiry/refresh machinery inert rather than pretending a
            // lifetime that nothing could renew.
            accessTokenExpiresAt: .distantFuture
        )
    }
}
#endif
