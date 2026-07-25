# Backend synchronisation design

The concrete algorithm behind ARCHITECTURE §5 and ADR-0012. No backend exists yet
(R-01/R-02): every contract here is provider-neutral, the only transport implementation is
the DEBUG-only `FakeSyncBackend`, and `SYNC_BASE_URL` is empty so the real transport is inert.
Nothing below fabricates live server behaviour.

## Layers

- **Contracts** (`MazidiNetworking/SyncContracts.swift`): distinct identity types, the
  mutation envelope, push batch/ack, pull request/response, cursor, tombstones, delivery ack,
  revocation state, typed `TransportError`, and the `SyncBackendTransport` protocol. No
  provider SDK type; the access token is fetched lazily via an injected accessor on the
  non-Codable `AuthenticatedRequestContext` and never enters a serialised body.
- **Persistence** (`BackendSyncStore`, GRDB): transactional push-ack application and
  pull-materialisation+cursor advance; `v3` schema (`outbox_operation` retry columns,
  `sync_cursor`, `remote_record`, `relationship`, `workout_assignment` delivery columns).
- **Engines** (`MazidiSync`): `BackendPushEngine`, `BackendPullEngine`, `ConflictResolver`,
  `FakeSyncBackend`.
- **App**: `BackendSyncDriver` (DEBUG) wires both shells' environments onto the engines,
  generation-guarded and torn down on `invalidate()`.

## Identity separation (ADR-0012 §2)

Local UUIDs (`Identifier<T>`) ≠ stable `AccountID` (opaque provider subject; hashed for
paths/actor ids, never email) ≠ server `RemoteRecordID` ≠ `RelationshipID` ≠ `MutationID`
(deterministic = the op's idempotency key) ≠ device installation id (device-global
UserDefaults) ≠ `SyncCursorToken` ≠ `ServerRecordVersion`. Every apply re-checks the session
`generation` AND that the response's `accountContext` equals the active account, so a delayed
prior-account/prior-session response can never mutate the active account.

## Push (mutation upload)

1. Fetch pending outbox operations; select the earliest **due** operation **per aggregate**
   (`next_attempt_at` ≤ now), bounded by `maxBatchSize` — this preserves strict per-aggregate
   ordering across drains (op N+1 is never sent before op N is acknowledged).
2. Build a `MutationEnvelope` per op (`mutationID` = idempotency key; local timestamp from the
   injected clock; `payloadSchemaVersion`; opaque payload snapshot — no token/credential).
3. Mark in-flight, upload the batch, and apply the typed `PushAck` **per mutation**, in one
   transaction (`applyPushResults`):
   - `applied` / `duplicateApplied` → acknowledged, removed from replay, **and the server
     version recorded in `remote_record` in the same transaction**.
   - `rejected(permanent)` → parked `rejected` (dead-letter, user-visible, never dropped).
   - `needsRetry` / missing ack → re-queued with backoff (never assumed applied).
4. A whole-batch transport failure re-queues every attempted op with backoff (honouring a
   rate-limit `retry-after`); a `revoked` result is surfaced for the caller to route to the
   `SessionCoordinator`.

**Idempotency:** a retry reuses the same deterministic `mutationID`, so the server applies it
at most once; a duplicate replay is a no-op. Nothing is ever silently discarded.

## Pull / cursor semantics (ADR-0012 §4)

Client-initiated (no socket). Per drain:
1. Load the account-scoped `sync_cursor`; request changes from its token.
2. Bind the response to the active account + live session (generation guard); a mismatch is
   ignored (`ignoredStale`).
3. Quarantine an unknown future server/payload schema OR an undecodable materialisable payload
   — apply nothing, preserve the cursor.
4. Accept only changes with `serverVersion` strictly greater than the cursor (duplicates /
   out-of-order ignored); decode materialisable payloads (assignment/relationship).
