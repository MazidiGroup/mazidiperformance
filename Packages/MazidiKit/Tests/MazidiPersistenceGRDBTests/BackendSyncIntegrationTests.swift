import Foundation
import Testing
import MazidiAuth
import MazidiDomain
import MazidiFoundations
import MazidiNetworking
import MazidiPersistence
import MazidiSync
@testable import MazidiPersistenceGRDB

private let t0 = Date(timeIntervalSince1970: 1_784_000_000)

/// Mutable, sync-readable "session active" flag (the app flips this false on invalidate()).
private final class ActiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ v: Bool = true) { value = v }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

/// Minimal provider double so we can drive a real SessionCoordinator end-to-end.
private actor StubProvider: AuthProviding {
    let clock: FixedClock
    init(clock: FixedClock) { self.clock = clock }
    private func session() -> ProviderSession {
        let id = AccountID("dev-client-001")
        return ProviderSession(
            claims: SessionClaims(accountID: id, roles: [.client]),
            credentials: AuthCredentials(accountID: id, accessToken: "a", refreshToken: "r", accessTokenExpiresAt: clock.now().addingTimeInterval(3600)),
            authenticatedAt: clock.now()
        )
    }
    func signIn(_ request: SignInRequest) async throws -> ProviderSession { session() }
    func refresh(refreshToken: String, accountID: AccountID) async throws -> ProviderSession { session() }
    func restore(credentials: AuthCredentials) async throws -> RestoredSession {
        RestoredSession(claims: SessionClaims(accountID: credentials.accountID, roles: [.client]), rotatedCredentials: nil, validatedRemotely: true)
    }
    func signOut(accessToken: String, accountID: AccountID) async throws {}
    func checkRevocation(accountID: AccountID) async -> RevocationCheck { .unknown }
}

@Suite struct BackendSyncIntegrationTests {
    private let account = AccountID("dev-client-001")
    private let device = DeviceInstallationID("device-1")

    private func context(generation: UInt64 = 1) -> AuthenticatedRequestContext {
        AuthenticatedRequestContext(accountID: account, deviceInstallationID: device, generation: generation, accessToken: { "token" })
    }

    private func assignment() throws -> WorkoutAssignment {
        var template = WorkoutTemplate(
            draft: WorkoutTemplateContent(title: "Lower A", exercises: [
                PrescribedExercise(slug: "barbell-squat", order: 0, prescription: .repsAndLoad(sets: 3, reps: 5...8, loadKg: 80)),
            ]),
            updatedAt: t0
        )
        let version = try template.publish(at: t0)
        return WorkoutAssignment(version: version, assigneeAccountRef: "dev-client-001", assignedAt: t0)
    }

    private func assignmentChange(_ a: WorkoutAssignment, version: Int) throws -> ChangeEnvelope {
        ChangeEnvelope(entityType: .workoutAssignment, remoteID: RemoteRecordID("R-\(version)"),
                       serverVersion: ServerRecordVersion(version), op: .upsert,
                       payload: try JSONEncoder().encode(a), payloadSchemaVersion: 1)
    }

    private func response(_ changes: [ChangeEnvelope], token: String? = "cur") -> PullChangesResponse {
        PullChangesResponse(changes: changes, nextCursorToken: token.map(SyncCursorToken.init),
                            hasMore: false, serverSchemaVersion: 1, accountContext: account)
    }

