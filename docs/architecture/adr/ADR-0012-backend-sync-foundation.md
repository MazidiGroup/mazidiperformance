# ADR-0012 — Provider-neutral backend synchronisation foundation

**Status:** Accepted · 2026-07-24

## Context

Every mutation today is a durable local operation queued in `outbox_operation` and replayed
by `SyncEngine` against a `SyncTransport` whose only implementation is the DEBUG
`FixtureSyncTransport` (acknowledge-when-online / retry-when-offline). No backend exists
(R-01/R-02): the networking layer is contract-only (`MazidiNetworking/Contracts.swift`,
DL-11), Coach→Client "delivery" is a DEBUG relay copying rows between account databases
(`DevelopmentAssignmentRelay`), and there is no pull path, no server identity/versioning, no
Coach–Client relationship entity, and no delivery/receipt distinction.

This ADR defines the **provider-neutral** foundation for real synchronisation: push, pull,
identity separation, conflict classification, the Coach–Client relationship, assignment
delivery/receipt states, revocation integration, retry policy, the `v3` migration, and the
fake-transport/test strategy. It **chooses no provider** (that is a separate future ADR) and
fabricates no live service. It is consistent with ADR-0003 (durable outbox, idempotency
keys, per-aggregate ordering, classified conflicts — never blanket last-write-wins), ADR-0006
(first-class audit), ADR-0008 (auth/session/account boundaries, session generations,
credentials-in-Keychain-only, honest offline, revocation-contract-only), ADR-0009 (immutable
versions, frozen assignment snapshots, DEBUG relay, "Queued — delivery confirms with
backend"), ADR-0010/0011 (config injected via `.xcconfig`, no hard-coded hosts), and
ARCHITECTURE §5 (conflict-resolution table).

**Phase 1 is this ADR only.** No contracts, migration, or engine code is written yet.

## Architecture audit (grounded findings)

1. **Outbox operation kinds / aggregate / idempotency / sequence.**
   `SyncOperation.Kind` (`MazidiSync/SyncOperation.swift:9-22`):
   `workoutSessionStarted, setRecorded, exerciseSwapped, workoutSessionCompleted,
   workoutSessionAbandoned, auditEventAppended, templateDraftSaved, templatePublished,
   assignmentCreated, assignmentStatusChanged`. `aggregateID: UUID` = session/template/
   assignment id; `sequence: Int` monotonic per aggregate (`nextSequence`,
   `MazidiPersistence/Repositories.swift:41`); `idempotencyKey: UUID`
   (`SyncOperation.swift:41`, preserved across retries — `markRetryable`, line 110);
   `status ∈ pending/inFlight/acknowledged/rejected` (lines 24-33). Outcome classes
   `acknowledged/retryable/terminallyRejected/authExpired` (line 134). **Gap:** the op
   `payload` is opaque `Data`; there is no entity-type, payload-schema-version,
   expected-server-version, backoff-schedule, or correlation column, and no account context
   on the row (account is implicit in the DB it lives in).

2. **Networking + auth-provider contracts.** `MazidiNetworking/Contracts.swift`:
   `AuthenticationEndpoint` (signIn/refresh/signOutEverywhere), `WorkoutSyncEndpoint`
   (`claimSessionEpoch`, `push(operationPayload:idempotencyKey:)`), `MediaManifestEndpoint`
   — PROPOSED, no pull, no batch, no versions. `AuthProviding`
   (`MazidiAuth/AuthProviding.swift`): signIn/refresh/restore/signOut/`checkRevocation →
   RevocationCheck{active,revoked,unknown}`.

3. **Account-scoped DB lifecycle.** Path = `<base>/accounts/<SHA-256(domainTag|accountID)[..32]>`
   (`AccountDatabasePath.swift`), no raw identity in paths. `GRDBStore.open` quarantines a
   damaged file and returns a typed `recovery` (`GRDBStore.swift:89-153`); migrations are
   forward-only (`GRDBSchema.migrator()`). `SessionCoordinator.generation` bumps on every
   sign-in/out/switch/cancel (`SessionCoordinator.swift:110,143,235`); stale async results are
   discarded by generation checks. `ClientEnvironment` builds one account store + one
   `SyncEngine(store:transport: FixtureSyncTransport)` and closes it on `invalidate()`
   (`ClientEnvironment.swift:122-159`). **Gap:** `CoachEnvironment` wires **no** `SyncEngine`
   — coach outbox ops enqueue but are never drained (verified: no `SyncEngine(`/`syncOnce`
   under `App/Coach/`).

4. **Records needing remote identity/version/sync metadata.** `workout_session`,
   `set_entry`, `exercise_swap`, `outbox_operation`, `audit_event`, `workout_template`,
   `template_version`, `workout_assignment` (`GRDBSchema.swift`). **None** carries a remote
   id, server version, or sync cursor. `workout_assignment.assignee_ref` is an opaque account
   string with no relationship id, no remote id, and only a local execution `status`
   (queued/started/completed/cancelled) — no delivery/receipt state.

5. **Coach–Client relationship identity/lifecycle.** No first-class entity exists.
   `assignee_ref` is an opaque `AccountID` string; `AuditEvent.Kind.relationshipEnded`
   exists (`AuditEvent.swift:27`) but there is no relationship table or lifecycle. The DEBUG
   relay copies assignment rows between fixture account DBs (`DevelopmentAssignmentRelay`).

6. **Push mutation envelopes.** Today: one op → `push(operationPayload: Data,
   idempotencyKey: UUID)` (no batch, no account context, no entity metadata, no expected
   version).

7. **Pull change envelopes.** None exist — there is no pull path at all.

8. **Idempotency rules.** Client-generated UUID key per op, at-most-once server application,
   key preserved across retries; server must return `.acknowledged` on key replay
   (`SyncEngine.swift:7`, `WorkoutSyncEndpoint` doc). No batch/partial-ack semantics defined.

9. **Checkpoint/cursor semantics.** None — no durable pull cursor exists.

10. **Retryable vs permanent errors.** `SyncAttemptOutcome`: `retryable` (network/5xx),
    `terminallyRejected` (validation/authz → parked `rejected`), `authExpired` (pause queue).
    `SyncEngine.syncOnce` stops an aggregate on first retryable/rejected to preserve ordering
    (`SyncEngine.swift:56-92`). **Gap:** no backoff schedule, no server `retry-after`, no
    dead-letter distinct from `rejected`, no bounded-work cap.

11. **Conflict classes + resolution.** Documented in ARCHITECTURE §5 (append-only facts →
    union by key; single-writer session → one-device epoch, superseded = read-only
    recoverable; coach config → version vector + explicit merge; published programmes →
    append-only immutable; status → monotonic lattice). `docs/architecture/SYNC_DESIGN.md`
    referenced there **does not exist yet**. No conflict code exists.

12. **Assignment delivery/receipt.** Local `status` only; coach copy stays "Queued — delivery
    confirms with backend" (ADR-0009); the DEBUG relay stands in for delivery and pulls
    started/completed facts back. No server acceptance / client-opened distinction.

13. **Revocation discovery.** `SessionCoordinator.checkRevocationAfterReconnect` +
    `provider.checkRevocation` → on `.revoked` deletes credentials and applies
    `.revocationDiscovered` → `AuthPhase.revoked` (`SessionCoordinator.swift:216-225`);
    `.unknown` changes nothing. `refresh` throwing `AuthError.revoked` also routes there
    (line 196). The transport has no revocation channel today.

14. **Stale-task protection across sign-out/switch.** `SessionCoordinator.generation` +
    per-call `guard generation == myGeneration` (throughout `SessionCoordinator.swift`); the
    app tears down account services and closes the DB on generation change (ADR-0008 §8),
    so a delayed prior-account response cannot write into the active account.

15. **Migration required.** Yes — `v3` (defined below). The sync foundation genuinely needs
    to persist a pull cursor, local↔remote id/version mapping, the relationship entity,
    assignment delivery state, and retry scheduling — none of which exist. It is additive
    (ALTER ADD + new tables), preserving v1/v2 rows.

16. **Impossible without a real backend.** Real delivery/receipt confirmation;
    relationship-level authorization enforcement (which coach may assign to which client);
    cross-device session supersession (M4 hardcoded `epoch: 1`,
    `ClientWorkoutModel.swift:161-163`); server-side revocation & "sign out everywhere";
    actual pull data and server versions. All ship as contracts + fake, with honest UI.

## Decisions

### 1. Provider-neutral transport contracts (MazidiNetworking, Foundation-only)

A new set of `Sendable`, Codable-where-serialised protocols and value types. **No provider
SDK type** may appear in these contracts or cross into `MazidiDomain`, views, non-sync
persistence records, workout/catalogue services. **No** hard-coded production URL, credential,
tenant id, API key, signed URL, or hostname — the base URL is injected from the active
`.xcconfig` (`SYNC_BASE_URL`, surfaced via Info.plist exactly like `MEDIA_BASE_URL`, ADR-0011),
empty by default so the transport is honestly inert until a backend exists. **No provider is
chosen here.**

- `AuthenticatedRequestContext` — `accountID`, session `generation`, device installation id,
  and an **injected access-token accessor** (fetched from the Keychain at send time via a
  closure/provider); the raw token is **never** stored in the context, a payload, or a log.
- `MutationEnvelope` (§3) and `PushMutationBatch { batchID, requestContext, [MutationEnvelope] }`.
- `PushAck { [MutationResult] }` where `MutationResult ∈ applied(serverVersion) /
  duplicateApplied(serverVersion) / rejected(PermanentReason) / needsRetry(TransportRetry)`
  keyed by `mutationID` (partial-batch acks supported).
- `PullChangesRequest { requestContext, stream, cursorToken?, maxChanges }`.
- `PullChangesResponse { [ChangeEnvelope], nextCursorToken, hasMore, serverSchemaVersion }`.
- `ChangeEnvelope { entityType, remoteID, serverVersion, op(upsert/tombstone), payload?,
  payloadSchemaVersion }`; `RemoteTombstone { entityType, remoteID, serverVersion }`.
- `SyncCursor { token, lastServerVersion }`; `ServerRecordVersion = Int`;
  `IdempotencyKey = UUID`.
- `DeliveryAck { remoteID, serverVersion, deliveryState }`; `RevocationState` = reuse
  `RevocationCheck{active,revoked,unknown}`.
- `RateLimit { retryAfter: TimeInterval }`; typed `TransportError ∈ unreachable / timeout /
  rateLimited(retryAfter) / unauthorized / forbidden / conflict(serverVersion) / revoked /
  serverError(status) / malformedResponse / cancelled`. All calls are `async` and honour
  Swift structured-concurrency **cancellation**.

### 2. Remote identity separation

Distinct, non-interchangeable identities, each with a single meaning:

- **Local UUIDs** — `Identifier<T>` domain ids (client-minted, stable, primary keys).
- **Stable account IDs** — `AccountID` (opaque provider subject; never email/display name;
  hashed for paths/actor ids). Raw email never appears in ids, paths, or payload keys.
- **Remote record IDs** — server-assigned, stored only in `remote_record.remote_id`.
- **Relationship IDs** — local `relationship.id`, mapped to `remote_id`.
- **Mutation IDs** — **deterministic** = the op's `idempotencyKey` (client UUID minted once
  at enqueue, reused verbatim on every retry). A retry never mints a new mutation id → no
  duplicate application.
