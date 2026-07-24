import Foundation
import MazidiAuth
import Security

/// Keychain-backed `CredentialStore` (SECURITY_BOUNDARIES.md).
///
/// - One generic-password item under service `com.mazidigroup.mazidi.auth` (the app
///   stores at most one signed-in account); the account attribute carries the opaque
///   account ID (not an email), the value is the JSON-encoded `AuthCredentials`.
/// - Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — readable after
///   first unlock so background queue drains can authenticate; never migrates to another
///   device via backup (ADR-0008 §3).
/// - Update semantics: atomic replace (delete-then-add inside one logical operation);
///   no partial state is left on failure paths.
/// - Failures map through the shared pure `KeychainStatusMapping` into typed errors;
///   there is NO fallback to any other storage.
struct KeychainCredentialStore: CredentialStore {
    private static let service = "com.mazidigroup.mazidi.auth"

    func save(_ credentials: AuthCredentials) async throws {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(credentials)
        } catch {
            throw CredentialStoreError.encodingFailed
        }
        // Single-account model: replace whatever is stored for this service.
        SecItemDelete(Self.baseQuery() as CFDictionary)
        var attributes = Self.baseQuery()
        attributes[kSecAttrAccount as String] = credentials.accountID.rawValue
        attributes[kSecValueData as String] = payload
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStatusMapping.error(fromOSStatus: status)
        }
    }

    func load(for accountID: AccountID) async throws -> AuthCredentials {
        guard let stored = try await loadCurrent(), stored.accountID == accountID else {
            throw CredentialStoreError.notFound
        }
        return stored
    }

    func loadCurrent() async throws -> AuthCredentials? {
        var query = Self.baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let credentials = try? JSONDecoder().decode(AuthCredentials.self, from: data) else {
                throw CredentialStoreError.encodingFailed
            }
            return credentials
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStatusMapping.error(fromOSStatus: status)
        }
    }

    func delete(for accountID: AccountID) async throws {
        var query = Self.baseQuery()
        query[kSecAttrAccount as String] = accountID.rawValue
        let status = SecItemDelete(query as CFDictionary)
        // Idempotent: a missing item is success, matching the reference store.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStatusMapping.error(fromOSStatus: status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }
}
