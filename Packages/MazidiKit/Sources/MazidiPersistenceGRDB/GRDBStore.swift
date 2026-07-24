import Foundation
import GRDB
import MazidiDomain
import MazidiFoundations
import MazidiPersistence
import MazidiSync

/// Durable SQLite implementation of the persistence contracts (ADR-0002/0003/0006/0007):
/// one store, one database, one transaction scope — exactly the shape the in-memory
/// reference implementation models. All three roles read/write the same `DatabaseWriter`,
/// so `saveAtomically` really is a single SQLite transaction.
///
/// Thread-safety: GRDB's writers serialise access; the only mutable state here is the
/// test-only failure hook, guarded by a lock (hence `@unchecked Sendable`).
public final class GRDBStore: @unchecked Sendable {
    let writer: any DatabaseWriter
    private let hookLock = NSLock()
    private var _atomicWriteHook: (@Sendable () throws -> Void)?

    /// Test seam (ADR-0003 crash-safety proof): runs *inside* the `saveAtomically`
    /// transaction, after the session rows are written and before the outbox rows are
    /// inserted. A throwing hook must roll back both halves.
    func setAtomicWriteHook(_ hook: (@Sendable () throws -> Void)?) {
        hookLock.lock(); defer { hookLock.unlock() }
        _atomicWriteHook = hook
    }

    private var atomicWriteHook: (@Sendable () throws -> Void)? {
        hookLock.lock(); defer { hookLock.unlock() }
        return _atomicWriteHook
    }

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: - Opening (factory + corruption policy, MIGRATIONS.md)

    public enum OpenError: Error {
        /// The database could not be opened/migrated even after moving a damaged file
        /// aside and starting fresh.
        case unrecoverable(underlying: Error)
    }

    /// Open (or create) the durable store at `directory/filename`, applying migrations.
    /// Policy (MIGRATIONS.md): if opening or migrating fails, the damaged file and its
    /// WAL side files are moved to `<filename>.corrupt-<UTC timestamp>` — preserved for
    /// diagnostics, never deleted — and a fresh database is created. A second failure is
    /// unrecoverable and thrown to the caller.
    public static func open(
        directory: URL,
        filename: String = "mazidi-client.sqlite",
        log: AppLog = AppLog(category: "persistence")
    ) throws -> GRDBStore {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)

        do {
            return GRDBStore(writer: try makePool(at: url))
        } catch {
            log.error("Opening \(filename) failed (\(error)); preserving file aside and starting fresh")
            setAside(url, fileManager: fm, log: log)
            do {
                return GRDBStore(writer: try makePool(at: url))
            } catch {
                throw OpenError.unrecoverable(underlying: error)
            }
        }
    }

    /// In-memory store: tests, previews, and the DEBUG ephemeral app mode.
    public static func inMemory() throws -> GRDBStore {
        let queue = try DatabaseQueue()
        try GRDBSchema.migrator().migrate(queue)
        return GRDBStore(writer: queue)
    }

    private static func makePool(at url: URL) throws -> DatabasePool {
        let pool = try DatabasePool(path: url.path)
        #if os(iOS)
        // iOS Data Protection (ADR-0002): complete-until-first-unlock so background sync
        // can run after reboot. Best-effort assertion of the class we document — iOS
        // already applies this class to app files by default. SQLCipher-style encryption
        // remains pending DL-07 (documented, not fabricated).
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path + suffix
            )
        }
        #endif
        try GRDBSchema.migrator().migrate(pool)
        return pool
    }

    private static func setAside(_ url: URL, fileManager fm: FileManager, log: AppLog) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: url.path + ".corrupt-\(stamp)" + suffix)
            do {
                try fm.moveItem(at: source, to: destination)
            } catch {
                log.error("Could not preserve \(source.lastPathComponent): \(error)")
            }
        }
    }
}

// MARK: - WorkoutSessionRepository

extension GRDBStore: WorkoutSessionRepository {
    public func save(_ session: WorkoutSession) async throws {
        try await writer.write { db in
            try Self.persist(session, in: db)
        }
    }

    public func session(id: Identifier<WorkoutSession>) async throws -> WorkoutSession? {
        let key = id.rawValue.uuidString
        return try await writer.read { db in
            try Self.fetchSession(id: key, in: db)
        }
    }

    public func resumableSession() async throws -> WorkoutSession? {
        try await writer.read { db in
            let phases = [WorkoutSession.Phase.notStarted, .active, .paused].map(\.rawValue)
            guard let record = try WorkoutSessionRecord
                .filter(phases.contains(Column("phase")))
                .fetchOne(db)
            else { return nil }
            return try Self.assemble(record, in: db)
        }
    }

    public func allSessions() async throws -> [WorkoutSession] {
        try await writer.read { db in
            try WorkoutSessionRecord.fetchAll(db).map { try Self.assemble($0, in: db) }
        }
    }

