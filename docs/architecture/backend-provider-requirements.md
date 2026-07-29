# Backend provider — hard requirements matrix

**Status:** input to ADR-0013 (Proposed). Derived from the contracts and ADRs already merged on
`main`, not from a wish list. Every requirement below cites the code or decision that fixes it.

No provider is chosen in this document. Nothing here is integration work: no SDK, no account, no
host, no key. `SYNC_BASE_URL` and `MEDIA_BASE_URL` stay empty (`Config/Base.xcconfig:17`,
`Config/Base.xcconfig:24`) and the real transport stays inert until the milestone that follows
ADR-0013.

## How to read this

- **MUST** — a candidate that cannot do this is disqualified for that role. The app's shipped
  semantics would have to be weakened to accommodate it, and ADR-0003/0006/0008/0012 forbid that.
- **SHOULD** — strongly preferred; a gap is a costed compensating-control decision, not a veto.
- **LEGAL** — cannot be settled by engineering. Recorded for the human owner and legal review
  (R-05, DL-01).

The single most important framing fact: **this codebase already implements the offline queue,
idempotency, cursors, tombstones and conflict resolution itself.** A provider's own "offline
sync" / "realtime magic" is therefore not a feature — it is a competing implementation of
machinery that is already written and unit-tested (`Packages/MazidiKit/Sources/MazidiSync/`,
`docs/architecture/SYNC_DESIGN.md`). What is needed from a provider is a **correct, boring,
observable server** that honours the contracts below over HTTPS.

---

## A. Authentication, sessions, tokens

| ID | Requirement | MUST/SHOULD | Fixed by |
|---|---|---|---|
| A-1 | Issue an **access token + refresh token + explicit expiry instant**, and exchange a refresh token for a fresh session. | MUST | `AuthProviding.refresh(refreshToken:accountID:)` — `MazidiAuth/AuthProviding.swift:36`; `AuthCredentials.accessTokenExpiresAt` — `MazidiAuth/AuthTypes.swift:69`; `SessionToken` — `MazidiNetworking/Contracts.swift:15-25` |
| A-2 | Expiry must be a value the client can read **before** sending, so proactive refresh works against an injected clock. Provider must not require "try the call and see if it 401s". | MUST | `AuthSession.isNearExpiry(at:window:)` — `MazidiAuth/AuthTypes.swift:58-60`; ADR-0008 §9 |
| A-3 | A **revocation check** endpoint/API whose answer maps onto `active` / `revoked` / **`unknown`**. `.unknown` must be representable and must **never** be inferred as revoked or as verified-active. | MUST | `RevocationCheck` — `MazidiAuth/AuthProviding.swift:66-72` (the doc comment on `:69-71` is the rule); `SessionCoordinator.checkRevocationAfterReconnect` — `MazidiAuth/SessionCoordinator.swift:214-225`; `revocationReported(forGeneration:)` — `:227-239`; SYNC_DESIGN.md "Revocation / stale-task" |
| A-4 | Server-side **revocation must be real and discoverable**: a session revoked on the server surfaces as `revoked` on the next authenticated call or check, so the client can bump the session generation, delete credentials, and close the account database. | MUST | ADR-0012 §8; `SessionCoordinator.swift:227-239`; SECURITY_BOUNDARIES.md "Deferred" |
| A-5 | **Role claims validated server-side.** The session must carry exactly `[.client]` or `[.coach]`. Missing/conflicting → safe error state; the client must never be able to self-assert a role. | MUST | `RoleClaim` — `MazidiAuth/AuthTypes.swift:13-16`; `SessionClaims.routableRole` (`roles.count == 1`) — `:29-32`; ADR-0008 §7; SECURITY_BOUNDARIES.md "Role and routing" |
| A-6 | Role must be enforced **on every server call**, not only used for client-side routing. A token bearing `client` must be structurally unable to perform coach programming writes. | MUST | ADR-0008 §7 + SECURITY_BOUNDARIES.md "Coach programming & assignments"; `PermanentRejection.forbidden` — `MazidiNetworking/SyncContracts.swift:162` |
| A-7 | The provider's account identity ("subject") must be a **stable opaque id, never an email or display name** — it is hashed into database paths and audit actor ids. | MUST | `AccountID` doc — `MazidiAuth/AuthTypes.swift:5-9`; `AccountDatabasePath.component(for:)` — `MazidiAuth/AccountDatabasePath.swift:19-23`; `AccountID.stableActorUUID` — `:36-44` |
| A-8 | Tokens must be usable as **opaque bearer strings the app stores in the Keychain**. Anything requiring an SDK-managed token cache, a keychain-writing SDK, or a token the app cannot hold itself is a fit failure. | MUST | `CredentialStore` — `MazidiAuth/CredentialStore.swift:18-29` (note `:16-17`: "There is NO plaintext fallback implementation"); SECURITY_BOUNDARIES.md "Credential storage" |
| A-9 | Single signed-in account per device is the model; the credential store holds at most one credential set. Provider multi-session features must not be required for correctness. | SHOULD | `CredentialStore.loadCurrent()` doc — `MazidiAuth/CredentialStore.swift:24-26` |
| A-10 | **"Sign out everywhere" must not be claimed without real support.** If the provider cannot revoke all refresh tokens for an account server-side, `signOutEverywhere` stays contract-only with honest-limitation copy — it must not be faked. | MUST | `AuthenticationEndpoint.signOutEverywhere` — `MazidiNetworking/Contracts.swift:12`; ADR-0012 §8; ADR-0008 §10 |
| A-11 | Offline sign-out must remain honestly local-only (`signedOut(pendingRemoteRevocation: true)`) — the provider must let a queued revocation be delivered later without inventing certainty in the meantime. | MUST | ADR-0008 §10; SECURITY_BOUNDARIES.md "Offline session policy"; `AuthProviding.signOut` doc — `MazidiAuth/AuthProviding.swift:43-45` |
| A-12 | Refresh failure must be **distinguishable**: unreachable (→ `offlineAuthenticated`) vs rejected-by-provider (→ `reauthenticationRequired`) vs revoked. A provider that collapses these into one opaque error breaks the state machine. | MUST | `AuthError` — `MazidiAuth/AuthTypes.swift:90-100`; ADR-0008 §9; `SessionCoordinator.swift:193-201` |
| A-13 | Refresh-token rotation is acceptable and preferred, provided the rotated pair is returned in one response (`RestoredSession.rotatedCredentials`). | SHOULD | `RestoredSession` — `MazidiAuth/AuthProviding.swift:53-64` |

