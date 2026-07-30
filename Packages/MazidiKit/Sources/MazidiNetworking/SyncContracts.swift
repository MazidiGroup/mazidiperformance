import Foundation
import MazidiAuth
import MazidiDomain
import MazidiFoundations

// ─────────────────────────────────────────────────────────────────────────────
//  Provider-neutral backend synchronisation contracts (ADR-0012).
//  PROPOSED — no backend exists (R-01/R-02). No provider SDK type appears here; no
//  hostname/credential/tenant/API key/signed URL is hard-coded (the base URL is injected
//  from `SYNC_BASE_URL` via .xcconfig, empty → inert). No provider is chosen.
//
//  Identity types are DISTINCT wrappers so the compiler forbids using a remote id where a
//  local id / mutation id / cursor / server version is expected (ADR-0012 §2). Serialised
//  bodies (envelope/batch/pull) are Codable and carry NO access token — the token is
//  fetched at send time through an injected accessor on the non-Codable request context.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Distinct identity types

/// Server-assigned record id (opaque). Never a local UUID, never an account id.
public struct RemoteRecordID: Hashable, Sendable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Local id of a Coach–Client relationship (ADR-0012 §6). Client-minted.
public struct RelationshipID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Client-generated idempotency key: minted once per operation at enqueue, reused verbatim
/// on every retry so the server applies it at most once (ADR-0003, ADR-0012 §3).
public struct IdempotencyKey: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

/// The deterministic mutation identifier = the operation's idempotency key. A retry never
/// mints a new one, so no duplicate application can occur (ADR-0012 §2).
public struct MutationID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(_ key: IdempotencyKey) { self.rawValue = key.rawValue }
    /// Restoration/parse initializer (from a stored/acked raw uuid).
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Device-global, non-secret installation id (namespaces idempotency, identifies the
/// sender). Lives in device-global UserDefaults, never a per-account table (ADR-0012 §2).
public struct DeviceInstallationID: Hashable, Sendable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Opaque server-provided pull continuation token — never interpreted client-side.
public struct SyncCursorToken: Hashable, Sendable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Monotonic server record version for optimistic concurrency (ADR-0012 §3/§5).
public struct ServerRecordVersion: Hashable, Sendable, Codable, Comparable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public static func < (lhs: ServerRecordVersion, rhs: ServerRecordVersion) -> Bool { lhs.rawValue < rhs.rawValue }
    public static let zero = ServerRecordVersion(0)
}

/// The entity a mutation/change concerns. Typed so routing/dead-letter queries never parse
/// an operation kind string.
public enum SyncEntityType: String, Sendable, Codable, CaseIterable {
    case workoutSession
    case setEntry
    case exerciseSwap
    case workoutTemplate
    case templateVersion
    case workoutAssignment
    case relationship
    case auditEvent
    /// Health-data consent records (ADR-0013 consent model). The payload carries ids,
    /// purpose identifiers, the notice version and timestamps — never health content.
    case healthDataConsent
}

public enum MutationOpType: String, Sendable, Codable {
    case create
    case update
    case delete
}

/// The pull stream (allows independent cursors later; "default" today).
public struct SyncStream: Hashable, Sendable, Codable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let `default` = SyncStream("default")
}

// MARK: - Push (mutation upload)

/// One mutation to upload. Codable body — **contains no access token** (fetched at send
/// time from the request context). `payloadSchemaVersion` lets payloads upgrade forward.
public struct MutationEnvelope: Sendable, Codable, Equatable {
    public let mutationID: MutationID
    public let accountContext: AccountID
    public let entityType: SyncEntityType
    /// Local entity id (the aggregate id) — never a remote id.
    public let entityID: String
    public let opType: MutationOpType
    public let payloadSchemaVersion: Int
    /// From the injected clock (deterministic tests) — never `Date()`.
    public let localTimestamp: Date
    /// Present only when the mutation targets an existing server record (optimistic concurrency).
    public let expectedServerVersion: ServerRecordVersion?
    public let idempotencyKey: IdempotencyKey
    /// Trace correlation only — never sensitive content.
    public let correlationID: String?
    public let payload: Data

