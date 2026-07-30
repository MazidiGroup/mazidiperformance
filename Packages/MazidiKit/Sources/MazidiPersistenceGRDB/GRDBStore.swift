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

    /// How this store came to exist — the typed recovery signal the composition boundary
    /// must consume so a fresh-after-quarantine database is never presented as a genuine
    /// empty state (MIGRATIONS.md corruption policy).
    public let recovery: RecoveryCondition

    /// Why a previous database file could not be used.
    public enum FailureCategory: String, Sendable, Equatable {
        /// The file could not be opened as a SQLite database at all.
        case unopenable
        /// The file opened but a schema migration failed.
        case migrationFailed
    }

    public enum RecoveryCondition: Sendable, Equatable {
        /// The database opened normally. `createdNew` distinguishes a genuine first
        /// launch (no file existed) from reopening existing data.
        case normal(createdNew: Bool)
        /// The previous database could not be opened or migrated. It was preserved —
        /// never deleted or overwritten — at `quarantinedPath`, and this store is a
        /// fresh replacement. Callers MUST surface this; it is not an empty state.
        case recoveredAfterQuarantine(quarantinedPath: String, reason: FailureCategory)
    }

    private let hookLock = NSLock()
    private var _atomicWriteHook: (@Sendable () throws -> Void)?

    /// Test seam (ADR-0003 crash-safety proof): runs *inside* the `saveAtomically`
    /// transaction, after the session rows are written and before the outbox rows are
    /// inserted. A throwing hook must roll back both halves.
    func setAtomicWriteHook(_ hook: (@Sendable () throws -> Void)?) {
        hookLock.lock(); defer { hookLock.unlock() }
        _atomicWriteHook = hook
    }

    /// Internal (not `private`) so adapter extensions in other files of this target — e.g. the
    /// v4 consent writes — can honour the same crash-safety test seam.
    var atomicWriteHook: (@Sendable () throws -> Void)? {
        hookLock.lock(); defer { hookLock.unlock() }
        return _atomicWriteHook
    }

    init(writer: any DatabaseWriter, recovery: RecoveryCondition = .normal(createdNew: false)) {
        self.writer = writer
        self.recovery = recovery
    }

    // MARK: - Closing (account transitions, ADR-0008)

    /// Close the underlying database connections. Called BEFORE any account transition
    /// (sign-out/switch): after close, every repository call throws, so a stale task
    /// holding this store can no longer read or write the account's data. Closing is
    /// terminal for this instance — reopen by constructing a new store.
    public func close() throws {
        try writer.close()
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
    /// diagnostics and future support/export recovery, never deleted or overwritten —
    /// and a fresh database is created. The outcome is reported as the store's typed
    /// `recovery` condition; a second failure is unrecoverable and thrown.
    ///
    /// Logging deliberately records only the file path and failure category — never
    /// workout contents.
    public static func open(
        directory: URL,
        filename: String = "mazidi-client.sqlite",
        log: AppLog = AppLog(category: "persistence")
    ) throws -> GRDBStore {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        let existedBefore = fm.fileExists(atPath: url.path)

        do {
            let pool = try makePool(at: url)
            return GRDBStore(writer: pool, recovery: .normal(createdNew: !existedBefore))
        } catch let failure as PoolCreationError {
            log.error("Database at \(url.lastPathComponent) failed (\(failure.category.rawValue)); quarantining and starting fresh")
            let quarantinedPath = setAside(url, fileManager: fm, log: log)
            do {
                let pool = try makePool(at: url)
                return GRDBStore(
                    writer: pool,
                    recovery: .recoveredAfterQuarantine(
                        quarantinedPath: quarantinedPath ?? url.path,
                        reason: failure.category
                    )
                )
            } catch {
                throw OpenError.unrecoverable(underlying: error)
            }
        }
    }

    /// In-memory store: tests, previews, and the DEBUG ephemeral app mode.
    public static func inMemory() throws -> GRDBStore {
        let queue = try DatabaseQueue()
        try GRDBSchema.migrator().migrate(queue)
        return GRDBStore(writer: queue, recovery: .normal(createdNew: true))
    }

    /// Wraps pool-creation failures with the category the recovery signal reports.
    private struct PoolCreationError: Error {
        let category: FailureCategory
        let underlying: Error
    }

    private static func makePool(at url: URL) throws -> DatabasePool {
        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: url.path)
        } catch {
            throw PoolCreationError(category: .unopenable, underlying: error)
        }
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
        do {
            try GRDBSchema.migrator().migrate(pool)
        } catch {
            throw PoolCreationError(category: .migrationFailed, underlying: error)
        }
        return pool
    }

    /// Returns the quarantined main-file path (nil if nothing could be preserved).
    private static func setAside(_ url: URL, fileManager fm: FileManager, log: AppLog) -> String? {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var quarantinedMainPath: String?
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: url.path + ".corrupt-\(stamp)" + suffix)
            do {
                try fm.moveItem(at: source, to: destination)
                if suffix.isEmpty { quarantinedMainPath = destination.path }
            } catch {
                log.error("Could not preserve \(source.lastPathComponent): \(error)")
            }
        }
        return quarantinedMainPath
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