---

## B. Sync push (mutation upload)

| ID | Requirement | MUST/SHOULD | Fixed by |
|---|---|---|---|
| B-1 | **At-most-once application per client-generated idempotency key.** The key is a client UUID minted once at enqueue and reused verbatim on every retry; the server must never apply it twice. | MUST | `IdempotencyKey` — `MazidiNetworking/SyncContracts.swift:32-37`; `MutationID.init(_ key:)` — `:41-46`; ADR-0003; ADR-0012 §3; `outbox_operation.idempotency_key` UNIQUE — MIGRATIONS.md v1 |
| B-2 | On **replay of a known key**, return the **canonical stored result** (the server version that was assigned), not a fresh apply and not a bare 200. | MUST | `MutationResult.duplicateApplied(ServerRecordVersion)` — `SyncContracts.swift:177`; `BackendPushEngine.swift:150` treats `applied`/`duplicateApplied` identically; `WorkoutSyncEndpoint.push` doc — `MazidiNetworking/Contracts.swift:27-36` |
| B-3 | **Partial batch acknowledgement, keyed by mutation id.** A batch of N mutations must be able to return N independent results. All-or-nothing batching is a fit failure — it would force the engine to re-send already-applied work or drop unacknowledged work. | MUST | `PushAck.results: [MutationID: MutationResult]` — `SyncContracts.swift:184-187`; ADR-0012 §3; SYNC_DESIGN.md "Push" step 3 |
| B-4 | **Typed permanent-vs-retryable rejection.** The server must distinguish "never retry this" (validation / unauthorized / forbidden / conflict / relationship ended / unsupported) from "try again later". A permanent rejection is dead-lettered and shown to the user; a retryable one stays queued. | MUST | `PermanentRejection` — `SyncContracts.swift:158-166`; `MutationResult.needsRetry(TransportRetry)` — `:179`; `BackendPushEngine.swift:153-158` |
| B-5 | **Server record versions** (monotonic integers) returned on every apply, for optimistic concurrency. The client sends `expectedServerVersion` on updates to an existing server record and must get a typed conflict carrying the current version when it is stale. | MUST | `ServerRecordVersion` — `SyncContracts.swift:61-67`; `MutationEnvelope.expectedServerVersion` — `:110`; `PermanentRejection.conflict(ServerRecordVersion)` — `:163`; `TransportError.conflict(ServerRecordVersion)` — `:303` |
| B-6 | **Rate limiting with an explicit retry-after**, honoured exactly by the client's backoff (it overrides the exponential schedule). | MUST | `RateLimit` — `SyncContracts.swift:288-292`; `TransportError.rateLimited` — `:299`; `TransportRetry.retryAfter` — `:169-172`; `BackendPushEngine.backoffDelay` — `BackendPushEngine.swift:99-100` (server value wins) |
| B-7 | A missing ack for a sent mutation must be **safe** — the client re-queues rather than assuming applied, which is only sound because of B-1. | MUST | `BackendPushEngine.swift:163-164`; ADR-0012 §3 ("an ack for a stale/unknown `mutationID` is a safe no-op") |
| B-8 | The push body must be able to carry `payloadSchemaVersion`, an opaque `payload: Data`, a typed `entityType`, an `accountContext`, a device installation id and an optional `correlationID` — i.e. the server must accept an app-defined envelope, not impose its own row shape. | MUST | `MutationEnvelope` — `SyncContracts.swift:99-141`; `PushMutationBatch` — `:143-156`; `SyncEntityType` — `:70-80` |
| B-9 | The access token must travel in a **header at send time**, never inside a serialised body. | MUST | `AuthenticatedRequestContext` is deliberately not `Codable` — `SyncContracts.swift:309-327`; ADR-0012 §1 |
| B-10 | The transport must be able to perform **no internal retry** — the app's engine owns backoff and bounded work. A client library that silently retries is a fit failure (it defeats the outbox's scheduling and audit). | MUST | `SyncBackendTransport` doc — `SyncContracts.swift:332-334`; ADR-0012 §9 |