- **Device installation ID** — device-global, non-secret, minted once and stored beside
  `mazidi.session.metadata` in UserDefaults (**not** a v3 table — avoids per-account
  duplication); namespaces idempotency and identifies the sender.
- **Sync cursors** and **server versions** — see §4/§5.

Isolation invariants (each tested): tokens never enter payloads; Account A can never read or
apply Account B's sync state (account-scoped DBs; drain/apply run only under the active
`ClientEnvironment`/`CoachEnvironment`); a delayed prior-account/prior-session response cannot
mutate the active account because every request carries the session `generation` and every
apply re-checks `generation` **and** that the response's `accountContext` equals the active
`AccountID` (explicit server-identity binding).

### 3. Mutation envelope + idempotency rules

`MutationEnvelope { mutationID (= idempotencyKey), accountContext, entityType, entityID
(local), opType, payloadSchemaVersion, localTimestamp (injected clock), expectedServerVersion?,
idempotencyKey (== mutationID), correlationID (opaque, no sensitive content), payload }`.

Rules: a retry carries the same `mutationID` → server applies at most once and returns
`duplicateApplied` on replay; a batch may be **partially** acked (each result keyed by
`mutationID`); a successful ack removes the op from the outbox **in the same local
transaction** that records its server version; a `needsRetry` op stays queued (backoff, §9);
a `rejected(permanent)` op moves to an explicit **blocked/dead-letter** state
(user-visible, never dropped); an ack for a stale/unknown `mutationID` is a safe no-op; the
envelope is `payloadSchemaVersion`-tagged so payloads upgrade forward without silent
discard. Nothing is ever silently discarded.

