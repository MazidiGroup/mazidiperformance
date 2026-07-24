import Foundation
import GRDB

/// Versioned, forward-only schema (ADR-0002/0007). Every migration registered here is
/// documented in docs/architecture/MIGRATIONS.md and is never edited once shipped.
public enum GRDBSchema {
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // v1 — initial workout persistence: sessions + set entries + swaps, the ADR-0003
        // outbox, and the ADR-0006 audit log. Table rationale in MIGRATIONS.md.
        migrator.registerMigration("v1-workout-persistence") { db in
            try db.create(table: "workout_session") { t in
                t.column("id", .text).primaryKey()
                t.column("epoch", .integer).notNull()
                t.column("phase", .text).notNull()
                t.column("started_at", .datetime)
                t.column("completed_at", .datetime)
                t.column("current_exercise_id", .text)
                t.column("rest_json", .blob)
                t.column("workout_json", .blob).notNull()
            }

            try db.create(table: "set_entry") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text).notNull().indexed()
                    .references("workout_session", onDelete: .cascade)
                t.column("exercise_id", .text).notNull()
                t.column("performed_slug", .text).notNull()
                t.column("set_index", .integer).notNull()
                t.column("value_json", .blob).notNull()
                t.column("rpe", .double)
                t.column("recorded_at", .datetime).notNull()
                t.column("idempotency_key", .text).notNull().unique()
                // Domain duplicate-prevention rule, enforced at the database too.
                t.uniqueKey(["session_id", "exercise_id", "set_index"])
            }

            try db.create(table: "exercise_swap") { t in
                t.column("session_id", .text).notNull()
                    .references("workout_session", onDelete: .cascade)
                t.column("exercise_id", .text).notNull()
                t.column("performed_slug", .text).notNull()
                t.primaryKey(["session_id", "exercise_id"])
            }

            try db.create(table: "outbox_operation") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull()
                t.column("aggregate_id", .text).notNull()
                t.column("sequence", .integer).notNull()
                t.column("idempotency_key", .text).notNull().unique()
                t.column("payload", .blob).notNull()
                t.column("enqueued_at", .datetime).notNull()
                t.column("status", .text).notNull()
                t.column("attempt_count", .integer).notNull()
                t.column("last_error", .text)
                // Per-aggregate ordering integrity (ADR-0003).
                t.uniqueKey(["aggregate_id", "sequence"])
            }
            try db.create(index: "idx_outbox_aggregate_sequence",
                          on: "outbox_operation", columns: ["aggregate_id", "sequence"])
            try db.create(index: "idx_outbox_status",
                          on: "outbox_operation", columns: ["status"])

            try db.create(table: "audit_event") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull()
                t.column("actor_id", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("occurred_at", .datetime).notNull()
                t.column("previous_hash", .text).notNull()
                t.column("payload_json", .blob).notNull()
            }
        }

        return migrator
    }
}