---

## C. Sync pull (change download)

| ID | Requirement | MUST/SHOULD | Fixed by |
|---|---|---|---|
| C-1 | An **incremental change feed** with an opaque, server-issued **continuation cursor** the client persists durably and never interprets. | MUST | `SyncCursorToken` — `SyncContracts.swift:55-59`; `PullChangesRequest.cursorToken` — `:232`; `sync_cursor` table — MIGRATIONS.md v3 |
| C-2 | **Monotonic server versions** across the feed, so `lastServerVersion` can be a running max that never regresses and duplicates/out-of-order changes are harmless. | MUST | `SyncCursor.lastServerVersion` — `SyncContracts.swift:260-271`; `BackendPullEngine.swift:87-89`, `:122` |
| C-3 | The client must be able to satisfy **"the cursor advances only after all changes in the batch are durably applied"** — i.e. the feed must be resumable from the *previous* cursor with no data loss after a client-side failure. Re-delivery of already-seen changes must be permitted and harmless. | MUST | ADR-0012 §4; SYNC_DESIGN.md "Pull / cursor semantics" step 5; `BackendPullEngine.swift:127` (single `applyPullChanges(_:advancingCursorTo:)` call) |
| C-4 | **Explicit tombstones.** Deletion is never inferred from absence from a page. | MUST | `ChangeOp.tombstone` — `SyncContracts.swift:191-194`; `RemoteTombstone` — `:216-227`; ADR-0012 §4 |
| C-5 | **Pagination** with an explicit `hasMore` and a client-requested page size. | MUST | `PullChangesResponse.hasMore` — `SyncContracts.swift:246`; `PullChangesRequest.maxChanges` — `:233` |
| C-6 | A **schema version on the feed** (`serverSchemaVersion`) plus a per-change `payloadSchemaVersion`, so an unknown future version is quarantined rather than applied. | MUST | `PullChangesResponse.serverSchemaVersion` — `SyncContracts.swift:247`; `ChangeEnvelope.payloadSchemaVersion` — `:205`; `BackendPullEngine.swift:82` |
| C-7 | The response must **echo the account context**, so the client can bind it to the active account before applying (defence against a delayed prior-account response). | MUST | `PullChangesResponse.accountContext` — `SyncContracts.swift:248-249`; ADR-0012 §2 isolation invariants |
| C-8 | Poll-based pull is sufficient this milestone; **no socket / push-delivery is required**. A provider whose only correct path is a realtime subscription is a poor fit. | SHOULD | ADR-0012 §4 ("No continuous socket / push delivery is designed in this milestone") |
| C-9 | Independent streams must be expressible later (`SyncStream`, `"default"` today) without a breaking change. | SHOULD | `SyncStream` — `SyncContracts.swift:88-93` |
| C-10 | The provider's own client-side cache/offline layer must be **avoidable or disableable**. Two competing offline stores with two conflict policies is a correctness hazard, not redundancy. | MUST | ADR-0003 (never blanket last-write-wins); `ConflictResolution.swift`; SYNC_DESIGN.md conflict table |

