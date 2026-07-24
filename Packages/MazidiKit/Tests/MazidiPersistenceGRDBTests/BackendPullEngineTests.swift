import Foundation
import Testing
import MazidiAuth
import MazidiFoundations
import MazidiNetworking
import MazidiPersistence
import MazidiSync
@testable import MazidiPersistenceGRDB

@Suite struct BackendPullEngineTests {
    private let account = AccountID("dev-client-001")
    private let device = DeviceInstallationID("device-1")
    private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

    private func context(_ id: AccountID? = nil) -> AuthenticatedRequestContext {
        AuthenticatedRequestContext(accountID: id ?? account, deviceInstallationID: device, generation: 1, accessToken: { "token" })
    }

    private func change(_ v: Int, _ remote: String, op: ChangeOp = .upsert, schema: Int = 1) -> ChangeEnvelope {
        ChangeEnvelope(entityType: .workoutAssignment, remoteID: RemoteRecordID(remote),
                       serverVersion: ServerRecordVersion(v), op: op, payload: Data("x".utf8), payloadSchemaVersion: schema)
    }

    private func response(_ changes: [ChangeEnvelope], token: String? = "cur", hasMore: Bool = false,
                          serverSchema: Int = 1, accountContext: AccountID? = nil) -> PullChangesResponse {
        PullChangesResponse(changes: changes, nextCursorToken: token.map(SyncCursorToken.init),
                            hasMore: hasMore, serverSchemaVersion: serverSchema, accountContext: accountContext ?? account)
    }

    private func makeStore() throws -> GRDBStore { try GRDBStore.inMemory() }

    private func engine(_ store: GRDBStore, _ backend: FakeSyncBackend, clock: FixedClock,
                        isActive: @escaping @Sendable () -> Bool = { true }) -> BackendPullEngine {
        BackendPullEngine(syncStore: store, transport: backend, clock: clock, isActive: isActive)
    }

