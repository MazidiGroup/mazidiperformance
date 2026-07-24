import Foundation

/// Typed credential-storage failures (SECURITY_BOUNDARIES.md). Never contains secret
/// material — only status information.
public enum CredentialStoreError: Error, Sendable, Equatable {
    case notFound
    case duplicateItem
    case accessDenied
    /// Keychain unavailable (e.g. device locked before first unlock).
    case storeUnavailable
    case encodingFailed
    case unhandled(status: Int32)
}

/// Secret storage boundary. The production implementation is Keychain-backed (app
/// target); tests and previews use `InMemoryCredentialStore`. There is NO plaintext
/// fallback implementation — a failing store surfaces its error.
public protocol CredentialStore: Sendable {
    /// Persist credentials for the account, replacing any existing entry (safe update:
    /// atomic replace, never a partial write).
    func save(_ credentials: AuthCredentials) async throws
    /// Credentials for a specific account, or `CredentialStoreError.notFound`.
    func load(for accountID: AccountID) async throws -> AuthCredentials
    /// The single stored credential set, if any (used for launch restoration; the app
    /// stores at most one signed-in account at a time).
    func loadCurrent() async throws -> AuthCredentials?
    /// Remove the account's credentials. Missing entries are not an error (idempotent).
    func delete(for accountID: AccountID) async throws
}

/// Reference in-memory implementation for tests/previews. Behaviourally faithful to the
/// Keychain adapter (same errors, same idempotent delete, same single-account model).
public actor InMemoryCredentialStore: CredentialStore {
    private var storage: [AccountID: AuthCredentials] = [:]
    /// Test hook: simulate an unavailable/denying store.
    private var failure: CredentialStoreError?

    public init() {}

    public func setFailure(_ error: CredentialStoreError?) { failure = error }

    public func save(_ credentials: AuthCredentials) async throws {
        if let failure { throw failure }
        // Single-account model: saving a different account replaces the previous one,
        // exactly like the Keychain adapter's single service item.
        storage = [credentials.accountID: credentials]
    }

    public func load(for accountID: AccountID) async throws -> AuthCredentials {
        if let failure { throw failure }
        guard let found = storage[accountID] else { throw CredentialStoreError.notFound }
        return found
    }

    public func loadCurrent() async throws -> AuthCredentials? {
        if let failure { throw failure }
        return storage.values.first
    }

    public func delete(for accountID: AccountID) async throws {
        if let failure { throw failure }
        storage[accountID] = nil
    }
}

/// Pure OSStatus → typed-error mapping shared with the app-side Keychain adapter, kept
/// here so the mapping itself is unit-testable without touching a real Keychain.
public enum KeychainStatusMapping {
    public static func error(fromOSStatus status: Int32) -> CredentialStoreError {
        switch status {
        case -25300: return .notFound          // errSecItemNotFound
        case -25299: return .duplicateItem     // errSecDuplicateItem
        case -25293: return .accessDenied      // errSecAuthFailed
        case -25308: return .storeUnavailable  // errSecInteractionNotAllowed
        default: return .unhandled(status: status)
        }
    }
}