---

## D. Authorization — the single biggest thing a backend must add

| ID | Requirement | MUST/SHOULD | Fixed by |
|---|---|---|---|
| D-1 | **Server-enforced Coach↔Client relationship authorization**: which coach may assign to / read from which client. Today this is **advisory only on device** and is explicitly recorded as impossible without a backend. This is the headline requirement. | MUST | SYNC_DESIGN.md "Relationship lifecycle" ("Relationship authorization is **advisory locally**"); SECURITY_BOUNDARIES.md "Remaining server requirement (R-01/R-02)"; ADR-0012 §6 and "What remains impossible"; KNOWN_ISSUES L8 |
| D-2 | The relationship must be a **first-class server entity with a lifecycle** (`invited / active / declined / ended / revoked`), and authorization must hinge on `active`. Ending a relationship blocks **new** access without deleting history. | MUST | `relationship` table — MIGRATIONS.md v3; ADR-0012 §6; conflict rule `relationshipEnded` → "block new access, retain existing history" — SYNC_DESIGN.md; CLAUDE.md privacy rule ("sharing off stops future sharing, never deletes past content") |
| D-3 | **Per-account data isolation**: Account A can never read or apply Account B's state, enforced by the server and not merely by the client's account-scoped database. | MUST | ADR-0012 §2 isolation invariants; `AccountDatabasePath` — `MazidiAuth/AccountDatabasePath.swift:14-32`; SECURITY_BOUNDARIES.md "Account-scoped databases" |
| D-4 | Authorization must be expressible as a **relationship-graph rule**, not just "owner == subject". Row-ownership-only models (the common mobile-BaaS default) cannot express "coach may write an assignment whose reader is a different account". | MUST | ADR-0012 §6/§7; `workout_assignment.relationship_id` — MIGRATIONS.md v3 |
| D-5 | Per-coach **per-category consent** must be expressible server-side later (client can revoke a category of sharing). Not required in the first integration, but the model must not preclude it. | SHOULD | CLAUDE.md privacy rules; ADR-0008 §7 (assistant-coach/relationship-scoped authz deferred); ROADMAP Phase 7 (13f/13h) |
| D-6 | A denied write must return a **typed permanent rejection** (`forbidden` / `relationshipEnded`), not a generic 500 or a silent no-op — the client dead-letters it visibly. | MUST | `PermanentRejection.forbidden`, `.relationshipEnded` — `SyncContracts.swift:162,164` |
| D-7 | **Assignment delivery/receipt must be server-attested**: `acceptedByServer` and `availableToClient` are server facts; `openedByClient` is a distinct client receipt event. "Queued" must never be upgraded to "Delivered" by anything but a real server ack. | MUST | ADR-0012 §7; SYNC_DESIGN.md "Delivery / receipt state machine"; `DeliveryAck` — `SyncContracts.swift:275-286` |
| D-8 | **Session epoch** claim for the one-device rule must be server-issued and monotonic (currently hardcoded `1`). | MUST | `WorkoutSyncEndpoint.claimSessionEpoch` — `MazidiNetworking/Contracts.swift:31-33`; KNOWN_ISSUES M4 |