    // First pull applies changes and advances the cursor.
    @Test func firstPullAppliesChangesAndAdvancesCursor() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        await backend.enqueuePull(.success(response([change(1, "r1"), change(2, "r2")])))
        let outcome = try await engine(store, backend, clock: clock).pullOnce(context: context())
        #expect(outcome == .applied(applied: 2, ignored: 0, hasMore: false))
        let cursor = try #require(try await store.loadSyncCursor(stream: "default"))
        #expect(cursor.lastServerVersion == 2)
        #expect(cursor.token == "cur")
        #expect(try await store.remoteRecordState(entityType: "workoutAssignment", localID: "r2")?.serverVersion == 2)
    }

    // Incremental pull continues from the cursor.
    @Test func incrementalPullContinuesFromCursor() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        await backend.enqueuePull(.success(response([change(1, "r1")])))
        await backend.enqueuePull(.success(response([change(2, "r2")])))
        _ = try await engine(store, backend, clock: clock).pullOnce(context: context())
        let outcome = try await engine(store, backend, clock: clock).pullOnce(context: context())
        #expect(outcome == .applied(applied: 1, ignored: 0, hasMore: false))
        #expect(try await store.loadSyncCursor(stream: "default")?.lastServerVersion == 2)
    }

    // Pagination surfaced via hasMore.
    @Test func paginationIsSurfaced() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        await backend.enqueuePull(.success(response([change(1, "r1")], hasMore: true)))
        let outcome = try await engine(store, backend, clock: clock).pullOnce(context: context())
        #expect(outcome == .applied(applied: 1, ignored: 0, hasMore: true))
    }

    // Duplicate/already-applied changes are harmless (ignored, not re-applied).
    @Test func duplicateChangesAreIgnored() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        await backend.enqueuePull(.success(response([change(1, "r1"), change(2, "r2")])))
        await backend.enqueuePull(.success(response([change(2, "r2"), change(3, "r3")])))
        _ = try await engine(store, backend, clock: clock).pullOnce(context: context())
        let outcome = try await engine(store, backend, clock: clock).pullOnce(context: context())
        #expect(outcome == .applied(applied: 1, ignored: 1, hasMore: false))   // v2 dup ignored, v3 applied
        #expect(try await store.loadSyncCursor(stream: "default")?.lastServerVersion == 3)
    }

    // Cursor is monotonic: an out-of-order lower version never regresses it.
    @Test func cursorNeverRegresses() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        await backend.enqueuePull(.success(response([change(5, "r5")])))
        await backend.enqueuePull(.success(response([change(3, "r3")])))       // out-of-order, older
        _ = try await engine(store, backend, clock: clock).pullOnce(context: context())
        let outcome = try await engine(store, backend, clock: clock).pullOnce(context: context())
        #expect(outcome == .applied(applied: 0, ignored: 1, hasMore: false))   // v3 ignored
        #expect(try await store.loadSyncCursor(stream: "default")?.lastServerVersion == 5)  // stays at 5
    }

    // A transport failure preserves the prior cursor (no partial advance).
    @Test func transportFailurePreservesCursor() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        await backend.enqueuePull(.success(response([change(4, "r4")])))
        _ = try await engine(store, backend, clock: clock).pullOnce(context: context())
        await backend.enqueuePull(.failure(.unreachable))
        let outcome = try await engine(store, backend, clock: clock).pullOnce(context: context())
        #expect(outcome == .transportFailed(.unreachable))
        #expect(try await store.loadSyncCursor(stream: "default")?.lastServerVersion == 4)  // unchanged
    }

    // Unknown future schema is quarantined; nothing applied, cursor preserved.
    @Test func unsupportedSchemaIsQuarantined() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        await backend.enqueuePull(.success(response([change(1, "r1")], serverSchema: 999)))
        let outcome = try await engine(store, backend, clock: clock).pullOnce(context: context())
        #expect(outcome == .quarantinedUnsupportedSchema(serverSchemaVersion: 999))
        #expect(try await store.loadSyncCursor(stream: "default") == nil)      // never advanced
    }

    // Explicit tombstones are recorded.
    @Test func tombstonesAreRecordedExplicitly() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        await backend.enqueuePull(.success(response([change(1, "r1", op: .tombstone)])))
        _ = try await engine(store, backend, clock: clock).pullOnce(context: context())
        #expect(try await store.remoteRecordState(entityType: "workoutAssignment", localID: "r1")?.tombstoned == true)
    }

    // Account-scoped cursor isolation: applying to account A never touches account B.
    @Test func cursorIsAccountScoped() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mazidi-pull-\(UUID().uuidString)", isDirectory: true)
        let storeA = try GRDBStore.open(directory: AccountDatabasePath.directory(base: base, accountID: AccountID("acct-a")))
        let storeB = try GRDBStore.open(directory: AccountDatabasePath.directory(base: base, accountID: AccountID("acct-b")))
        let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        await backend.enqueuePull(.success(response([change(1, "r1")], accountContext: AccountID("acct-a"))))
        _ = try await BackendPullEngine(syncStore: storeA, transport: backend, clock: clock)
            .pullOnce(context: context(AccountID("acct-a")))
        #expect(try await storeA.loadSyncCursor(stream: "default")?.lastServerVersion == 1)
        #expect(try await storeB.loadSyncCursor(stream: "default") == nil)     // B untouched
        try storeA.close(); try storeB.close()
    }

    // A delayed response arriving after sign-out is ignored (session-generation guard).
    @Test func delayedResponseAfterSignOutIsIgnored() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        await backend.enqueuePull(.success(response([change(1, "r1")])))
        let outcome = try await engine(store, backend, clock: clock, isActive: { false }).pullOnce(context: context())
        #expect(outcome == .ignoredStale)
        #expect(try await store.loadSyncCursor(stream: "default") == nil)      // nothing applied
    }

    // A response echoing a DIFFERENT account is ignored (cross-account binding).
    @Test func responseForDifferentAccountIsIgnored() async throws {
        let store = try makeStore(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        await backend.enqueuePull(.success(response([change(1, "r1")], accountContext: AccountID("someone-else"))))
        let outcome = try await engine(store, backend, clock: clock).pullOnce(context: context())
        #expect(outcome == .ignoredStale)
        #expect(try await store.loadSyncCursor(stream: "default") == nil)
    }
}