    /// Write the full session aggregate: session row upserted; set entries upserted by
    /// primary key (append-only in the domain, so this never rewrites history — the
    /// UNIQUE(session, exercise, set_index) constraint would surface any violation);
    /// swaps replaced wholesale (they are a small, revocable mapping).
    fileprivate static func persist(_ session: WorkoutSession, in db: Database) throws {
        try WorkoutSessionRecord(session: session).save(db)
        for entry in session.setEntries {
            try SetEntryRecord(entry: entry, sessionID: session.id).save(db)
        }
        let sessionKey = session.id.rawValue.uuidString
        try ExerciseSwapRecord
            .filter(Column("session_id") == sessionKey)
            .deleteAll(db)
        for (exerciseID, slug) in session.swaps {
            try ExerciseSwapRecord(
                sessionId: sessionKey,
                exerciseId: exerciseID.rawValue.uuidString,
                performedSlug: slug.rawValue
            ).save(db)
        }
    }

    fileprivate static func fetchSession(id: String, in db: Database) throws -> WorkoutSession? {
        guard let record = try WorkoutSessionRecord.fetchOne(db, key: id) else { return nil }
        return try assemble(record, in: db)
    }

    fileprivate static func assemble(_ record: WorkoutSessionRecord, in db: Database) throws -> WorkoutSession {
        let entries = try SetEntryRecord
            .filter(Column("session_id") == record.id)
            .order(sql: "rowid")
            .fetchAll(db)
            .map { try $0.toDomain() }
        let swapRecords = try ExerciseSwapRecord
            .filter(Column("session_id") == record.id)
            .fetchAll(db)
        var swaps: [Identifier<AssignedExercise>: ExerciseSlug] = [:]
        for swap in swapRecords {
            guard let uuid = UUID(uuidString: swap.exerciseId) else {
                throw RecordMappingError.badUUID(table: "exercise_swap", column: "exercise_id", value: swap.exerciseId)
            }
            swaps[Identifier<AssignedExercise>(uuid)] = ExerciseSlug(swap.performedSlug)
        }
        return try record.toDomain(entries: entries, swaps: swaps)
    }
}

// MARK: - SyncOperationStore (ADR-0003 outbox)

extension GRDBStore: SyncOperationStore {
    public typealias Operation = SyncOperation

    /// The crash-safety invariant: session snapshot + outbox rows in ONE transaction —
    /// either both commit or neither does.
    public func saveAtomically(session: WorkoutSession, enqueueing operations: [SyncOperation]) async throws {
        let hook = atomicWriteHook
        try await writer.write { db in
            try Self.persist(session, in: db)
            try hook?()
            for operation in operations {
                try OutboxOperationRecord(operation: operation).insert(db)
            }
        }
    }

    public func enqueue(_ operation: SyncOperation) async throws {
        try await writer.write { db in
            try OutboxOperationRecord(operation: operation).insert(db)
        }
    }

    public func update(_ operation: SyncOperation) async throws {
        try await writer.write { db in
            try OutboxOperationRecord(operation: operation).save(db)
        }
    }

    /// Pending scan in global enqueue order (rowid): pending plus ambiguous in-flight —
    /// after a crash, unacknowledged sends are replayable (idempotency keys make the
    /// retry harmless). Acknowledged and rejected rows are excluded but never deleted.
    public func pendingOperations() async throws -> [SyncOperation] {
        try await writer.read { db in
            let replayable = [SyncOperation.Status.pending, .inFlight].map(\.rawValue)
            return try OutboxOperationRecord
                .filter(replayable.contains(Column("status")))
                .order(sql: "rowid")
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    public func operations(inAggregate aggregateID: UUID) async throws -> [SyncOperation] {
        let key = aggregateID.uuidString
        return try await writer.read { db in
            try OutboxOperationRecord
                .filter(Column("aggregate_id") == key)
                .order(Column("sequence"))
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    public func nextSequence(forAggregate aggregateID: UUID) async throws -> Int {
        let key = aggregateID.uuidString
        return try await writer.read { db in
            let max = try Int.fetchOne(
                db,
                sql: "SELECT MAX(sequence) FROM outbox_operation WHERE aggregate_id = ?",
                arguments: [key]
            )
            return (max ?? -1) + 1
        }
    }
}

// MARK: - AuditEventStore (ADR-0006)

extension GRDBStore: AuditEventStore {
    public func append(_ event: AuditEvent) async throws {
        try await writer.write { db in
            try AuditEventRecord(event: event).insert(db)
        }
    }

    public func latestHash() async throws -> String {
        try await writer.read { db in
            guard let last = try AuditEventRecord.order(sql: "rowid DESC").fetchOne(db) else {
                return "0"
            }
            return auditChainHash(of: try last.toDomain())
        }
    }

    public func allEvents() async throws -> [AuditEvent] {
        try await writer.read { db in
            try AuditEventRecord.order(sql: "rowid").fetchAll(db).map { try $0.toDomain() }
        }
    }
}
