# Database schema & migrations

Registered in code in `Packages/MazidiKit/Sources/MazidiPersistenceGRDB/GRDBSchema.swift`
(`GRDBSchema.migrator()`), applied with GRDB's `DatabaseMigrator`. Per ADR-0002/0007:

- **Forward-only, numbered, versioned.** Every migration is appended here with its intent.
  Shipped migrations are never edited or reordered.
- **No destructive reset as a migration strategy.** A migration transforms data in place.
- **Migration failure:** `migrate` errors propagate to the store factory, which treats the
  file like an unopenable database (below). The original file is preserved.
- **Corruption / unopenable database:** the factory moves the file (plus `-wal`/`-shm`
  side files) to `<name>.corrupt-<UTC timestamp>` next to the original — preserved for
  diagnostics and future recovery, never deleted or overwritten — logs only the file path
  and failure category (never workout contents), and starts a fresh database. The outcome
  is a **typed recovery signal** (`GRDBStore.recovery`): `normal(createdNew:)`
  distinguishes a genuine first launch from reopening existing data, and
  `recoveredAfterQuarantine(quarantinedPath:reason:)` (reason: `unopenable` or
  `migrationFailed`) marks a fresh replacement database. The composition root maps this to
  `ClientEnvironment.StoreHealth` and the Today screen surfaces quarantine/fallback states
  — a fresh-after-quarantine database is never presented as a normal empty state.
  **Deferred until account/support/export UI exists:** user-driven retrieval or export of
  a quarantined file, support tooling around it, and any repair attempt (no speculative
  repair engine); tracked as KNOWN_ISSUES L5.
- **Location:** `Application Support/MazidiPerformance/mazidi-client.sqlite` (created with
  intermediate directories). One database per signed-in identity is the target design;
  until authentication exists (R-01) there is a single local database. On iOS the file is
  given `completeUntilFirstUserAuthentication` file protection; SQLCipher encryption is a
  separate pending decision (DL-07).
- **Signed out / dev roles:** the client store opens lazily with the Client shell. Account
  lifecycle behaviour (wipe on sign-out/remote revocation, per-identity files) is pending
  the authentication milestone and is intentionally not fabricated now.
- **Close behaviour:** the store owns its `DatabasePool` for the app's lifetime; GRDB
  checkpoints WAL on deallocation/termination. No explicit close API is exposed yet.
- **Tests** use in-memory `DatabaseQueue`s (or unique temporary files for the reopen,
  corruption and UI relaunch tests) — production files are never touched by tests, and no
  database file is ever committed to git (`*.sqlite*` is git-ignored).

## v1 — initial workout persistence (2026-07-24)

| Table | Why it exists |
|---|---|
| `workout_session` | One row per workout session aggregate: identity (`id`, TEXT UUID PK), `epoch` (one-device rule), `phase` (lifecycle TEXT), `started_at`/`completed_at`, `current_exercise_id` (position restoration, 5b), `rest_json` (BLOB `RestTimer` snapshot for honest rest restoration — timestamps, not remaining-seconds), and `workout_json` (BLOB snapshot of the `AssignedWorkout` as assigned — immutable per-session coach config; see ADR-0007 §3). |
| `set_entry` | Append-only recorded sets, one row each: `id` PK, `session_id` FK → `workout_session` (CASCADE), `exercise_id`, `performed_slug` (survives approved swaps), `set_index`, `value_json` (type-aware value BLOB), `rpe`, `recorded_at`, `idempotency_key` (UNIQUE). **UNIQUE(session_id, exercise_id, set_index)** enforces duplicate prevention at the database level, matching the domain rule. |
| `exercise_swap` | Approved swaps active in a session: PK(`session_id`,`exercise_id`) → `performed_slug`. Restores the performed exercise after relaunch (4b/7h). FK → `workout_session` (CASCADE). |
| `outbox_operation` | The ADR-0003 durable operation queue: `id` PK, `kind`, `aggregate_id`, `sequence`, `idempotency_key` (UNIQUE — retry safety), `payload` BLOB, `enqueued_at`, `status` (pending/inFlight/acknowledged/rejected), `attempt_count`, `last_error`. **UNIQUE(aggregate_id, sequence)** guarantees per-aggregate ordering integrity; index on (`aggregate_id`,`sequence`) serves ordered replay; index on `status` serves the pending scan; implicit `rowid` preserves global enqueue order. Rows are never deleted by sync — acknowledged/rejected rows remain as durable history. |
| `audit_event` | ADR-0006 append-only audit log: `id` PK, `kind`, `actor_id`, `subject`, `occurred_at`, `previous_hash` (chain), `payload_json`. `rowid` gives append order; the chain hash of the latest row reproduces `latestHash()`. |

