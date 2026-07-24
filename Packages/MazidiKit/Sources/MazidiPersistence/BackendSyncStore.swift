import Foundation

// ─────────────────────────────────────────────────────────────────────────────
//  Backend-sync persistence boundary (ADR-0012). Primitive-typed on purpose: this
//  contract layer imports Foundation only (no networking types), so the push/pull
//  engine (MazidiSync) maps the provider-neutral wire contracts to/from these values.
//  GRDBStore implements it durably/transactionally; a test double implements it in-memory.
// ─────────────────────────────────────────────────────────────────────────────

/// Local↔remote identity + server version + tombstone (primitive projection of `remote_record`).
public struct RemoteRecordState: Sendable, Equatable {
    public let entityType: String
    public let localID: String
    public let remoteID: String?
    public let serverVersion: Int
    public let tombstoned: Bool
    public let lastSyncedAt: Date?

    public init(entityType: String, localID: String, remoteID: String?, serverVersion: Int, tombstoned: Bool, lastSyncedAt: Date?) {
        self.entityType = entityType
        self.localID = localID
        self.remoteID = remoteID
        self.serverVersion = serverVersion
        self.tombstoned = tombstoned
        self.lastSyncedAt = lastSyncedAt
    }
}

/// Durable pull checkpoint (primitive projection of `sync_cursor`).
public struct SyncCursorState: Sendable, Equatable {
    public let token: String?
    public let lastServerVersion: Int
    public let schemaVersion: Int

    public init(token: String?, lastServerVersion: Int, schemaVersion: Int) {
        self.token = token
        self.lastServerVersion = lastServerVersion
        self.schemaVersion = schemaVersion
    }

    public static let initial = SyncCursorState(token: nil, lastServerVersion: 0, schemaVersion: 1)
}

/// One outbox operation's resolved push outcome, ready to persist.
public struct PushOutcomeApplication: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Server applied (or replayed) — remove from the queue and record the server version.
        case acknowledged(remoteID: String?, serverVersion: Int)
        /// Permanent failure — park as rejected (dead-letter), user-visible, never dropped.
        case deadLettered(reason: String)
        /// Transient — keep queued, not due until `nextAttemptAt` (backoff).
        case retry(nextAttemptAt: Date, reason: String)
    }

    public let operationID: UUID
    public let entityType: String
    public let localEntityID: String
    public let outcome: Outcome

    public init(operationID: UUID, entityType: String, localEntityID: String, outcome: Outcome) {
        self.operationID = operationID
        self.entityType = entityType
        self.localEntityID = localEntityID
        self.outcome = outcome
    }
}

public protocol BackendSyncStore: Sendable {
    /// Apply a batch of push outcomes in ONE transaction: update each outbox row's
    /// status/error/next_attempt_at AND, on acknowledgement, upsert its `remote_record`
    /// server version. Either all effects for the batch land, or none (ADR-0012 §3).
    func applyPushResults(_ applications: [PushOutcomeApplication], at now: Date) async throws

    /// Read/write the account-scoped pull cursor (CG5).
    func loadSyncCursor(stream: String) async throws -> SyncCursorState?
    func saveSyncCursor(_ cursor: SyncCursorState, stream: String, at now: Date) async throws

    /// Read a remote-record mapping (CG5).
    func remoteRecordState(entityType: String, localID: String) async throws -> RemoteRecordState?
}
