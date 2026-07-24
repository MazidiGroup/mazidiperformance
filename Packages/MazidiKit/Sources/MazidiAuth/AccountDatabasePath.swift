import CryptoKit
import Foundation

/// Deterministic, privacy-preserving per-account database directory naming
/// (ADR-0008 §4, SECURITY_BOUNDARIES.md).
///
/// `component(for:)` = hex(SHA-256(domainTag + "|" + accountID)) truncated to 32 hex
/// characters. Properties the tests pin down:
/// - Deterministic: same account → same component, every launch, every device.
/// - No raw identity: the account ID (or email/name/token) never appears in a path.
/// - Domain-separated: the version-tagged prefix means hashing the same account ID for
///   any other purpose (different tag) yields an unrelated value.
/// - Collision-safe in practice: 128 bits of SHA-256 output.
public enum AccountDatabasePath {
    /// Versioned domain tag — never reuse for any other derivation.
    public static let domainTag = "com.mazidigroup.mazidi.account-db.v1"

    /// The directory component for an account, e.g. "3f9a…" (32 hex chars).
    public static func component(for accountID: AccountID) -> String {
        let message = Data("\(domainTag)|\(accountID.rawValue)".utf8)
        let digest = SHA256.hash(data: message)
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Account directory under a base directory:
    /// `<base>/accounts/<component>` — strictly beneath `accounts/`, so the legacy
    /// pre-identity database directly under `<base>` can never be adopted by an account.
    public static func directory(base: URL, accountID: AccountID) -> URL {
        base.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(component(for: accountID), isDirectory: true)
    }
}

public extension AccountID {
    /// Deterministic, domain-separated UUID for audit `actorID` fields — stable per
    /// account, never the raw identity, never reused from the database-path derivation.
    var stableActorUUID: UUID {
        let digest = SHA256.hash(data: Data("com.mazidigroup.mazidi.actor-id.v1|\(rawValue)".utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