    // (Pinned #1) Pull materialisation is atomic with the cursor advance: a delivered
    // assignment row and the cursor both land together.
    @Test func pullMaterializesAssignmentAtomicallyWithCursor() async throws {
        let store = try GRDBStore.inMemory(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        let a = try assignment()
        await backend.enqueuePull(.success(response([try assignmentChange(a, version: 1)])))
        let engine = BackendPullEngine(syncStore: store, transport: backend, clock: clock)
        let outcome = try await engine.pullOnce(context: context())

        #expect(outcome == .applied(applied: 1, ignored: 0, hasMore: false))
        #expect(try await store.assignment(id: a.id)?.assigneeAccountRef == "dev-client-001")  // materialised
        #expect(try await store.loadSyncCursor(stream: "default")?.lastServerVersion == 1)      // cursor advanced together
    }

    // An undecodable materialisable payload quarantines the batch — the cursor is NOT
    // advanced past a change whose domain effect could not be applied.
    @Test func undecodableAssignmentPayloadQuarantinesAndPreservesCursor() async throws {
        let store = try GRDBStore.inMemory(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        let bad = ChangeEnvelope(entityType: .workoutAssignment, remoteID: RemoteRecordID("R1"),
                                 serverVersion: ServerRecordVersion(1), op: .upsert, payload: Data("not-an-assignment".utf8), payloadSchemaVersion: 1)
        await backend.enqueuePull(.success(response([bad])))
        let outcome = try await BackendPullEngine(syncStore: store, transport: backend, clock: clock).pullOnce(context: context())
        #expect(outcome == .quarantinedUndecodablePayload(entityType: "workoutAssignment"))
        #expect(try await store.loadSyncCursor(stream: "default") == nil)      // never advanced
    }

    // (Pinned #3) The push engine emits sync audit events with ids-only subjects.
    @Test func pushEmitsAuditEventsWithIdsOnly() async throws {
        let store = try GRDBStore.inMemory(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        let op = SyncOperation(kind: .assignmentCreated, aggregateID: UUID(), sequence: 0, payload: Data("p".utf8), enqueuedAt: t0)
        try await store.enqueue(op)
        await backend.setPushResult(.applied(ServerRecordVersion(1)), for: MutationID(IdempotencyKey(op.idempotencyKey)))
        let engine = BackendPushEngine(outbox: store, syncStore: store, transport: backend, clock: clock, random: { 0 }, audit: store, actorID: UUID())
        _ = try await engine.pushOnce(context: context())

        let kinds = try await store.allEvents().map(\.kind)
        #expect(kinds.contains(.syncBatchAttempted))
        #expect(kinds.contains(.syncBatchAcknowledged))
        // No event subject or payload leaks content (ids/counts only).
        for event in try await store.allEvents() {
            #expect(!event.subjectDescription.contains("token"))
            #expect(event.payload.values.allSatisfy { !$0.lowercased().contains("token") })
        }
    }

    @Test func pushEmitsMutationPermanentlyRejected() async throws {
        let store = try GRDBStore.inMemory(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        let op = SyncOperation(kind: .assignmentCreated, aggregateID: UUID(), sequence: 0, payload: Data("p".utf8), enqueuedAt: t0)
        try await store.enqueue(op)
        await backend.setPushResult(.rejected(.validationFailed("bad")), for: MutationID(IdempotencyKey(op.idempotencyKey)))
        _ = try await BackendPushEngine(outbox: store, syncStore: store, transport: backend, clock: clock, random: { 0 }, audit: store, actorID: UUID())
            .pushOnce(context: context())
        #expect(try await store.allEvents().contains { $0.kind == .mutationPermanentlyRejected })
    }

    @Test func pullEmitsPullChangesApplied() async throws {
        let store = try GRDBStore.inMemory(); let backend = FakeSyncBackend(); let clock = FixedClock(t0)
        let a = try assignment()
        await backend.enqueuePull(.success(response([try assignmentChange(a, version: 1)])))
        _ = try await BackendPullEngine(syncStore: store, transport: backend, clock: clock, audit: store, actorID: UUID()).pullOnce(context: context())
        #expect(try await store.allEvents().contains { $0.kind == .pullChangesApplied })
    }

    // (Pinned #2) Transport .revoked routes to SessionCoordinator end-to-end: session moves
    // to .revoked, account-DB access is blocked, and further uploads stop (engine inactive).
    @Test func transportRevokedRoutesToCoordinatorAndStopsUploads() async throws {
        let clock = FixedClock(t0)
        let coordinator = SessionCoordinator(provider: StubProvider(clock: clock), credentials: InMemoryCredentialStore(), clock: clock)
        _ = await coordinator.signIn(.development(identity: "dev-client-001"))
        let generation = await coordinator.generation

        let store = try GRDBStore.inMemory(); let backend = FakeSyncBackend()
        let active = ActiveFlag(true)
        let op = SyncOperation(kind: .assignmentCreated, aggregateID: UUID(), sequence: 0, payload: Data("p".utf8), enqueuedAt: t0)
        try await store.enqueue(op)
        let engine = BackendPushEngine(outbox: store, syncStore: store, transport: backend, clock: clock,
                                       random: { 0 }, isActive: { active.get() })

        await backend.setPushError(.revoked)
        let summary = try await engine.pushOnce(context: context(generation: generation))
        #expect(summary.revoked)

        // The app routes a confirmed revocation to the coordinator and tears down the env.
        _ = await coordinator.revocationReported(forGeneration: generation)
        active.set(false)

        guard case .revoked = await coordinator.phase else { Issue.record("expected .revoked"); return }
        #expect(await coordinator.phase.allowsAccountDataAccess == false)   // DB access blocked
        // No pending work uploads after confirmed revocation.
        let after = try await engine.pushOnce(context: context(generation: generation))
        #expect(after.skippedInactive)
        #expect(await backend.pushCallCount == 1)                          // only the first (revoked) attempt
        #expect(try await store.pendingOperations().first?.id == op.id)    // op still queued, not dropped
    }

    // A transport .unknown never routes to revocation — the session stays authenticated and
    // uploads continue (offline can never claim revocation knowledge).
    @Test func transportUnknownDoesNotRevokeAndUploadsContinue() async throws {
        let clock = FixedClock(t0)
        let coordinator = SessionCoordinator(provider: StubProvider(clock: clock), credentials: InMemoryCredentialStore(), clock: clock)
        _ = await coordinator.signIn(.development(identity: "dev-client-001"))
        // .unknown is never surfaced as revoked by the transport contract; the coordinator
        // stays authenticated.
        await coordinator.checkRevocationAfterReconnect()
        guard case .authenticated = await coordinator.phase else { Issue.record("unknown must not revoke"); return }

        let store = try GRDBStore.inMemory(); let backend = FakeSyncBackend()
        let op = SyncOperation(kind: .assignmentCreated, aggregateID: UUID(), sequence: 0, payload: Data("p".utf8), enqueuedAt: t0)
        try await store.enqueue(op)
        await backend.setPushResult(.applied(ServerRecordVersion(1)), for: MutationID(IdempotencyKey(op.idempotencyKey)))
        let summary = try await BackendPushEngine(outbox: store, syncStore: store, transport: backend, clock: clock, random: { 0 })
            .pushOnce(context: context())
        #expect(summary.acknowledged == 1)                                 // uploads continue
    }
}
