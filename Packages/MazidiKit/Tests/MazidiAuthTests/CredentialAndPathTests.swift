import CryptoKit
import Foundation
import Testing
@testable import MazidiAuth

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

private func creds(_ account: String, access: String = "access-1") -> AuthCredentials {
    AuthCredentials(
        accountID: AccountID(account),
        accessToken: access,
        refreshToken: "refresh-1",
        accessTokenExpiresAt: t0.addingTimeInterval(3600)
    )
}

@Suite struct CredentialStoreTests {
    @Test func emptyStoreBehaviour() async throws {
        let store = InMemoryCredentialStore()
        #expect(try await store.loadCurrent() == nil)
        await #expect(throws: CredentialStoreError.notFound) {
            _ = try await store.load(for: AccountID("missing"))
        }
        // Deleting a missing entry is idempotent, not an error.
        try await store.delete(for: AccountID("missing"))
    }

    @Test func saveReadUpdateDeleteRoundTrip() async throws {
        let store = InMemoryCredentialStore()
        try await store.save(creds("acct-1", access: "v1"))
        #expect(try await store.load(for: AccountID("acct-1")).accessToken == "v1")

        // Safe update: replaces atomically, no duplicate entries.
        try await store.save(creds("acct-1", access: "v2"))
        #expect(try await store.load(for: AccountID("acct-1")).accessToken == "v2")

        try await store.delete(for: AccountID("acct-1"))
        #expect(try await store.loadCurrent() == nil)
    }

    @Test func singleAccountModelReplacesOnDifferentAccountSave() async throws {
        let store = InMemoryCredentialStore()
        try await store.save(creds("acct-1"))
        try await store.save(creds("acct-2"))
        // Only the most recent account's credentials exist (matches Keychain adapter).
        #expect(try await store.loadCurrent()?.accountID == AccountID("acct-2"))
        await #expect(throws: CredentialStoreError.notFound) {
            _ = try await store.load(for: AccountID("acct-1"))
        }
    }

    @Test func storeFailuresSurfaceTyped() async throws {
        let store = InMemoryCredentialStore()
        await store.setFailure(.storeUnavailable)
        await #expect(throws: CredentialStoreError.storeUnavailable) {
            try await store.save(creds("acct-1"))
        }
        await #expect(throws: CredentialStoreError.storeUnavailable) {
            _ = try await store.loadCurrent()
        }
    }

    @Test func keychainStatusMappingCoversKnownCodes() {
        #expect(KeychainStatusMapping.error(fromOSStatus: -25300) == .notFound)
        #expect(KeychainStatusMapping.error(fromOSStatus: -25299) == .duplicateItem)
        #expect(KeychainStatusMapping.error(fromOSStatus: -25293) == .accessDenied)
        #expect(KeychainStatusMapping.error(fromOSStatus: -25308) == .storeUnavailable)
        #expect(KeychainStatusMapping.error(fromOSStatus: -12345) == .unhandled(status: -12345))
    }

    @Test func credentialsDescriptionNeverContainsTokens() {
        let c = creds("acct-1", access: "SUPER-SECRET-ACCESS-TOKEN")
        let described = "\(c)"
        #expect(!described.contains("SUPER-SECRET-ACCESS-TOKEN"))
        #expect(!described.contains("refresh-1"))
        #expect(described.contains("redacted"))
    }
}

@Suite struct AccountDatabasePathTests {
    @Test func deterministicAcrossCalls() {
        let a1 = AccountDatabasePath.component(for: AccountID("dev-client-001"))
        let a2 = AccountDatabasePath.component(for: AccountID("dev-client-001"))
        #expect(a1 == a2)
        #expect(a1.count == 32)
        let allHex = a1.allSatisfy { $0.isHexDigit }
        #expect(allHex)
    }

    @Test func differentAccountsGetUnrelatedDirectories() {
        let a = AccountDatabasePath.component(for: AccountID("dev-client-001"))
        let b = AccountDatabasePath.component(for: AccountID("dev-client-002"))
        let c = AccountDatabasePath.component(for: AccountID("dev-coach-001"))
        #expect(Set([a, b, c]).count == 3)
    }

    @Test func rawIdentityNeverAppearsInPath() {
        let id = "dev-client-001"
        let url = AccountDatabasePath.directory(
            base: URL(fileURLWithPath: "/base"), accountID: AccountID(id)
        )
        #expect(!url.path.contains(id))
        #expect(!url.path.contains("client")) // no fragment of the identity either
        #expect(url.path.hasPrefix("/base/accounts/"))
    }

    @Test func domainSeparationTagIsPartOfTheDerivation() {
        // Hashing the same account ID under a different domain tag (as a future feature
        // legitimately might) must never collide with the database-path derivation.
        let withTag = AccountDatabasePath.component(for: AccountID("acct-1"))
        #expect(withTag != Self.derive(tag: "some.other.purpose", id: "acct-1"))
        #expect(withTag == Self.derive(tag: AccountDatabasePath.domainTag, id: "acct-1"))
    }

    private static func derive(tag: String, id: String) -> String {
        let digest = SHA256.hash(data: Data("\(tag)|\(id)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    @Test func legacyPreIdentityDatabaseIsNeverInsideAccountsTree() {
        // The legacy dev DB lives directly under base; account dirs are strictly under
        // base/accounts/<hash>. They can never be the same path.
        let base = URL(fileURLWithPath: "/base")
        let legacy = base.appendingPathComponent("mazidi-client.sqlite")
        let account = AccountDatabasePath.directory(base: base, accountID: AccountID("any"))
            .appendingPathComponent("mazidi-client.sqlite")
        #expect(legacy.path != account.path)
        #expect(account.path.contains("/accounts/"))
        #expect(!legacy.path.contains("/accounts/"))
    }
}
