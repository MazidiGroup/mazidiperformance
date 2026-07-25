import Foundation
import Testing
import MazidiAuth
import MazidiFoundations
import MazidiNetworking
import MazidiSync
@testable import MazidiPersistenceGRDB

@Suite struct BackendPushRevocationTests {
    private let account = AccountID("dev-client-001")
    private let device = DeviceInstallationID("device-1")
    private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

    private func context() -> AuthenticatedRequestContext {
        AuthenticatedRequestContext(accountID: account, deviceInstallationID: device, generation: 1, accessToken: { "token" })
    }

    private func enqueue(_ store: GRDBStore) async throws -> SyncOperation {
        let op = SyncOperation(kind: .assignmentCreated, aggregateID: UUID(), sequence: 0, payload: Data("p".utf8), enqueuedAt: t0)
        try await store.enqueue(op)
        return op
    }

    // (iv) No pending work uploads after revocation/sign-out: an inactive session skips the
    // drain entirely — the transport is never called and the op stays queued.
    @Test func noPendingWorkUploadsWhenSessionInactive() async throws {
        let store = try GRDBStore.inMemory(); let backend = FakeSyncBackend()
        let op = try await enqueue(store)
        let engine = BackendPushEngine(outbox: store, syncStore: store, transport: backend,
                                       clock: FixedClock(t0), random: { 0 }, isActive: { false })
        let summary = try await engine.pushOnce(context: context())
        #expect(summary.skippedInactive)
        #expect(await backend.pushCallCount == 0)                 // transport never called
        #expect(try await store.pendingOperations().first?.id == op.id)   // op still queued, not dropped
    }

    // A revoked transport signal is surfaced (so the caller routes it to the coordinator);
    // the op stays queued (never dead-lettered).
    @Test func transportRevokedIsSurfacedAndOpStaysQueued() async throws {
        let store = try GRDBStore.inMemory(); let backend = FakeSyncBackend()
        let op = try await enqueue(store)
        await backend.setPushError(.revoked)
        let engine = BackendPushEngine(outbox: store, syncStore: store, transport: backend, clock: FixedClock(t0), random: { 0 })
        let summary = try await engine.pushOnce(context: context())
        #expect(summary.revoked)
        #expect(summary.transportFailed)
        let row = try await store.operations(inAggregate: op.aggregateID).first
        #expect(row?.status == .pending)                          // queued, not dead-lettered
    }
}
