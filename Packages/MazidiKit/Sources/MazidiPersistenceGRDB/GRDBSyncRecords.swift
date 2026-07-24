import Foundation
import GRDB
import MazidiDomain
import MazidiFoundations

// ─────────────────────────────────────────────────────────────────────────────
//  v3 backend-sync metadata rows (ADR-0012). Internal to the GRDB adapter (ADR-0007:
//  only this target imports GRDB). These carry ONLY sync metadata (ids, versions,
//  cursors, delivery state) — never a copy of a domain payload snapshot. The push/pull
//  engine (CG4/CG5) maps these to the provider-neutral MazidiNetworking contracts.
// ─────────────────────────────────────────────────────────────────────────────

/// `sync_cursor` — durable, account-scoped pull checkpoint.
struct SyncCursorRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "sync_cursor"

    var stream: String
    var cursorToken: String?
    var lastServerVersion: Int
    var schemaVersion: Int
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case stream
        case cursorToken = "cursor_token"
        case lastServerVersion = "last_server_version"
        case schemaVersion = "schema_version"
        case updatedAt = "updated_at"
    }
}

/// `remote_record` — local↔remote id mapping + server version + tombstone flag.
struct RemoteRecordRow: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "remote_record"

    var entityType: String
    var localId: String
    var remoteId: String?
    var serverVersion: Int
    var tombstoned: Bool
    var lastSyncedAt: Date?

    enum CodingKeys: String, CodingKey {
        case entityType = "entity_type"
        case localId = "local_id"
        case remoteId = "remote_id"
        case serverVersion = "server_version"
        case tombstoned
        case lastSyncedAt = "last_synced_at"
    }
}

/// `relationship` — Coach–Client relationship (opaque account ids, never email).
struct RelationshipRow: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "relationship"

    var id: String
    var remoteId: String?
    var coachAccountId: String
    var clientAccountId: String
    var status: String
    var createdAt: Date
    var acceptedAt: Date?
    var endedAt: Date?
    var serverVersion: Int
    var localSyncState: String

    enum CodingKeys: String, CodingKey {
        case id, status
        case remoteId = "remote_id"
        case coachAccountId = "coach_account_id"
        case clientAccountId = "client_account_id"
        case createdAt = "created_at"
        case acceptedAt = "accepted_at"
        case endedAt = "ended_at"
        case serverVersion = "server_version"
        case localSyncState = "local_sync_state"
    }
}

/// Projection of the `workout_assignment` delivery/receipt columns (read/updated without
/// touching the immutable `content_json` snapshot).
struct AssignmentDeliveryRow: Codable, FetchableRecord, TableRecord, Equatable {
    static let databaseTableName = "workout_assignment"

    var id: String
    var remoteId: String?
    var serverVersion: Int
    var relationshipId: String?
    var deliveryState: String
    var deliveredAt: Date?
    var openedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case remoteId = "remote_id"
        case serverVersion = "server_version"
        case relationshipId = "relationship_id"
        case deliveryState = "delivery_state"
        case deliveredAt = "delivered_at"
        case openedAt = "opened_at"
    }
}

// MARK: - Store accessors (internal; consumed by CG4–CG8 and the migration tests)

extension GRDBStore {
    // Cursor
    func syncCursor(stream: String) async throws -> SyncCursorRecord? {
        try await writer.read { db in try SyncCursorRecord.fetchOne(db, key: stream) }
    }

    func saveSyncCursor(_ record: SyncCursorRecord) async throws {
        try await writer.write { db in try record.save(db) }
    }

    // Remote record mapping
    func remoteRecord(entityType: String, localID: String) async throws -> RemoteRecordRow? {
        try await writer.read { db in
            try RemoteRecordRow.filter(Column("entity_type") == entityType && Column("local_id") == localID).fetchOne(db)
        }
    }

    func remoteRecord(entityType: String, remoteID: String) async throws -> RemoteRecordRow? {
        try await writer.read { db in
            try RemoteRecordRow.filter(Column("entity_type") == entityType && Column("remote_id") == remoteID).fetchOne(db)
        }
    }

    func upsertRemoteRecord(_ record: RemoteRecordRow) async throws {
        try await writer.write { db in try record.save(db) }
    }

    // Relationships
    func relationship(id: String) async throws -> RelationshipRow? {
        try await writer.read { db in try RelationshipRow.fetchOne(db, key: id) }
    }

    func allRelationships() async throws -> [RelationshipRow] {
        try await writer.read { db in try RelationshipRow.order(Column("created_at")).fetchAll(db) }
    }

    func saveRelationship(_ record: RelationshipRow) async throws {
        try await writer.write { db in try record.save(db) }
    }

    // Assignment delivery/receipt columns
    func assignmentDelivery(id: Identifier<WorkoutAssignment>) async throws -> AssignmentDeliveryRow? {
        let key = id.rawValue.uuidString
        return try await writer.read { db in try AssignmentDeliveryRow.fetchOne(db, key: key) }
    }

    /// Update only the delivery/receipt/remote-binding columns; the immutable snapshot and
    /// execution `status` are untouched.
    func updateAssignmentDelivery(
        id: Identifier<WorkoutAssignment>,
        state: AssignmentDeliveryState,
        remoteID: String?,
        serverVersion: Int,
        relationshipID: String?,
        deliveredAt: Date?,
        openedAt: Date?
    ) async throws {
        let key = id.rawValue.uuidString
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE workout_assignment
                SET delivery_state = ?, remote_id = ?, server_version = ?, relationship_id = ?,
                    delivered_at = ?, opened_at = ?
                WHERE id = ?
                """, arguments: [state.rawValue, remoteID, serverVersion, relationshipID, deliveredAt, openedAt, key])
        }
    }
}
