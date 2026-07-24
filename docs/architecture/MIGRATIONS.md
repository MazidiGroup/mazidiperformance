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
  diagnostics, never silently deleted — logs the event, and starts a fresh database.
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