Indexes: `set_entry(session_id)`, `outbox_operation(aggregate_id, sequence)`,
`outbox_operation(status)`.

Not persisted deliberately: SwiftUI navigation stacks, sheet visibility, sync engine
in-flight UI status (recomputed honestly from `outbox_operation` rows on launch), and
anything derivable from the rows above.

## v2 — coach programming & assignments (2026-07-24, ADR-0009)

| Table | Why it exists |
|---|---|
| `workout_template` | One row per coach draft: `id` PK, `draft_json` (coach-authored content snapshot — ADR-0007 §3 blob rule; no query reaches inside), `published_version_count`, `updated_at`. Coach-owned; lives only in the coach's account database. |
| `template_version` | **Immutable** publication snapshots: `id` PK, `template_id` (indexed), `version_number`, `content_json`, `published_at`. **UNIQUE(template_id, version_number)** — a duplicate publication is rejected, a frozen row is never overwritten (INSERT-only in code). |
| `workout_assignment` | One row per client assignment: version reference (`template_id`, `version_id`, `version_number`) plus a self-contained `content_json` snapshot, `assignee_ref` (opaque account ref, indexed), `assigned_at`, `status` (queued/started/completed/cancelled, indexed), `completed_session_id`, `completed_at`. Self-contained by design: client databases receive assignment rows standalone (no FK to template tables, which exist only coach-side). |
| `workout_session.assignment_id` | New nullable column: links an executing session to its assignment for completion linkage; old rows read back as NULL safely. |

Transactions: draft saves, publications (template + version + ops), assignment saves, and
assignment transitions (session + assignment + ops) each commit atomically with their
outbox operations, extending the ADR-0003 invariant to programming writes.

## v3 — backend synchronisation metadata (2026-07-25, ADR-0012)

**Additive and non-destructive: every existing v1/v2 row is preserved and reads unchanged.**
New columns are nullable or defaulted; no existing row is rewritten, and no row is ever
reassigned across accounts (the migration runs per account-scoped database, in place).
Forward-only migrations are not reversible — this one is safe because it only adds.

| Table / column | Why it exists |
|---|---|
| `outbox_operation` +`entity_type`, +`payload_schema_version` (NOT NULL DEFAULT 1), +`expected_server_version`, +`next_attempt_at`, +`correlation_id` | Sync-transport metadata on the durable outbox — typed dead-letter/routing, forward-compatible payload upgrades, optimistic-concurrency target version, backoff scheduling, and trace correlation. None duplicates the opaque `payload` snapshot. Index `idx_outbox_due(status, next_attempt_at)` serves the backoff due-scan. |
| `sync_cursor` | Durable, account-scoped pull checkpoint: `stream` PK, `cursor_token` (opaque), `last_server_version` (monotonic, never regresses), `schema_version`, `updated_at`. Advanced only in the same transaction that applies its changes (ADR-0012 §4). |
| `remote_record` | Local↔remote identity map: PK(`entity_type`, `local_id`), `remote_id`, `server_version`, `tombstoned`, `last_synced_at`; partial UNIQUE(`entity_type`, `remote_id`) where `remote_id` is not null. Stores only ids/version/flag — never a copy of the domain row. Enables optimistic concurrency and explicit remote-deletion detection. |
| `relationship` | First-class Coach–Client relationship: `id` PK, `remote_id`, `coach_account_id`, `client_account_id` (opaque `AccountID`s, never email), `status`, `created_at`, `accepted_at`, `ended_at`, `server_version`, `local_sync_state`. Indexed on `status`, `coach_account_id`, `client_account_id`. |
| `workout_assignment` +`remote_id`, +`server_version`, +`relationship_id`, +`delivery_state` (NOT NULL DEFAULT 'createdLocally'), +`delivered_at`, +`opened_at` | Delivery/receipt lifecycle **orthogonal** to the execution `status` column ("Queued" ≠ "Delivered" ≠ "Opened", ADR-0012 §7) plus remote binding. Not a copy of `content_json`. Indexed on `delivery_state` and `relationship_id`. |

Old assignment rows read back with `delivery_state = 'createdLocally'`, `server_version = 0`,
and NULL remote/relationship/timestamp columns; the delivery lifecycle is advanced only by the
real transport (never the DEBUG relay, never at `queuedForUpload` — the `assignmentDelivered`
audit fires only on genuine `acceptedByServer`). The engine's push/pull/conflict logic and the
relationship domain model land in later commit groups.