    public init(
        mutationID: MutationID,
        accountContext: AccountID,
        entityType: SyncEntityType,
        entityID: String,
        opType: MutationOpType,
        payloadSchemaVersion: Int,
        localTimestamp: Date,
        expectedServerVersion: ServerRecordVersion?,
        idempotencyKey: IdempotencyKey,
        correlationID: String?,
        payload: Data
    ) {
        self.mutationID = mutationID
        self.accountContext = accountContext
        self.entityType = entityType
        self.entityID = entityID
        self.opType = opType
        self.payloadSchemaVersion = payloadSchemaVersion
        self.localTimestamp = localTimestamp
        self.expectedServerVersion = expectedServerVersion
        self.idempotencyKey = idempotencyKey
        self.correlationID = correlationID
        self.payload = payload
    }
}

/// A batch of mutations for one account/device. No token in the body.
public struct PushMutationBatch: Sendable, Codable, Equatable {
    public let batchID: UUID
    public let accountContext: AccountID
    public let deviceInstallationID: DeviceInstallationID
    public let mutations: [MutationEnvelope]

    public init(batchID: UUID = UUID(), accountContext: AccountID, deviceInstallationID: DeviceInstallationID, mutations: [MutationEnvelope]) {
        self.batchID = batchID
        self.accountContext = accountContext
        self.deviceInstallationID = deviceInstallationID
        self.mutations = mutations
    }
}

/// Why a mutation was permanently rejected (never retried — parked/dead-lettered).
public enum PermanentRejection: Sendable, Equatable, Codable {
    case validationFailed(String)
    case unauthorized
    case forbidden
    case conflict(ServerRecordVersion)
    case relationshipEnded
    case unsupported(String)
}

/// Retry guidance for a transient failure.
public struct TransportRetry: Sendable, Equatable, Codable {
    public let retryAfter: TimeInterval?
    public init(retryAfter: TimeInterval? = nil) { self.retryAfter = retryAfter }
}

/// Per-mutation server result (partial-batch acks supported).
public enum MutationResult: Sendable, Equatable {
    case applied(ServerRecordVersion)
    case duplicateApplied(ServerRecordVersion)
    case rejected(PermanentRejection)
    case needsRetry(TransportRetry)
}

/// The server's response to a push batch: results keyed by mutation id. An ack for a
/// stale/unknown mutation id is safely ignored by the caller (ADR-0012 §3).
public struct PushAck: Sendable, Equatable {
    public let results: [MutationID: MutationResult]
    public init(results: [MutationID: MutationResult]) { self.results = results }
}

// MARK: - Pull (change download)

public enum ChangeOp: String, Sendable, Codable {
    case upsert
    case tombstone
}

/// One remote change. `payload` is nil for a tombstone. `payloadSchemaVersion` gates
/// forward-compat (an unknown future version is quarantined, never applied).
public struct ChangeEnvelope: Sendable, Codable, Equatable {
    public let entityType: SyncEntityType
    public let remoteID: RemoteRecordID
    public let serverVersion: ServerRecordVersion
    public let op: ChangeOp
    public let payload: Data?
    public let payloadSchemaVersion: Int

    public init(entityType: SyncEntityType, remoteID: RemoteRecordID, serverVersion: ServerRecordVersion, op: ChangeOp, payload: Data?, payloadSchemaVersion: Int) {
        self.entityType = entityType
        self.remoteID = remoteID
        self.serverVersion = serverVersion
        self.op = op
        self.payload = payload
        self.payloadSchemaVersion = payloadSchemaVersion
    }
}

/// Explicit remote deletion marker (ADR-0012 §4) — deletion is never inferred from absence.
public struct RemoteTombstone: Sendable, Codable, Equatable {
    public let entityType: SyncEntityType
    public let remoteID: RemoteRecordID
    public let serverVersion: ServerRecordVersion

    public init(entityType: SyncEntityType, remoteID: RemoteRecordID, serverVersion: ServerRecordVersion) {
        self.entityType = entityType
        self.remoteID = remoteID
        self.serverVersion = serverVersion
    }
}

public struct PullChangesRequest: Sendable, Codable, Equatable {
    public let accountContext: AccountID
    public let stream: SyncStream
    public let cursorToken: SyncCursorToken?
    public let maxChanges: Int

    public init(accountContext: AccountID, stream: SyncStream = .default, cursorToken: SyncCursorToken?, maxChanges: Int) {
        self.accountContext = accountContext
        self.stream = stream
        self.cursorToken = cursorToken
        self.maxChanges = maxChanges
    }
}

