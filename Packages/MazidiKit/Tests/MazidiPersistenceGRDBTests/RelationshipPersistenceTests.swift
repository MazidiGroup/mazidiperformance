import Foundation
import Testing
import MazidiAuth
import MazidiDomain
import MazidiFoundations
import MazidiSync
@testable import MazidiPersistenceGRDB

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

@Suite struct RelationshipPersistenceTests {
    private func op(aggregate: UUID) -> SyncOperation {
        SyncOperation(kind: .relationshipUpdated, aggregateID: aggregate, sequence: 0, payload: Data("r".utf8), enqueuedAt: t0)
    }

    private func dir(_ tag: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mazidi-rel-\(tag)-\(UUID().uuidString)", isDirectory: true)
    }

    // Activation: pending → active, acceptedAt set, round-tripped through the store atomically.
    @Test func relationshipActivationRoundTripsWithQueuedOperation() async throws {
        let store = try GRDBStore.inMemory()
        var relationship = Relationship(coachAccountRef: "dev-coach-001", clientAccountRef: "dev-client-001", createdAt: t0)
        #expect(relationship.status == .pendingLocalUpload)
        try relationship.activate(at: t0.addingTimeInterval(60))
        #expect(relationship.status == .active)
        #expect(relationship.acceptedAt == t0.addingTimeInterval(60))

        try await store.saveRelationshipAtomically(relationship, enqueueing: [op(aggregate: relationship.id.rawValue)])
        let restored = try await store.relationship(id: relationship.id)
        #expect(restored == relationship)
        #expect(try await store.pendingOperations().map(\.kind) == [.relationshipUpdated])  // atomic op
    }

    // Termination: active → ended, endedAt set, retained (not deleted).
    @Test func relationshipTerminationRetainsTheRow() async throws {
        let store = try GRDBStore.inMemory()
        var relationship = Relationship(coachAccountRef: "c", clientAccountRef: "cl", status: .active, createdAt: t0, acceptedAt: t0)
        try relationship.end(at: t0.addingTimeInterval(1000))
        #expect(relationship.status == .ended)
        try await store.saveRelationshipAtomically(relationship, enqueueing: [])
        let restored = try #require(try await store.relationship(id: relationship.id))
        #expect(restored.status == .ended)
        #expect(restored.endedAt == t0.addingTimeInterval(1000))
        #expect(try await store.allRelationships().count == 1)             // retained, never deleted
    }

    // (i) Cross-account isolation: a relationship (and assignment) created in coach A's
    // account database is invisible to any other account's database.
    @Test func relationshipAndAssignmentAreAccountScopedAndNotCrossVisible() async throws {
        let base = dir("iso")
        let storeA = try GRDBStore.open(directory: AccountDatabasePath.directory(base: base, accountID: AccountID("coach-a")))
        let storeB = try GRDBStore.open(directory: AccountDatabasePath.directory(base: base, accountID: AccountID("coach-b")))

        let relationship = Relationship(coachAccountRef: "coach-a", clientAccountRef: "client-1", status: .active, createdAt: t0, acceptedAt: t0)
        try await storeA.saveRelationshipAtomically(relationship, enqueueing: [])

        #expect(try await storeA.allRelationships().count == 1)
        #expect(try await storeB.allRelationships().isEmpty)               // another account never sees it
        #expect(try await storeB.relationship(id: relationship.id) == nil)
        try storeA.close(); try storeB.close()
    }

    // Signed-out inaccessibility: after the account store is closed (sign-out/switch), all
    // relationship access throws — the shell can no longer read the account's data.
    @Test func closedStoreRefusesRelationshipAccess() async throws {
        let store = try GRDBStore.open(directory: dir("closed"))
        let relationship = Relationship(coachAccountRef: "c", clientAccountRef: "cl", createdAt: t0)
        try await store.saveRelationshipAtomically(relationship, enqueueing: [])
        try store.close()
        await #expect(throws: (any Error).self) { _ = try await store.allRelationships() }
        await #expect(throws: (any Error).self) { _ = try await store.relationship(id: relationship.id) }
        await #expect(throws: (any Error).self) {
            try await store.saveRelationshipAtomically(relationship, enqueueing: [])
        }
    }
}

@Suite struct RelationshipDomainTests {
    // Lifecycle guards are deterministic; illegal transitions throw and never mutate.
    @Test func lifecycleTransitionsAreGuarded() throws {
        var r = Relationship(coachAccountRef: "c", clientAccountRef: "cl", status: .invited, createdAt: t0)
        try r.activate(at: t0); #expect(r.status == .active); #expect(r.permitsNewAccess)
        // Cannot re-activate a non-pending/active-illegal state.
        #expect(throws: Relationship.LifecycleError.self) { try r.decline(at: t0) }   // active can't decline
        try r.end(at: t0); #expect(r.status == .ended); #expect(!r.permitsNewAccess)
        #expect(throws: Relationship.LifecycleError.self) { try r.revoke(at: t0) }     // terminal
    }

    @Test func revokeIsLegalFromActiveButNotTerminal() throws {
        var active = Relationship(coachAccountRef: "c", clientAccountRef: "cl", status: .active, createdAt: t0)
        try active.revoke(at: t0)
        #expect(active.status == .revoked)
        #expect(active.endedAt == t0)
    }
}
