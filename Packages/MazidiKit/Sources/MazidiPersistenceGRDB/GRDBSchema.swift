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

        // v2 — coach programming & assignments (ADR-0009). Content columns are JSON
        // snapshots of coach-authored config (ADR-0007 §3 blob rule). template_version
        // rows are immutable once written. No FK from assignment to template/version:
        // client databases receive assignment rows standalone (self-contained snapshot)
        // via the delivery path; integrity is by construction (immutable snapshots).
        migrator.registerMigration("v2-coach-programming") { db in
            try db.create(table: "workout_template") { t in
                t.column("id", .text).primaryKey()
                t.column("draft_json", .blob).notNull()
                t.column("published_version_count", .integer).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "template_version") { t in
                t.column("id", .text).primaryKey()
                t.column("template_id", .text).notNull().indexed()
                t.column("version_number", .integer).notNull()
                t.column("content_json", .blob).notNull()
                t.column("published_at", .datetime).notNull()
                t.uniqueKey(["template_id", "version_number"])
            }

            try db.create(table: "workout_assignment") { t in
                t.column("id", .text).primaryKey()
                t.column("template_id", .text).notNull()
                t.column("version_id", .text).notNull()
                t.column("version_number", .integer).notNull()
                t.column("content_json", .blob).notNull()
                t.column("assignee_ref", .text).notNull().indexed()
                t.column("assigned_at", .datetime).notNull()
                t.column("status", .text).notNull().indexed()
                t.column("completed_session_id", .text)
                t.column("completed_at", .datetime)
            }

            try db.alter(table: "workout_session") { t in
                t.add(column: "assignment_id", .text)
            }
        }

        // v3 — backend synchronisation metadata (ADR-0012). Additive and non-destructive:
        // every v1/v2 row is preserved and reads unchanged; new columns are nullable or
        // defaulted; no existing row is rewritten or reassigned across accounts. Sync
        // metadata is kept SEPARATE from the domain payload snapshots (no duplication).
        migrator.registerMigration("v3-backend-sync-metadata") { db in
            // Retry/routing metadata on the durable outbox (does not duplicate the payload).
            try db.alter(table: "outbox_operation") { t in
                t.add(column: "entity_type", .text)                                   // typed dead-letter/routing
                t.add(column: "payload_schema_version", .integer).notNull().defaults(to: 1)
                t.add(column: "expected_server_version", .integer)                    // optimistic concurrency
                t.add(column: "next_attempt_at", .datetime)                           // backoff scheduling
                t.add(column: "correlation_id", .text)                                // trace only
            }
            // Backoff due-scan (pending ops whose next_attempt_at has arrived).
            try db.create(index: "idx_outbox_due", on: "outbox_operation",
                          columns: ["status", "next_attempt_at"])

            // Durable, account-scoped pull checkpoint. Monotonic last_server_version;
            // advanced only in the same transaction that applies its changes (CG5).
            try db.create(table: "sync_cursor") { t in
                t.column("stream", .text).primaryKey()
                t.column("cursor_token", .text)
                t.column("last_server_version", .integer).notNull().defaults(to: 0)
                t.column("schema_version", .integer).notNull().defaults(to: 1)
                t.column("updated_at", .datetime).notNull()
            }

            // Local↔remote id + server version + tombstone. Stores ONLY ids/version/flag —
            // never a copy of the domain row's content.
            try db.create(table: "remote_record") { t in
                t.column("entity_type", .text).notNull()
                t.column("local_id", .text).notNull()
                t.column("remote_id", .text)
                t.column("server_version", .integer).notNull().defaults(to: 0)
                t.column("tombstoned", .integer).notNull().defaults(to: 0)
                t.column("last_synced_at", .datetime)
                t.primaryKey(["entity_type", "local_id"])
            }
            // A remote id maps to at most one local record (only where assigned).
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_remote_record_remote_id
                ON remote_record (entity_type, remote_id) WHERE remote_id IS NOT NULL
                """)

            // First-class Coach–Client relationship (ADR-0012 §6). Account ids are opaque
            // AccountID strings — never email.
            try db.create(table: "relationship") { t in
                t.column("id", .text).primaryKey()
                t.column("remote_id", .text)
                t.column("coach_account_id", .text).notNull()
                t.column("client_account_id", .text).notNull()
                t.column("status", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("accepted_at", .datetime)
                t.column("ended_at", .datetime)
                t.column("server_version", .integer).notNull().defaults(to: 0)
                t.column("local_sync_state", .text).notNull()
            }
            try db.create(index: "idx_relationship_status", on: "relationship", columns: ["status"])
            try db.create(index: "idx_relationship_coach", on: "relationship", columns: ["coach_account_id"])
            try db.create(index: "idx_relationship_client", on: "relationship", columns: ["client_account_id"])

            // Delivery/receipt lifecycle + remote binding on assignments — ORTHOGONAL to the
            // execution `status` column, and not a copy of content_json (the frozen snapshot).
            try db.alter(table: "workout_assignment") { t in
                t.add(column: "remote_id", .text)
                t.add(column: "server_version", .integer).notNull().defaults(to: 0)
                t.add(column: "relationship_id", .text)
                t.add(column: "delivery_state", .text).notNull().defaults(to: "createdLocally")
                t.add(column: "delivered_at", .datetime)
                t.add(column: "opened_at", .datetime)
            }
            try db.create(index: "idx_assignment_delivery_state", on: "workout_assignment", columns: ["delivery_state"])
            try db.create(index: "idx_assignment_relationship", on: "workout_assignment", columns: ["relationship_id"])
        }

        // v4 — health-data consent records (ADR-0013 "Consent and data-protection model").
        // PURELY ADDITIVE: one new table, no change to any v1/v2/v3 table, column or index, so
        // every existing row is preserved and reads unchanged. Account-scoped like every other
        // table (the migration runs per account database, in place) and the corruption/
        // quarantine policy is untouched.
        //
        // ONE ROW PER (PURPOSE, GRANT) — no purposes child table. A child table would make a
        // parent row that carries several purposes under one granted_at and one withdrawal
        // switch representable, which is exactly the bundled consent Art. 9(2)(a) rejects.
        // Keeping `purpose` as a typed column on the record makes unbundling structural: each
        // purpose has its own grant timestamp, its own notice version and its own withdrawal.
        //
        // APPEND-ONLY EVIDENCE: rows are INSERTed on grant and never deleted. Withdrawal only
        // stamps `withdrawn_at`; `purpose`, `granted_at` and `notice_version` are never
        // rewritten, so the record of past lawful processing survives (Art. 7(1)). A re-grant
        // inserts a NEW row rather than clearing an old one.
        migrator.registerMigration("v4-health-data-consent") { db in
            try db.create(table: "health_data_consent") { t in
                // Client-generated UUID — also the sync aggregate id, so a grant and its later
                // withdrawal replay in order against one record.
                t.column("id", .text).primaryKey()
                // Exactly one purpose per row (HealthDataConsent.Purpose raw value).
                t.column("purpose", .text).notNull()
                // Which privacy-notice wording the decision was given against. Consent is to a
                // specific text, so the version must be retained with the decision.
                t.column("granted_at", .datetime).notNull()
                t.column("notice_version", .text).notNull()
                // NULL while in force; set once on withdrawal, never cleared.
                t.column("withdrawn_at", .datetime)
            }
            // The gate's hot query — "is a record in force for purpose X?" — reads exactly
            // this partial index and nothing else.
            try db.execute(sql: """
                CREATE INDEX idx_health_consent_in_force
                ON health_data_consent (purpose) WHERE withdrawn_at IS NULL
                """)
            // History reads (the settings surface and the evidential export) scan a purpose in
            // decision order.
            try db.create(index: "idx_health_consent_purpose_granted",
                          on: "health_data_consent", columns: ["purpose", "granted_at"])
        }

        return migrator
    }
}