5. **In one transaction:** materialise decoded domain rows (idempotent upsert), record each
   change's remote id / server version / tombstone, and advance the cursor. The cursor's
   `lastServerVersion` is the running max, so it **never regresses** and never advances past a
   change whose domain effect was not durably applied. A transport failure preserves the prior
   cursor.

## Conflict resolution (ADR-0012 §5, `ConflictResolver`)

Deterministic per class — **never last-write-wins** (version-vector, not timestamps):

| Conflict | Resolution |
|---|---|
| `remoteVersionAdvanced(local, remote)` | apply remote iff `remote > local`; else idempotent no-op |
| `localRecordDeletedRemotely(historicalTruth)` | keep local if completed/immutable history; else apply tombstone |
| `assignmentCancelledRemotely(localCompleted)` | keep local if the session completed (never erase history); else apply cancel |
| `immutableVersionMismatch` | keep local — published versions immutable, completed history never rewritten |
| `relationshipEnded` / `permissionRevoked` | block new access, retain existing history |
| `unsupportedSchema` / `invalidServerState` | surface honestly, apply nothing |
| `duplicateCompletion` | idempotent no-op |
| `localMutationPermanentlyRejected` | park as rejected (never dropped) |

## Retry / backoff (ADR-0012 §9)

Immediate first attempt; exponential backoff `base·2^(attempt-1)` capped at `maxBackoff`, with
jitter from injected randomness; a server `retry-after` overrides it exactly. Scheduling uses
`outbox_operation.next_attempt_at` against the **injected clock** — no `sleep`, no uncontrolled
loop; each drain does bounded work. Permanent failures are dead-lettered with manual retry.
Connectivity restore clears the schedule (retry-now).

## Delivery / receipt state machine (ADR-0012 §7)

`createdLocally → queuedForUpload → acceptedByServer → availableToClient → openedByClient`
(plus `permanentlyRejected` from queued/accepted). **Orthogonal** to the execution
`status` (queued/started/completed/cancelled). "Queued" ≠ "Delivered" ≠ "Opened":
`delivered_at` is set only on `acceptedByServer`, `opened_at` only on `openedByClient` (a
distinct client receipt event). The `assignmentDelivered` audit fires **only** on genuine
`acceptedByServer` (never the DEBUG relay, never at `queuedForUpload`), in the same
transaction. A completed session's history stays durable across any later delivery-metadata
change.

## Relationship lifecycle (ADR-0012 §6)

`invited / active / declined / ended / revoked / pendingLocalUpload / pendingRemoteConfirmation`
with guarded transitions. Coach/client are opaque account refs (never email). Relationship
authorization is **advisory locally** — server-enforced authz (which coach may relate to which
client) is deferred to the backend. Relationship writes commit atomically with a
`relationshipUpdated` outbox op.

## Revocation / stale-task (ADR-0012 §8)

The transport surfaces a confirmed `revoked` into `SessionCoordinator.revocationReported(
forGeneration:)` — **only** on confirmed revocation, never `.unknown` (offline can never claim
current revocation knowledge). Generation-guarded: a delayed prior-session report is ignored.
A confirmed revocation bumps the generation (invalidating outstanding work), deletes
credentials, moves to `.revoked` (account-DB access blocked → the app closes the database), and
the drain's `isActive` guard stops any further upload. No "sign out everywhere" is claimed.

## Audit (ADR-0006 privacy exclusions)

Sync events (`syncBatchAttempted/Acknowledged`, `mutationPermanentlyRejected`,
`pullChangesApplied`, `assignmentDelivered`, `relationshipActivated/Ended`,
`revocationDiscovered`) carry **ids/counts only** — never tokens, full request/response bodies,
full notes, private messages, credentials, or signed URLs. User-facing errors expose no server
internals (`TransportError` carries a status code at most).

## What remains impossible without a real backend

Real delivery/receipt confirmation, server-enforced relationship authorization, cross-device
session supersession (M4 real epoch), server-side revocation & "sign out everywhere", and
actual pulled data/authoritative server versions. All ship as contracts + a deterministic fake
with honest UI until the provider ADR and backend land.