---

## E. Media — object storage + CDN for the 206-clip library

| ID | Requirement | MUST/SHOULD | Fixed by |
|---|---|---|---|
| E-1 | Object storage addressed by **immutable, checksum-backed, provider-neutral relative keys** of the exact shape `exercises/<slug>/<kind>-v<n>.<ext>`. The key must never carry a hostname, bucket, credential or absolute path. | MUST | `MediaLocator.objectKey(slug:kind:contentVersion:)` — `MazidiContent/CatalogueModels.swift:47-49`; `MediaLocator.sha256` doc — `:31-37`; ADR-0011 §3 |
| E-2 | The origin must be a **single injected base URL** joined with that relative key — `MEDIA_BASE_URL`, empty ⇒ remote tier honestly disabled. No SDK-constructed URLs. | MUST | `RemoteMediaOrigin` — `MazidiContent/MediaLocation.swift:101-124`; `Config/Base.xcconfig:17`; ADR-0011 §3 |
| E-3 | **Authenticated, expiring, revocable URLs. Never public.** A URL leak must be containable. | MUST | CLAUDE.md privacy rule ("exports are authenticated, expiring, revocable, never public URLs"); ARCHITECTURE.md §4 ("7-day expiring revocable links, never unprotected shared storage") |
| E-4 | Because signed URLs are generally not individually revocable at the CDN, the provider must offer a **real revocation lever** — signing-key rotation, a key-group/token-key that can be retired, or an authenticated edge check — and the operational cost of pulling it must be understood. | MUST | Derived from E-3; recorded as an evaluation question rather than assumed |
| E-5 | **Poster-first delivery.** Posters are small and fetched eagerly; clips stream on demand. Immutable keys must be cacheable long (versioned filenames make cache-busting free). | MUST | ARCHITECTURE.md §6; `asset-cdn-integration.md` "Delivery rules (panel 7i)"; `MediaLocator.contentVersion` — `MazidiContent/CatalogueModels.swift:31` |
| E-6 | The full 206-clip library must **never be bundled or auto-downloaded**; cache tiers are auto / opt-in Wi-Fi prefetch / explicit download. Egress pricing must be evaluated against that access pattern, not against a naive "every client downloads everything". | MUST | `asset-cdn-integration.md`; ARCHITECTURE.md §6; CLAUDE.md "Never commit — the full animation library" |
| E-7 | **Coach-scoped ACLs for custom exercise uploads** into the same namespace: an upload by coach A must not be readable by coach B or by unrelated clients. | MUST | `asset-cdn-integration.md` ("Custom coach exercises upload to the same CDN namespace with coach-scoped ACLs") |
| E-8 | A **versioned manifest with content hashes** must be servable (`manifest.json`), matching `MediaManifestRecord` (slug, poster/video keys, version, checksum, availability + content review status). | MUST | `MediaManifestRecord` / `MediaManifestEndpoint` — `MazidiNetworking/Contracts.swift:39-56`; `asset-cdn-integration.md` "Manifest contract" |
| E-9 | A signed URL must **never appear in an audit event, log, or analytics payload**. | MUST | ADR-0012 §10 privacy exclusions; SYNC_DESIGN.md "Audit"; CLAUDE.md ("No personal/sensitive data in URLs or analytics payloads") |

---

## F. Data protection — LEGAL REVIEW REQUIRED

The app stores **personal health/fitness data about named clients** of a personal trainer:
workout performance, discomfort/pain reports (panel 5d), check-ins, coach notes. Under UK GDPR
this is at minimum personal data and plausibly special-category health data. That determination
is **not an engineering call**.

