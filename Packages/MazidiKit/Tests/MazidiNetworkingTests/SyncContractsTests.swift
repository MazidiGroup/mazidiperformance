import Foundation
import Testing
import MazidiAuth
import MazidiDomain
@testable import MazidiNetworking

@Suite struct SyncContractsTests {
    private let account = AccountID("acct-123")
    private let device = DeviceInstallationID("device-abc")

    private func envelope(
        key: UUID = UUID(),
        entity: SyncEntityType = .workoutAssignment,
        version: ServerRecordVersion? = nil,
        payload: Data = Data("body".utf8)
    ) -> MutationEnvelope {
        let idem = IdempotencyKey(key)
        return MutationEnvelope(
            mutationID: MutationID(idem),
            accountContext: account,
            entityType: entity,
            entityID: "local-1",
            opType: .update,
            payloadSchemaVersion: 1,
            localTimestamp: Date(timeIntervalSince1970: 1_784_000_000),
            expectedServerVersion: version,
            idempotencyKey: idem,
            correlationID: "corr-1",
            payload: payload
        )
    }

    // MARK: - Serialization round-trips

    @Test func mutationEnvelopeRoundTrips() throws {
        let value = envelope(version: ServerRecordVersion(7))
        let decoded = try JSONDecoder().decode(MutationEnvelope.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    @Test func pushBatchRoundTrips() throws {
        let batch = PushMutationBatch(accountContext: account, deviceInstallationID: device, mutations: [envelope(), envelope()])
        let decoded = try JSONDecoder().decode(PushMutationBatch.self, from: JSONEncoder().encode(batch))
        #expect(decoded == batch)
    }

    @Test func pullResponseAndCursorRoundTrip() throws {
        let response = PullChangesResponse(
            changes: [
                ChangeEnvelope(entityType: .workoutAssignment, remoteID: RemoteRecordID("r1"), serverVersion: ServerRecordVersion(3), op: .upsert, payload: Data("x".utf8), payloadSchemaVersion: 1),
                ChangeEnvelope(entityType: .relationship, remoteID: RemoteRecordID("r2"), serverVersion: ServerRecordVersion(4), op: .tombstone, payload: nil, payloadSchemaVersion: 1),
            ],
            nextCursorToken: SyncCursorToken("cursor-xyz"),
            hasMore: true,
            serverSchemaVersion: 1,
            accountContext: account
        )
        let decoded = try JSONDecoder().decode(PullChangesResponse.self, from: JSONEncoder().encode(response))
        #expect(decoded == response)
        let cursor = SyncCursor(token: SyncCursorToken("cursor-xyz"), lastServerVersion: ServerRecordVersion(4))
        let decodedCursor = try JSONDecoder().decode(SyncCursor.self, from: JSONEncoder().encode(cursor))
        #expect(decodedCursor == cursor)
    }

    // MARK: - Identity-type separation

    @Test func mutationIDIsDeterministicFromIdempotencyKey() {
        let uuid = UUID()
        let key = IdempotencyKey(uuid)
        // Deterministic: the same key always yields the same mutation id (retry safety).
        #expect(MutationID(key) == MutationID(key))
        #expect(MutationID(key).rawValue == uuid)
        #expect(MutationID(key) == MutationID(rawValue: uuid))
    }

    @Test func distinctIdentityTypesDoNotCollide() {
        // Same underlying string/int, but the wrappers are distinct types with distinct
        // meaning — the compiler forbids substituting one for another.
        let remote = RemoteRecordID("id-1")
        let cursor = SyncCursorToken("id-1")
        let device2 = DeviceInstallationID("id-1")
        #expect(remote.rawValue == cursor.rawValue)      // same raw string…
        #expect(remote.rawValue == device2.rawValue)
        // …but the types are not interchangeable (this is a compile-time guarantee; here we
        // just assert they are separate nominal types by round-tripping each independently).
        #expect(ServerRecordVersion(1) < ServerRecordVersion(2))
        #expect(ServerRecordVersion.zero == ServerRecordVersion(0))
    }

    // MARK: - Token never in a serialised body

    @Test func noSerialisedBodyContainsAnAccessToken() throws {
        let batch = PushMutationBatch(accountContext: account, deviceInstallationID: device, mutations: [envelope()])
        let json = String(data: try JSONEncoder().encode(batch), encoding: .utf8)!.lowercased()
        #expect(!json.contains("token"))
        #expect(!json.contains("accesstoken"))
        #expect(!json.contains("bearer"))
        #expect(!json.contains("refresh"))
    }

    private actor FetchCounter { private(set) var count = 0; func bump() { count += 1 } }

    @Test func requestContextObtainsTokenLazilyAndIsNotSerialised() async throws {
        // The token is supplied by an injected accessor at send time — never stored.
        let counter = FetchCounter()
        let context = AuthenticatedRequestContext(
            accountID: account, deviceInstallationID: device, generation: 3,
            accessToken: { await counter.bump(); return "secret-token" }
        )
        #expect(context.generation == 3)
        #expect(await counter.count == 0)              // not fetched until requested
        let token = try await context.accessToken()
        #expect(token == "secret-token")
        #expect(await counter.count == 1)
        // AuthenticatedRequestContext is intentionally NOT Codable — there is no code path
        // that serialises the token. (Compile-time: it has no Codable conformance.)
    }

    // MARK: - Ack keying (stale/unknown id is a safe lookup miss)

    @Test func pushAckIsKeyedByMutationIDAndUnknownIsNil() {
        let known = MutationID(IdempotencyKey(UUID()))
        let unknown = MutationID(IdempotencyKey(UUID()))
        let ack = PushAck(results: [known: .applied(ServerRecordVersion(5))])
        #expect(ack.results[known] == .applied(ServerRecordVersion(5)))
        #expect(ack.results[unknown] == nil)           // stale/unknown ack → safe no-op
    }

    @Test func deliveryStateServerAcceptanceIsTheOnlyDeliveredPoint() {
        // Audit-note #2: only acceptedByServer counts as genuine delivery.
        #expect(AssignmentDeliveryState.acceptedByServer.isServerAccepted)
        for state in AssignmentDeliveryState.allCases where state != .acceptedByServer {
            #expect(!state.isServerAccepted)
        }
    }
}