### 4. Pull / cursor semantics (poll-based; no socket this milestone)

The account-scoped `sync_cursor` is the durable pull checkpoint. A pull batch **applies all
changes and advances the cursor in one transaction**; the cursor's `lastServerVersion` is
monotonic and **can never regress** (out-of-order or duplicate changes with
`serverVersion ≤ lastServerVersion` are ignored — duplicates are harmless upserts by
`(entityType, remoteID)`). An unknown future `serverSchemaVersion`/`payloadSchemaVersion` is
**quarantined and surfaced honestly** (not applied). Tombstones are explicit
(`op = tombstone` / `RemoteTombstone`) — never inferred from absence. A pull **failure
preserves the prior cursor** (no partial advance). An account switch closes the pull context
(generation); a signed-out phase prevents any further application. **No continuous socket /
push delivery** is designed in this milestone — pull is client-initiated.

### 5. Typed conflict model (deterministic per entity; never last-write-wins)

`SyncConflict ∈ remoteVersionAdvanced / localRecordDeletedRemotely /
assignmentCancelledRemotely / immutableVersionMismatch / relationshipEnded / permissionRevoked
/ unsupportedSchema / invalidServerState / duplicateCompletion / localMutationPermanentlyRejected`.
Per-entity handling, consistent with ARCHITECTURE §5:

- **Append-only facts** (recorded sets, audit events): union by idempotency key; duplicates
  dropped; never conflict.
- **Single-writer session** (client's active workout): one-device epoch; a superseded offline
  session becomes **read-only recoverable**, surfaced, never silently discarded; a remote
  cancellation can never erase a **completed** session, and `duplicateCompletion` is
  idempotent (a completed assignment cannot complete again — ADR-0009).
- **Coach-authored drafts**: version vector; concurrent edit → explicit merge prompt; later
  save becomes a new revision; nothing overwritten silently.
- **Published versions**: immutable; `immutableVersionMismatch` never rewrites a published
  version or completed history (a template update never mutates a frozen assignment snapshot —
  historical truth).
- **Relationship / permission** (`relationshipEnded`, `permissionRevoked`): blocks **new**
  access; historical records follow the documented retention rule (sharing off stops future
  sharing, never deletes past content — CLAUDE.md), not deletion.
- **`unsupportedSchema` / `invalidServerState`**: surfaced honestly and blocked; never
  coerced. No generic last-write-wins anywhere.

### 6. Coach–Client relationship model

First-class `relationship` (see v3 schema): `{ id, remoteID?, coachAccountID, clientAccountID,
status, createdAt, acceptedAt?, endedAt?, serverVersion, localSyncState }`. Lifecycle
`status ∈ invited / active / declined / ended / revoked / pendingLocalUpload /
pendingRemoteConfirmation`. No invitation email/discovery flow is fabricated (that needs the
backend + its own product/ADR work); DEBUG/UI-test-only deterministic relationships mirror the
existing dev-fixture pattern (`dev-coach-001` ↔ `dev-client-00x`). Assignment authorization
will hinge on an `active` relationship once the backend enforces it; locally it is advisory.

### 7. Assignment delivery states (distinct from execution status)

A `delivery_state` orthogonal to the execution `status` (queued/started/completed/cancelled):
`createdLocally → queuedForUpload → acceptedByServer → availableToClient → openedByClient`,
plus `permanentlyRejected`. **"Queued" ≠ "Delivered"; server acceptance ≠ client opened;**
receipt/opening is a **separate** event (`opened_at`). The DEBUG relay never leaks into
Release and never upgrades the coach-side "Queued" label (ADR-0009). Existing execution +
completion linkage is untouched; a completed session's history stays durable even if delivery
metadata later changes.

### 8. Revocation discovery integration

The transport surfaces explicit revocation (`TransportError.revoked` / `unauthorized` +
`RevocationState.revoked`) into `SessionCoordinator` via the existing
`.revocationDiscovered` path; `RevocationState.unknown` **never** means revoked. Confirmed
revocation closes authenticated services and account-DB access (generation bump + `invalidate`),
deletes credentials, and follows the existing sign-out boundary. The drain checks phase +
generation **before every send**, so **no pending work is uploaded after revocation**; delayed
prior-session responses are ignored (generation). Offline can never claim current revocation
knowledge (honest UI). No "sign out everywhere" is claimed without real server support
(`signOutEverywhere` stays contract-only with honest-limitation copy).

### 9. Retry / backoff policy

Immediate first attempt; exponential backoff (base delay × 2^attempt, ±jitter from **injected
randomness**) capped at a max delay; honour server `retry-after` (from `rateLimited`); pause
the queue on `unreachable`/network-unavailable; require an auth refresh before retrying an
`authExpired`/`unauthorized` op; classify validation/authz as **permanent** → blocked/
dead-letter with **manual retry**; **cancel** all in-flight work on sign-out/switch
(generation). Scheduling uses `outbox_operation.next_attempt_at` + the **injected clock** — no
arbitrary `sleep`, no uncontrolled infinite loop; each drain does **bounded** work (max batch
size, max ops per `syncOnce`).

### 10. Fake transport + audit events

A deterministic in-process `FakeSyncBackend` (DEBUG/test-only, extending today's
`FixtureSyncTransport` to push **and** pull) drives all states reproducibly; it is **never
selectable as a production path in Release** (compiled out; the Release provider slot fails
typed/honest) and there are **no live-network tests**. New `AuditEvent.Kind` (additive):
`syncBatchAttempted, syncBatchAcknowledged, mutationPermanentlyRejected, pullChangesApplied,
relationshipActivated` (`relationshipEnded`, `assignmentDelivered` — `assignmentDelivered`
new; `relationshipEnded` exists), `revocationDiscovered`. Privacy exclusions (ADR-0006 §8):
audit subjects carry **ids only** — never tokens, full request/response bodies, full coach
notes, private messages, credentials, or signed URLs; user-facing errors never expose server
internals.

## Migration `v3` (exact schema — forward-only, additive, preserves v1/v2)

Registered after `v2-coach-programming`; applied by `GRDBSchema.migrator()`; documented in
MIGRATIONS.md **when the migration lands** (not in this Phase-1 ADR commit). Every existing
v1/v2 row remains readable (new columns are nullable or defaulted; no rewrites; no cross-account
reassignment; account-scoped corruption recovery unchanged).

**A. `ALTER outbox_operation ADD`** (retry/routing metadata — none duplicates the domain
payload):
| Column | Type | Why genuinely required |
|---|---|---|
| `entity_type` | TEXT (nullable) | Typed dead-letter/routing queries without parsing `kind`; old rows map from `kind` on read. |
| `payload_schema_version` | INTEGER NOT NULL DEFAULT 1 | Forward-compatible payload upgrades (§3). |
| `expected_server_version` | INTEGER (nullable) | Optimistic concurrency for mutations targeting an existing server record (§5). |
| `next_attempt_at` | DATETIME (nullable) | Backoff scheduling via injected clock (§9); indexed due-scan. |
| `correlation_id` | TEXT (nullable) | Trace correlation; no sensitive content. |

Index `idx_outbox_due` on `(status, next_attempt_at)`. (The permanent/dead-letter state reuses
the existing `rejected` status + `last_error`; no status column is added.)

**B. `sync_cursor`** (durable pull checkpoint, account-scoped):
`stream TEXT PRIMARY KEY`, `cursor_token TEXT` (nullable), `last_server_version INTEGER NOT
NULL DEFAULT 0`, `schema_version INTEGER NOT NULL DEFAULT 1`, `updated_at DATETIME NOT NULL`.
*Why:* the pull cursor must be durable and monotonic; apply+advance in one transaction (§4).

**C. `remote_record`** (local↔remote id + version + tombstone; **no domain payload**):
`entity_type TEXT NOT NULL`, `local_id TEXT NOT NULL`, `remote_id TEXT` (nullable),
`server_version INTEGER NOT NULL DEFAULT 0`, `tombstoned INTEGER NOT NULL DEFAULT 0`,
`last_synced_at DATETIME`, PRIMARY KEY `(entity_type, local_id)`, UNIQUE
`(entity_type, remote_id)` (partial, where `remote_id` not null). *Why:* optimistic
concurrency (compare `server_version`), explicit remote-deletion detection (`tombstoned`), and
id mapping — storing only ids/version/flag, never the row's content.

**D. `relationship`** (Coach–Client, §6):
`id TEXT PRIMARY KEY`, `remote_id TEXT` (nullable), `coach_account_id TEXT NOT NULL`,
`client_account_id TEXT NOT NULL`, `status TEXT NOT NULL`, `created_at DATETIME NOT NULL`,
`accepted_at DATETIME`, `ended_at DATETIME`, `server_version INTEGER NOT NULL DEFAULT 0`,
`local_sync_state TEXT NOT NULL`. Indexes on `(status)`, `(coach_account_id)`,
`(client_account_id)`. *Why:* the relationship that assignment authorization/delivery hinges
on has no home today (finding #5). Account ids are opaque; never email.

**E. `ALTER workout_assignment ADD`** (delivery/receipt + remote binding, orthogonal to the
execution `status`):
| Column | Type | Why genuinely required |
|---|---|---|
| `remote_id` | TEXT (nullable) | Server binding for the assignment record. |
| `server_version` | INTEGER NOT NULL DEFAULT 0 | Optimistic concurrency / cancellation ordering. |
| `relationship_id` | TEXT (nullable) | Links to `relationship.id` for authorization. |
| `delivery_state` | TEXT NOT NULL DEFAULT 'createdLocally' | Delivery lifecycle distinct from execution status (§7). |
| `delivered_at` | DATETIME (nullable) | Server-acceptance / availability timestamp. |
| `opened_at` | DATETIME (nullable) | Client receipt event (≠ delivered). |

Indexes on `(delivery_state)`, `(relationship_id)`. None duplicates `content_json` (the frozen
snapshot).

The device installation id is **not** a v3 table (device-global UserDefaults, §2).

## Consequences

- The outbox stays the durable record of intent (ADR-0003); `v3` adds only the metadata a real
  push/pull loop needs, indexed for retry/cursor/relationship/delivery queries.
- Coach outbox draining (finding #3 gap) can be wired on the same `SyncEngine`/transport once
  the push contract exists — the coach environment gains a drain symmetric to the client's.
- Honesty holds end-to-end: no provider chosen, no host/credential in the repo, `SYNC_BASE_URL`
  empty → transport inert; the fake backend is the only implementation and is Release-excluded;
  "Queued ≠ Delivered ≠ Opened"; revocation `.unknown` ≠ revoked; no "sign out everywhere".
- Migration `v3` is additive and reversible-by-omission (old rows read unchanged); v1/v2
  invariants (immutable versions, frozen snapshots, per-aggregate ordering, account isolation)
  are preserved.

## What remains impossible without a real backend (recorded, not fabricated)

Real delivery/receipt confirmation; server-enforced relationship authorization (which coach
may assign to which client); cross-device supersession (M4 real epoch); server-side revocation
and "sign out everywhere"; actual pulled data and authoritative server versions. All ship as
provider-neutral contracts + a deterministic fake, with honest UI, until the provider ADR and
backend exist (R-01/R-02).

## Non-goals (this milestone)

Choosing a provider; real HTTP/socket clients; continuous push delivery; the invitation/
discovery UX; multi-device epoch enforcement; SQLCipher (DL-07); analytics changes.