| ID | Requirement | MUST/SHOULD | Fixed by |
|---|---|---|---|
| F-1 | **UK/EU data residency** — data at rest in a UK or EU region, chosen at provisioning time and verifiable. | LEGAL + MUST | Product is UK-first (DL-03: GBP + UK); R-05 legal/privacy review |
| F-2 | A **signed processor agreement / DPA** with the provider, available on the tier actually purchased (some vendors gate a signed DPA behind paid or enterprise tiers). | LEGAL | R-05; CLAUDE.md privacy rules |
| F-3 | A **published, current subprocessor list** with change notification, so onward transfers are known. | LEGAL | R-05 |
| F-4 | **Deletion and retention support**: the provider must permit hard deletion of a data subject's records on request, and retention periods must be configuration, not constants. Note the product rule: **deletion ≠ cancellation** — cancelling a subscription must never delete client records. | LEGAL + MUST | CLAUDE.md ("deletion ≠ cancellation"; "no plan change or cancellation ever removes client records"); DL-01; ROADMAP Phase 7 (13g/13j) |
| F-5 | **Export**: a data subject's data must be exportable through an authenticated, expiring, revocable channel — never a public URL, never unprotected shared storage. | MUST | ARCHITECTURE.md §4; CLAUDE.md privacy rules |
| F-6 | **No personal or sensitive data in URLs, query strings, or analytics payloads.** REST path design must therefore use opaque ids, and the provider's own telemetry must not require otherwise. | MUST | CLAUDE.md; ARCHITECTURE.md §8 (analytics vs audit separation) |
| F-7 | The provider must not require the developer to hold data they cannot access for their own compliance obligations — i.e. a model where the developer is contractually the controller but technically cannot export or delete is a compliance trap. | LEGAL | Derived from F-4/F-5; directly relevant to CloudKit's private-database model |
| F-8 | Interaction with **DL-07 (SQLCipher at-rest encryption, undecided)**: choosing a provider does not settle at-rest encryption on device, and the backend choice must not be used as an argument to skip it. | LEGAL + eng lead | DL-07; SECURITY_BOUNDARIES.md "Deferred"; MIGRATIONS.md ("SQLCipher encryption is a separate pending decision") |

---

## G. Operational

Cost assumptions are stated explicitly so they can be challenged. **These are assumptions, not
measurements** — no load test exists and no backend exists.

**Scale assumption S0 (pilot):** ~5 coaches × ~20 clients = ~105 accounts; a handful of workouts
per client per week.
**Scale assumption S1 (target):** ~50 coaches × ~30 clients = ~1,500 client accounts + 50 coach
accounts ≈ **1,550 monthly active accounts**.
**Traffic assumption:** ~4 workouts/client/week; a workout produces on the order of 30–80 outbox
mutations (session start, per-set entries, swaps, completion, audit events), batched. That is
roughly **6,000 client-workouts/month ≈ 300k–500k mutations/month**, plus poll-based pulls (say
every app foreground + every 15 min while active ≈ low hundreds of thousands of requests/month).
Database size is small: a few GB at most, dominated by set entries and audit events.
**Media assumption:** 206 clips + 206 posters, roughly 100–400 MB of objects; posters fetched
broadly, clips fetched selectively and cached immutably. Egress is the cost driver and is
bounded by the "never auto-download the library" rule (E-6).

| ID | Requirement | MUST/SHOULD |
|---|---|---|
| G-1 | Cost at S0 must be near-zero or low-tens-of-GBP/month; cost at S1 must be predictable and modest relative to a subscription business. Usage-metered pricing with a cliff (per-MAU auth pricing, per-read database pricing) must be modelled, not hand-waved. | MUST |
| G-2 | **Observability**: request logs, error rates, and latency visible to the operator. Distinct from the app's own audit trail — ARCHITECTURE.md §8 keeps audit and analytics separate, and server telemetry is a third thing that must not swallow personal data. | MUST |
| G-3 | **Backup and restore** with point-in-time recovery, and a tested restore path. Client data loss is the K-01 risk. | MUST |
| G-4 | **Migration-out / exit path.** The lock-in cost must be stated: can the data be exported in an open format, and can the server be re-implemented elsewhere without changing the client contracts? | MUST |
| G-5 | **SLA and maturity** — an actual SLA on the tier purchased, and a track record. A single-founder service or a product with sunset signals is a risk. | SHOULD |
| G-6 | The provider must not require a **macOS/Xcode-only** toolchain for the server side; MazidiKit is deliberately buildable off-Mac (ADR-0001) and CI is not yet set up (R-09 / DL-09). | SHOULD |
| G-7 | Idempotency at the storage layer must be cheap to implement — a unique index on the idempotency key with a stored canonical response. Providers that make this awkward raise the cost of B-1/B-2. | SHOULD |