// MARK: - ProgrammingRepository (ADR-0009)

extension GRDBStore: ProgrammingRepository {
    public func saveTemplateAtomically(_ template: WorkoutTemplate, enqueueing operations: [SyncOperation]) async throws {
        let hook = atomicWriteHook
        try await writer.write { db in
            try WorkoutTemplateRecord(template: template).save(db)
            try hook?()
            for operation in operations {
                try OutboxOperationRecord(operation: operation).insert(db)
            }
        }
    }

    public func template(id: Identifier<WorkoutTemplate>) async throws -> WorkoutTemplate? {
        let key = id.rawValue.uuidString
        return try await writer.read { db in
            try WorkoutTemplateRecord.fetchOne(db, key: key).map { try $0.toDomain() }
        }
    }

    public func allTemplates() async throws -> [WorkoutTemplate] {
        try await writer.read { db in
            try WorkoutTemplateRecord
                .order(Column("updated_at").desc)
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    /// Publication (ADR-0009): bumped template + immutable version row + outbox
    /// operations, one transaction. Versions are INSERTed, never saved-over — a
    /// duplicate publication of the same (template, versionNumber) violates the UNIQUE
    /// constraint and rolls back rather than mutating an immutable row.
    public func publishAtomically(
        template: WorkoutTemplate,
        version: WorkoutTemplateVersion,
        enqueueing operations: [SyncOperation]
    ) async throws {
        let hook = atomicWriteHook
        try await writer.write { db in
            try WorkoutTemplateRecord(template: template).save(db)
            try TemplateVersionRecord(version: version).insert(db)
            try hook?()
            for operation in operations {
                try OutboxOperationRecord(operation: operation).insert(db)
            }
        }
    }

    public func version(id: Identifier<WorkoutTemplateVersion>) async throws -> WorkoutTemplateVersion? {
        let key = id.rawValue.uuidString
        return try await writer.read { db in
            try TemplateVersionRecord.fetchOne(db, key: key).map { try $0.toDomain() }
        }
    }

    public func versions(templateID: Identifier<WorkoutTemplate>) async throws -> [WorkoutTemplateVersion] {
        let key = templateID.rawValue.uuidString
        return try await writer.read { db in
            try TemplateVersionRecord
                .filter(Column("template_id") == key)
                .order(Column("version_number"))
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    public func saveAssignmentAtomically(_ assignment: WorkoutAssignment, enqueueing operations: [SyncOperation]) async throws {
        let hook = atomicWriteHook
        try await writer.write { db in
            try WorkoutAssignmentRecord(assignment: assignment).save(db)
            try hook?()
            for operation in operations {
                try OutboxOperationRecord(operation: operation).insert(db)
            }
        }
    }

    public func assignment(id: Identifier<WorkoutAssignment>) async throws -> WorkoutAssignment? {
        let key = id.rawValue.uuidString
        return try await writer.read { db in
            try WorkoutAssignmentRecord.fetchOne(db, key: key).map { try $0.toDomain() }
        }
    }

    public func allAssignments() async throws -> [WorkoutAssignment] {
        try await writer.read { db in
            try WorkoutAssignmentRecord
                .order(Column("assigned_at").desc)
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    /// Start/completion linkage (ADR-0009): the executing session, the assignment's
    /// lifecycle transition, and their outbox operations commit together or not at all.
    public func recordAssignmentTransitionAtomically(
        session: WorkoutSession,
        assignment: WorkoutAssignment,
        enqueueing operations: [SyncOperation]
    ) async throws {
        let hook = atomicWriteHook
        try await writer.write { db in
            try Self.persist(session, in: db)
            try WorkoutAssignmentRecord(assignment: assignment).save(db)
            try hook?()
            for operation in operations {
                try OutboxOperationRecord(operation: operation).insert(db)
            }
        }
    }
}
