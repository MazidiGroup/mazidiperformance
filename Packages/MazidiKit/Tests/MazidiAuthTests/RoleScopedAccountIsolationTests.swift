import Foundation
import Testing
@testable import MazidiAuth

/// Properties the local device test profile (ADR-0014) depends on when it gives the coach
/// and client sides of one device **separate account ids**.
///
/// The id format itself lives in the app target (`LocalDeviceAccount`, compiled only under
/// `LOCAL_IDENTITY`), so it cannot be imported here; these tests pin the MazidiKit
/// behaviour the format relies on, using the same shape of literal ids. If account-path
/// derivation ever stopped separating two ids that share a prefix, role switching would
/// silently start sharing one database — which is exactly what this guards.
@Suite struct RoleScopedAccountIsolationTests {
    private static let deviceUUID = "0e0b3b7c-8f1e-4b64-9a1e-1f2a3b4c5d6e"
    private static func account(_ role: String) -> AccountID {
        AccountID("local-test-profile.v1.\(deviceUUID).\(role)")
    }

    @Test func rolesOfOneDeviceDeriveSeparateDatabaseDirectories() {
        let coach = AccountDatabasePath.component(for: Self.account("coach"))
        let client = AccountDatabasePath.component(for: Self.account("client"))

        #expect(coach != client, "Coach and client profiles must never share a database directory")
        #expect(coach.count == 32)
        #expect(client.count == 32)
    }

    @Test func roleScopedComponentsAreDeterministicAcrossLaunches() {
        // "Same device → same identity → same directory" is the whole point of persisting
        // the device UUID: a second launch must land on the identical path.
        #expect(
            AccountDatabasePath.component(for: Self.account("coach"))
                == AccountDatabasePath.component(for: Self.account("coach"))
        )
    }

    @Test func rawProfileIdentityNeverAppearsInThePath() {
        let directory = AccountDatabasePath.directory(
            base: URL(fileURLWithPath: "/tmp/base", isDirectory: true),
            accountID: Self.account("client")
        )
        let path = directory.path
        #expect(!path.contains(Self.deviceUUID))
        #expect(!path.contains("local-test-profile"))
        #expect(!path.contains("client"))
        // Strictly under accounts/, so the legacy pre-identity database can never be adopted.
        #expect(path.contains("/accounts/"))
    }

    @Test func rolesOfOneDeviceGetDistinctAuditActors() {
        // Audit chains are per-account; two role profiles must not write as the same actor.
        #expect(Self.account("coach").stableActorUUID != Self.account("client").stableActorUUID)
        #expect(Self.account("coach").stableActorUUID == Self.account("coach").stableActorUUID)
    }

    @Test func differentDevicesNeverCollide() {
        let other = AccountID("local-test-profile.v1.9f8e7d6c-5b4a-4321-8765-0a1b2c3d4e5f.coach")
        #expect(
            AccountDatabasePath.component(for: Self.account("coach"))
                != AccountDatabasePath.component(for: other)
        )
    }
}
