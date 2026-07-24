#if DEBUG
import Foundation
import MazidiAuth

/// FIXTURE — a file-backed credential store used ONLY by UI tests that need a development
/// session to survive app termination (the relaunch-restoration and account-switch
/// journeys). It exists solely because CI builds the app **unsigned**
/// (`CODE_SIGNING_ALLOWED=NO`), and an unsigned app on the simulator cannot use the
/// Keychain (`SecItemAdd` → missing-entitlement) — so the real `KeychainCredentialStore`
/// can't persist a session in that environment.
///
/// Scope and safety:
/// - `#if DEBUG` only — never compiled into Release (proven by a Release-exclusion test).
/// - Selected only when the DEBUG launch variable `MAZIDI_STORE_DIR` is set, i.e. under
///   explicit UI-test configuration; normal Debug and all Release runs use the Keychain.
/// - Stores ONLY fixture development credentials (opaque `dev.*` tokens minted by
///   `DevelopmentAuthProvider` — not real secrets) in the test's own unique temporary
///   directory, so isolation and cleanup are inherent to that per-test directory.
/// - Production credentials never touch this type.
struct DevelopmentFileCredentialStore: CredentialStore {
    private let fileURL: URL

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("uitest-credentials.json")
    }

    private func readAll() -> AuthCredentials? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AuthCredentials.self, from: data)
    }

    func save(_ credentials: AuthCredentials) async throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(credentials)
            // Single-account model, mirroring the Keychain adapter: replace atomically.
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw CredentialStoreError.storeUnavailable
        }
    }

    func load(for accountID: AccountID) async throws -> AuthCredentials {
        guard let stored = readAll(), stored.accountID == accountID else {
            throw CredentialStoreError.notFound
        }
        return stored
    }

    func loadCurrent() async throws -> AuthCredentials? { readAll() }

    func delete(for accountID: AccountID) async throws {
        // Idempotent single-account semantics: remove the stored file only when it holds
        // the account being cleared (matching the Keychain adapter). Absence is success.
        if let stored = readAll(), stored.accountID == accountID {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
#endif
