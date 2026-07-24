import Foundation
import Testing
import MazidiAuth
import MazidiDomain
import MazidiFoundations
@testable import MazidiPersistenceGRDB

/// Account-scoped data boundaries (ADR-0008 §4/§5): deterministic per-account
/// directories, isolation between accounts, inaccessibility after close, account-scoped
/// corruption recovery, and the legacy pre-identity database policy.
@Suite struct AccountScopedStoreTests {
    private func temporaryBase() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mazidi-acct-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeWorkoutSession() -> WorkoutSession {
        let squat = AssignedExercise(
            slug: "barbell-squat",
            prescription: .repsAndLoad(sets: 3, reps: 5...8, loadKg: 80)
        )
        let workout = AssignedWorkout(title: "Iso", programmeVersion: 1, sections: [.main: [squat]])
        var session = WorkoutSession(workout: workout, epoch: 1)
        try? session.start(at: Date(timeIntervalSince1970: 1_784_000_000))
        return session
    }

    @Test func sameAccountReopensTheSameDatabase() async throws {
        let base = temporaryBase()
        let account = AccountID("acct-alpha")
        let dir = AccountDatabasePath.directory(base: base, accountID: account)

        let first = try GRDBStore.open(directory: dir)
        let session = makeWorkoutSession()
        try await first.save(session)
        try first.close()

        // Same account, fresh launch: same directory, data present.
        let second = try GRDBStore.open(directory: AccountDatabasePath.directory(base: base, accountID: account))
        #expect(second.recovery == .normal(createdNew: false))
        let restored = try await second.session(id: session.id)
        #expect(restored?.id == session.id)
        try second.close()
    }

    @Test func differentAccountsNeverShareADatabase() async throws {
        let base = temporaryBase()
        let alpha = AccountID("acct-alpha")
        let beta = AccountID("acct-beta")

        let alphaStore = try GRDBStore.open(directory: AccountDatabasePath.directory(base: base, accountID: alpha))
        let session = makeWorkoutSession()
        try await alphaStore.save(session)
        try alphaStore.close()

        // A different account gets a different directory and an empty database.
        let betaDir = AccountDatabasePath.directory(base: base, accountID: beta)
        #expect(betaDir != AccountDatabasePath.directory(base: base, accountID: alpha))
        let betaStore = try GRDBStore.open(directory: betaDir)
        #expect(betaStore.recovery == .normal(createdNew: true))
        #expect(try await betaStore.session(id: session.id) == nil)
        #expect(try await betaStore.resumableSession() == nil)
        try betaStore.close()
    }

    @Test func closedStoreRefusesAllRepositoryAccess() async throws {
        let base = temporaryBase()
        let store = try GRDBStore.open(
            directory: AccountDatabasePath.directory(base: base, accountID: AccountID("acct-close"))
        )
        let session = makeWorkoutSession()
        try await store.save(session)
        try store.close()

        // Signed-out (closed) store: every role's calls throw; nothing is readable.
        await #expect(throws: (any Error).self) { _ = try await store.resumableSession() }
        await #expect(throws: (any Error).self) { _ = try await store.session(id: session.id) }
        await #expect(throws: (any Error).self) { _ = try await store.pendingOperations() }
        await #expect(throws: (any Error).self) { _ = try await store.allEvents() }
        await #expect(throws: (any Error).self) { try await store.save(self.makeWorkoutSession()) }
    }

    @Test func corruptionRecoveryStaysInsideOneAccountDirectory() async throws {
        let base = temporaryBase()
        let victim = AccountID("acct-corrupt")
        let bystander = AccountID("acct-untouched")

        // Bystander account has healthy data.
        let bystanderDir = AccountDatabasePath.directory(base: base, accountID: bystander)
        let bystanderStore = try GRDBStore.open(directory: bystanderDir)
        let bystanderSession = makeWorkoutSession()
        try await bystanderStore.save(bystanderSession)
        try bystanderStore.close()

        // Victim account's database file is garbage.
        let victimDir = AccountDatabasePath.directory(base: base, accountID: victim)
        try FileManager.default.createDirectory(at: victimDir, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: victimDir.appendingPathComponent("mazidi-client.sqlite"))

        let recovered = try GRDBStore.open(directory: victimDir)
        guard case .recoveredAfterQuarantine(let quarantinedPath, _) = recovered.recovery else {
            Issue.record("expected quarantine recovery, got \(recovered.recovery)"); return
        }
        // Quarantine artifacts live inside the victim's directory only.
        #expect(quarantinedPath.hasPrefix(victimDir.path))
        try recovered.close()

        // The bystander account is untouched: normal reopen, data intact.
        let bystanderReopened = try GRDBStore.open(directory: bystanderDir)
        #expect(bystanderReopened.recovery == .normal(createdNew: false))
        #expect(try await bystanderReopened.session(id: bystanderSession.id)?.id == bystanderSession.id)
        try bystanderReopened.close()
    }

    @Test func legacyPreIdentityDatabaseIsNotAdoptedByAccounts() async throws {
        let base = temporaryBase()
        // Legacy dev database directly under base (the pre-identity location).
        let legacyStore = try GRDBStore.open(directory: base)
        let legacySession = makeWorkoutSession()
        try await legacyStore.save(legacySession)
        try legacyStore.close()

        // An authenticated account opening its scoped store must NOT see legacy data.
        let account = AccountID("acct-fresh")
        let accountStore = try GRDBStore.open(
            directory: AccountDatabasePath.directory(base: base, accountID: account)
        )
        #expect(accountStore.recovery == .normal(createdNew: true))
        #expect(try await accountStore.session(id: legacySession.id) == nil)
        try accountStore.close()

        // And the legacy file still exists untouched (preserved, never migrated).
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("mazidi-client.sqlite").path))
    }

    @Test func repeatedOpenCloseCyclesForOneAccountAreStable() async throws {
        let base = temporaryBase()
        let account = AccountID("acct-cycle")
        let session = makeWorkoutSession()
        for launch in 0..<4 {
            let store = try GRDBStore.open(
                directory: AccountDatabasePath.directory(base: base, accountID: account)
            )
            if launch == 0 {
                #expect(store.recovery == .normal(createdNew: true))
                try await store.save(session)
            } else {
                #expect(store.recovery == .normal(createdNew: false))
                #expect(try await store.session(id: session.id)?.id == session.id)
            }
            try store.close()
        }
    }
}