---

## H. Architectural fit — the non-negotiable seam

| ID | Requirement | MUST/SHOULD | Fixed by |
|---|---|---|---|
| H-1 | The provider must be reachable **behind the existing provider-neutral protocols**: `SyncBackendTransport` and `AuthProviding`. No new seam may be invented for it. | MUST | `SyncBackendTransport` — `SyncContracts.swift:334-339`; `AuthProviding` — `MazidiAuth/AuthProviding.swift:29-51` |
| H-2 | **No provider SDK type may enter** `MazidiDomain`, SwiftUI views, non-sync persistence records, workout services, or catalogue services. | MUST | ADR-0012 §1; ADR-0008 §1; ARCHITECTURE.md §2 layer table |
| H-3 | **Prefer plain HTTPS/REST over `URLSession`** to no SDK at all. If an SDK is unavoidable it must be confined to an app-layer adapter, because `MazidiKit` is Foundation-only and must keep building and testing off-Mac. | MUST | ADR-0001; CLAUDE.md layout rule ("MazidiKit imports Foundation only"); ADR-0012 §1 |
| H-4 | Adding a dependency to `MazidiKit` is effectively forbidden — the package's platform-neutrality is load-bearing for the Windows/Linux test story. | MUST | ADR-0001; ARCHITECTURE.md §1 |
| H-5 | Configuration (base URL) must come from `.xcconfig` → Info.plist, with **no host, tenant id, key, or signed URL in the repo**. | MUST | `Config/Base.xcconfig:17,24`; ADR-0010 §6 / ADR-0011 §3; ARCHITECTURE.md §9; CLAUDE.md "Never commit" |
| H-6 | The transport must honour **Swift structured-concurrency cancellation** and return `Result<_, TransportError>` — no untyped `Error` leaking to callers. | MUST | `SyncBackendTransport` doc — `SyncContracts.swift:331-339`; `TransportError` — `:294-307` |
| H-7 | The server must be able to speak the app's envelope over ordinary JSON (`Codable`), including `Data` payload blobs, without demanding a provider-specific wire format or code generation step. | SHOULD | `MutationEnvelope`, `ChangeEnvelope` — `SyncContracts.swift:99,198` |
| H-8 | The **DEBUG `FakeSyncBackend` must remain the test path**; the real transport must be additive and Release-inert until configured. No live-network tests. | MUST | ADR-0012 §10; SYNC_DESIGN.md "Layers" |

---

## Disqualifying patterns (stated once, applied in the evaluation)

1. **A mandatory client SDK that owns the offline cache and the conflict policy.** It duplicates
   and contradicts `MazidiSync` (C-10, B-10). The app would have to abandon its at-most-once
   idempotency and cursor semantics, which ADR-0003 and ADR-0012 forbid.
2. **Blanket last-write-wins.** ADR-0003 and the ARCHITECTURE.md §5 conflict table forbid it.
3. **Row-ownership-only authorization.** Cannot express coach↔client (D-4).
4. **Public or non-revocable media URLs** (E-3, E-4).
5. **A platform that structurally excludes non-Apple clients**, if a non-Apple future is wanted —
   this is a product decision the ADR must surface, not assume.
6. **Any model where the developer cannot meet export/deletion obligations** for data they are
   the controller of (F-7).

---

## What this document deliberately does not decide

The provider. The transport implementation. Whether SQLCipher (DL-07) lands. The invitation /
discovery UX (ADR-0012 §6 explicitly refuses to fabricate it). Push notification topology
(DL-06, R-07). Any pricing commitment. Those belong to ADR-0013 and the milestones after it.