public struct PullChangesResponse: Sendable, Codable, Equatable {
    public let changes: [ChangeEnvelope]
    public let nextCursorToken: SyncCursorToken?
    public let hasMore: Bool
    public let serverSchemaVersion: Int
    /// Echoed so the caller can bind the response to the active account before applying.
    public let accountContext: AccountID

    public init(changes: [ChangeEnvelope], nextCursorToken: SyncCursorToken?, hasMore: Bool, serverSchemaVersion: Int, accountContext: AccountID) {
        self.changes = changes
        self.nextCursorToken = nextCursorToken
        self.hasMore = hasMore
        self.serverSchemaVersion = serverSchemaVersion
        self.accountContext = accountContext
    }
}

/// The durable pull checkpoint value (persisted in `sync_cursor`, CG3).
public struct SyncCursor: Sendable, Codable, Equatable {
    public let token: SyncCursorToken?
    public let lastServerVersion: ServerRecordVersion

    public init(token: SyncCursorToken?, lastServerVersion: ServerRecordVersion) {
        self.token = token
        self.lastServerVersion = lastServerVersion
    }

    public static let initial = SyncCursor(token: nil, lastServerVersion: .zero)
}

// MARK: - Delivery & revocation

/// Server confirmation of an assignment's delivery state (ADR-0012 §7).
public struct DeliveryAck: Sendable, Codable, Equatable {
    public let remoteID: RemoteRecordID
    public let serverVersion: ServerRecordVersion
    public let deliveryState: AssignmentDeliveryState

    public init(remoteID: RemoteRecordID, serverVersion: ServerRecordVersion, deliveryState: AssignmentDeliveryState) {
        self.remoteID = remoteID
        self.serverVersion = serverVersion
        self.deliveryState = deliveryState
    }
}

/// Rate-limit guidance from the server.
public struct RateLimit: Sendable, Equatable, Codable {
    public let retryAfter: TimeInterval
    public init(retryAfter: TimeInterval) { self.retryAfter = retryAfter }
}

/// Typed transport failures — no untyped `Error` leaks to callers. `revoked`/`unauthorized`
/// route to the SessionCoordinator (ADR-0012 §8); `conflict` carries the server version.
public enum TransportError: Error, Sendable, Equatable {
    case unreachable
    case timeout
    case rateLimited(RateLimit)
    case unauthorized
    case forbidden
    case revoked
    case conflict(ServerRecordVersion)
    case serverError(status: Int)
    case malformedResponse
    case cancelled
}

// MARK: - Request context (non-Codable — the token never enters a serialised body)

/// Per-request authentication context. It is deliberately NOT Codable: the access token is
/// obtained lazily through the injected accessor at send time and never stored, serialised,
/// or logged (ADR-0008 credentials-in-Keychain-only, ADR-0012 §1/§2). Carries the session
/// `generation` so a delayed prior-account/prior-session response can be discarded.
public struct AuthenticatedRequestContext: Sendable {
    public let accountID: AccountID
    public let deviceInstallationID: DeviceInstallationID
    public let generation: UInt64
    public let accessToken: @Sendable () async throws -> String

    public init(accountID: AccountID, deviceInstallationID: DeviceInstallationID, generation: UInt64, accessToken: @escaping @Sendable () async throws -> String) {
        self.accountID = accountID
        self.deviceInstallationID = deviceInstallationID
        self.generation = generation
        self.accessToken = accessToken
    }
}

// MARK: - Transport protocol

/// The provider-neutral sync transport (ADR-0012 §1). Result-typed (no `throws`), honours
/// Swift structured-concurrency cancellation, performs NO internal retry (the engine owns
/// backoff). The only implementation until a backend exists is the DEBUG/test fake.
public protocol SyncBackendTransport: Sendable {
    func push(_ batch: PushMutationBatch, context: AuthenticatedRequestContext) async -> Result<PushAck, TransportError>
    func pull(_ request: PullChangesRequest, context: AuthenticatedRequestContext) async -> Result<PullChangesResponse, TransportError>
    func acknowledgeDelivery(remoteID: RemoteRecordID, context: AuthenticatedRequestContext) async -> Result<DeliveryAck, TransportError>
    func checkRevocation(context: AuthenticatedRequestContext) async -> RevocationCheck
}
