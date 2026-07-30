#if LOCAL_IDENTITY
import Foundation
import MazidiAuth
import Security

/// Storage boundary for the local test profile (ADR-0014). The production-shaped
/// implementation is Keychain-backed, exactly like `KeychainCredentialStore`; there is no
/// plaintext fallback — a failing store surfaces its error and sign-in fails honestly.
protocol LocalDeviceProfileStoring: Sendable {
    /// The stored profile, or nil when this device has never had one.
    func load() async throws -> LocalDeviceProfile?
    /// Persist the profile, replacing any existing entry (atomic replace).
    func save(_ profile: LocalDeviceProfile) async throws
}

extension LocalDeviceProfileStoring {
    /// The device's profile, minting and persisting one on first use. Minting is the only
    /// place a local device UUID is created.
    func loadOrCreate() async throws -> LocalDeviceProfile {
        if let existing = try await load() { return existing }
        let fresh = LocalDeviceProfile()
        try await save(fresh)
        return fresh
    }
}

/// Keychain-backed local profile store.
///
/// - One generic-password item under service `com.mazidigroup.mazidi.local-profile`,
///   deliberately **separate** from the auth-credential service so a local profile can
///   never be mistaken for, or overwrite, real credentials when a backend lands.
/// - Accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable after
///   first unlock, and never migrated to another device by backup — the identity is
///   device-local by construction, matching what the UI tells the tester.
/// - The stored value is the JSON `LocalDeviceProfile` (a random UUID and the chosen
///   role). It is not secret material, but it lives here so it inherits the same
///   this-device-only guarantee and disappears with the app's Keychain items.
struct KeychainLocalDeviceProfileStore: LocalDeviceProfileStoring {
    private static let service = "com.mazidigroup.mazidi.local-profile"
    private static let account = "device-profile"

    func load() async throws -> LocalDeviceProfile? {
        var query = Self.baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let profile = try? JSONDecoder().decode(LocalDeviceProfile.self, from: data) else {
                throw CredentialStoreError.encodingFailed
            }
            return profile
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStatusMapping.error(fromOSStatus: status)
        }
    }

    func save(_ profile: LocalDeviceProfile) async throws {
        guard let payload = try? JSONEncoder().encode(profile) else {
            throw CredentialStoreError.encodingFailed
        }
        SecItemDelete(Self.baseQuery() as CFDictionary)
        var attributes = Self.baseQuery()
        attributes[kSecValueData as String] = payload
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStatusMapping.error(fromOSStatus: status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

#if DEBUG
/// FIXTURE — file-backed local profile store for UI tests. CI builds the app **unsigned**
/// (`CODE_SIGNING_ALLOWED=NO`) and an unsigned simulator app cannot use the Keychain, so
/// the same `MAZIDI_STORE_DIR` seam that relocates the credential store and the database
/// also relocates the profile. Selected only under that explicit test configuration;
/// normal Debug runs and every Staging build use the Keychain store.
struct LocalDeviceProfileFileStore: LocalDeviceProfileStoring {
    private let fileURL: URL

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("uitest-local-device-profile.json")
    }

    func load() async throws -> LocalDeviceProfile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let profile = try? JSONDecoder().decode(LocalDeviceProfile.self, from: data) else {
            throw CredentialStoreError.encodingFailed
        }
        return profile
    }

    func save(_ profile: LocalDeviceProfile) async throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(profile).write(to: fileURL, options: .atomic)
        } catch {
            throw CredentialStoreError.storeUnavailable
        }
    }
}

/// FIXTURE — process-lifetime profile store for `MAZIDI_STORE_MODE=ephemeral` UI tests
/// (a fresh device identity per process, matching the ephemeral in-memory database).
actor InMemoryLocalDeviceProfileStore: LocalDeviceProfileStoring {
    private var profile: LocalDeviceProfile?

    func load() async throws -> LocalDeviceProfile? { profile }
    func save(_ profile: LocalDeviceProfile) async throws { self.profile = profile }
}
#endif
#endif
