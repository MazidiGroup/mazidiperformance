# ADR-0013 — Backend provider selection

**Status:** **Proposed** · 2026-07-29

> **Why this ADR is `Proposed` and not `Accepted`.** ADR-0001 through ADR-0012 are all
> `Accepted`, because each was an engineering decision this team owns end to end. This one is
> deliberately different: it commits money, creates vendor lock-in, and determines under whose
> processor agreement the personal health data of named clients will sit. The deciding input —
> the legal/privacy review (R-05, DL-01) and the cost approval — is **not an engineering
> judgement and has not happened.** The recommendation below is complete and actionable, but it
> requires the human owner's sign-off before it becomes `Accepted`. Nothing may be integrated
> against it until then.

**No code changed in the commit that introduces this ADR. No account was created, nothing was
deployed, no dependency was added, and no cost was incurred.** `SYNC_BASE_URL` and
`MEDIA_BASE_URL` remain empty (`Config/Base.xcconfig:17,24`) and the real transport remains
inert.

## Context

R-01 and R-02 have been open since the risk register was written: **no backend API exists**, and
server-side idempotency-key support is a recorded backend dependency. DL-11 records that the
`MazidiNetworking` protocols are the client-authored API spec, marked PROPOSED. ADR-0008 §1 and
ADR-0012 §1 both explicitly deferred the provider choice to "its own ADR when the backend
decision (R-01) lands". This is that ADR.

Two prior decisions have already fixed almost everything a provider could otherwise dictate:

- **ADR-0008** fixed identity and session semantics: a provider-neutral `AuthProviding`
  boundary, `RevocationCheck { active, revoked, unknown }` where `.unknown` is never inferred as
  revoked (`MazidiAuth/AuthProviding.swift:66-72`), Keychain-only credentials with no plaintext
  fallback (`MazidiAuth/CredentialStore.swift:16-29`), role routing from validated claims where
  exactly one of `[.client]`/`[.coach]` is routable (`MazidiAuth/AuthTypes.swift:29-32`),
  account-scoped databases keyed by a domain-separated hash
  (`MazidiAuth/AccountDatabasePath.swift:14-32`), and session generations that discard stale
  async results (`MazidiAuth/SessionCoordinator.swift:16`).
- **ADR-0012** fixed the sync contract: distinct identity types, deterministic mutation ids equal
  to the client idempotency key (`MazidiNetworking/SyncContracts.swift:32-46`), partial batch
  acks keyed by mutation id (`:184-187`), typed permanent-vs-retryable rejection (`:158-180`),
  monotonic server versions (`:61-67`), a cursored change feed with explicit tombstones
  (`:216-271`), typed `TransportError` (`:294-307`), and a token that never enters a serialised
  body (`:309-327`). The push/pull/conflict engines and a deterministic `FakeSyncBackend` are
  built and tested (`Packages/MazidiKit/Sources/MazidiSync/`).

The consequence is stated plainly in KNOWN_ISSUES **L8**: everything except a real server exists.
What remains impossible without one is real delivery/receipt confirmation, **server-enforced
relationship authorization**, cross-device supersession (**M4**, epoch hardcoded to `1`),
server-side revocation and "sign out everywhere", and actual pulled data with authoritative
versions. **L9** records that migrations are forward-only, so a provider that forces a schema
rethink is expensive.

The full requirements matrix is `docs/architecture/backend-provider-requirements.md`; the scored
evaluation is `docs/architecture/backend-provider-evaluation.md`.

## Decision drivers

1. **The client semantics are not negotiable.** At-most-once idempotency, partial acks, monotonic
   versions, durable cursors and per-class conflict resolution are merged and tested. A provider
   whose own offline/sync layer competes with them is a hazard, not a feature.
2. **Server-enforced coach↔client authorization is the point of the exercise.** It is the single
   largest thing a backend adds and is advisory-only on device today.
3. **The data is personal health data about named individuals.** Data-protection posture carries
   the highest consequence.
4. **`MazidiKit` must stay Foundation-only** (ADR-0001) — no provider SDK anywhere near it.
5. **Delivery risk is real.** There is no CI (R-09, DL-09), the app target needs a Mac (R-08),
   and every hour spent on infrastructure is an hour not spent on the Phase 3–7 product.
6. **Honesty is a shipped property.** Whatever is chosen must let the UI keep telling the truth:
   "Queued ≠ Delivered ≠ Opened", `.unknown` ≠ revoked, no "sign out everywhere" without real
   support.

### Three findings that reframed the decision

- **No identity provider can answer the revocation question.** AWS Cognito documents that revoked
  tokens still pass standard JWT signature/expiry validation; Supabase documents that an access
  token cannot be revoked before expiry. **Requirement A-3 must be served by a revocation store
  we own**, checked server-side per request, with `.unknown` meaning "the store was unreachable".
  This is not a provider gap to shop around for — it is universal.
- **Every candidate requires us to write the server logic.** No BaaS ships idempotency
  canonicalisation, partial batch acks, monotonic change feeds or relationship authorization. The
  question is therefore *where our own small server runs and who supplies the database, identity
  and object store around it* — not *which backend to buy*.
- **"Revocable URLs" cannot mean "recallable after issue."** No evaluated object store supports
  per-URL revocation; CloudFront/Bunny/R2 revocation is signing-key rotation, i.e. mass
  invalidation. The only design giving genuine per-grant revocation is an **authorising edge
  check**.

## Recommendation

### Primary: Supabase, London (`eu-west-2`), used narrowly

Managed Postgres + GoTrue authentication + Row Level Security + (data only) Storage, on the
**Pro** plan with a Small compute add-on (~$40/month, verified 2026-07-29), with:

- **all sync semantics implemented as our own Postgres functions** (transactional at-most-once
  idempotency via a unique key + `INSERT … ON CONFLICT … RETURNING` the canonical result; a
  sequence-backed monotonic `server_version`; a cursored change feed over that version),
  exposed over **plain HTTPS** via PostgREST RPC and reached from `URLSession`;
- **RLS as defence in depth** for per-account isolation (D-3) and the coach↔client relationship
  join (D-1/D-4) — the relationship table already exists in the `v3` schema;
- **no `supabase-swift` dependency anywhere**, so ADR-0001, ADR-0012 §1 and requirements
  H-2/H-3/H-4 hold unchanged;
- every Supabase feature that would compete with `MazidiSync` — Realtime, the client-side offline
  cache, auto-generated table CRUD — **simply unused**.

**Why this and not the highest-scoring option.** The weighted matrix ranks **AWS first at 89.4%
and Supabase second at 86.2%**. That gap comes entirely from data protection and operations —
AWS's DPA is automatically incorporated into its Service Terms with no signature, its compliance
artifacts are freely available, it publishes SLAs, and RDS offers 35-day PITR. Those are genuine
advantages and this ADR does not minimise them. Supabase is recommended anyway because the 3.2
point gap is **inside the noise of my own weighting**, while the difference in *delivery risk* is
not: Supabase requires no compute to operate, no IAM estate, no IaC and no alarm plumbing, and it
leaves the exit door wide open (plain Postgres, `pg_dump`, self-hostable). For a team with no CI
and a single Mac, that is the difference between a working transport this quarter and an
infrastructure project.

### Runner-up: AWS, `eu-west-2`

API Gateway + Lambda + RDS Postgres + Cognito + S3/CloudFront.

**Switch to AWS if any of the following is true after review:**

1. **Legal or procurement requires a compliance report or a contractual SLA.** Supabase lists
   "SOC2 & ISO 27001" as a **Team-plan ($599/month)** line item and uptime SLAs as
   **Enterprise-only**. If either is required, Supabase costs 24× more and *still* has no SLA
   below Enterprise — at which point AWS wins outright. (Exactly what that gating means is
   **UNVERIFIED**; see open question OQ-1.)
2. **The DPIA requires an automatically-incorporated processor agreement** with published SCC /
   UK-Addendum coverage rather than a per-customer signed DPA.
3. **A Supabase Pro customer cannot execute the signed DPA at all** (OQ-2). This would be
   disqualifying immediately.
4. **Platform risk materialises** — a pricing model change, an acquisition, or a service posture
   that no longer suits a health-data workload.

Cognito is additionally attractive on one specific point: enabling token revocation adds
`jti`/`origin_jti` claims, which is precisely the identifier our own revocation store needs.

### Media origin: a separate decision, deferred to the media-backend slice

**Supabase Storage is not recommended for the 206-clip library.** Its signed URLs are signed with
an internal key and remain valid until expiry regardless of key changes, with immediate
revocation requiring a support request — failing **E-4**; and CDN caching is documented for
*public* buckets, while the library must be private — putting **E-5** in doubt.

The leading candidate is **Cloudflare R2 behind a Worker**: R2 egress is free and the library
(~400 MB, ~309k reads/month at target scale) fits inside the free tier, with a Workers Paid plan
at ~$5/month; and a Worker validating a grant id against a revocation source **on every request**
is the only evaluated design that genuinely satisfies E-4. **Bunny.net** is the alternative if
EU-entity contracting outweighs per-grant revocation (BunnyWay d.o.o. is a Slovenian EU entity
with London Edge Storage). Neither is decided here.

## What this recommendation does NOT decide

- **It does not authorise integration.** No adapter, no transport, no SDK, no configuration.
- **It does not create an account, a project, a bucket, a tenant or a key**, and it records none.
- **It does not settle the media origin** (above) or DL-05 (CDN host, URL scheme, manifest
  versioning).
- **It does not settle DL-07** (SQLCipher vs iOS Data Protection at rest). Choosing a backend
  does **not** discharge on-device encryption, and must not be used as an argument to skip it —
  if anything, a backend that authenticates a device into a coach's client roster raises the
  value of the local database to an attacker.
- **It does not settle DL-06 / R-07** (push topology, quiet-hours evaluation) or DL-04
  (billing channel).
- **It does not settle the invitation / discovery UX.** ADR-0012 §6 explicitly refused to
  fabricate it; that remains true.
- **It does not change any product-safety rule.** Draft-content labelling, per-coach
  per-category consent, deletion ≠ cancellation, "the app never moves money", and the
  accessibility acceptance criteria are unaffected.
- **It does not weaken ADR-0003, ADR-0006, ADR-0008 or ADR-0012.** Every contract stands as
  merged.

## Consequences

**If accepted:**

- The `SyncBackendTransport` gains a second implementation — a plain `URLSession` adapter in the
  **app target**, alongside the DEBUG `FakeSyncBackend`, which remains the test path.
  `MazidiKit` gains no dependency.
- `AuthProviding` gains a real implementation in the app target. `UnavailableAuthProvider`
  remains the Release fallback until that implementation is configured, so Release stays honest.
- **We take on a server codebase.** Postgres functions implementing push, pull, relationship
  authorization, delivery acknowledgement and revocation become a maintained artifact with its
  own migrations, review and test story. Writing a complete push/pull engine in plpgsql is
  ergonomically awkward; that is an accepted cost of avoiding a separate compute tier, and is the
  first thing to revisit if it bites.
- **We take on a revocation store we own** (finding above), which is the only way A-3/A-4 can be
  satisfied by anyone.
- **Recurring cost begins** — roughly $40/month at pilot scale, plus ~$5/month for media, before
  VAT and before any PITR add-on (~$100/month per 7 days of retention).
- KNOWN_ISSUES **L8** and **M4** become closable in the milestone after next; **L7** (inert
  remote media tier) closes with the media slice.
- Backups: Supabase Pro gives a 7-day daily-backup window. **Regardless of provider we must run
  our own scheduled `pg_dump` to separate storage and actually test-restore it** — UK GDPR
  Art. 32 makes the ability to restore availability in a timely manner an explicit obligation,
  and a backup never restored is not a backup.

**If rejected or deferred:** nothing breaks. The app continues to ship contracts + a DEBUG fake
with honest UI, exactly as ADR-0012 designed. This ADR's cost is the evaluation effort, not a
commitment.

## Migration / exit strategy

Lock-in was weighted explicitly, and the primary recommendation is the option with the lowest
exit cost among managed candidates.

- **Data.** Supabase is stock Postgres. Exit is `pg_dump` / `pg_restore` into any other Postgres
  — Fly Managed Postgres (`lhr`), Neon (`aws-eu-west-2`), RDS, or a self-hosted instance. The
  entire stack is also self-hostable.
- **Server logic.** Postgres functions are SQL, not a vendor runtime. If they are ever
  re-implemented as a separate service, note that **ADR-0001 makes `MazidiKit` Linux-buildable,
  so a Swift server could import the `SyncContracts` types directly** and eliminate client/server
  envelope drift by construction. That is a genuine future option, not a commitment.
- **Identity is the sticky part** for every candidate: password hashes and provider subject ids
  do not port cleanly. Mitigations: keep `AccountID` opaque and provider-issued (already true —
  `MazidiAuth/AuthTypes.swift:5-9`), never derive anything from its internal structure, and note
  that `AccountDatabasePath` hashes it, so **an account-id change is a database-path change** and
  would need an explicit, user-visible migration. This is the one place a provider switch is
  genuinely expensive, and it argues for choosing once, carefully — which is what this ADR is
  for.
- **The client is already insulated.** Because the transport sits behind `SyncBackendTransport`
  and `AuthProviding`, a provider switch is an app-target adapter swap, not an app rewrite. That
  insulation is the payoff from ADR-0008 and ADR-0012 and should be preserved deliberately.
- **Media** is checksum-addressed with provider-neutral relative keys
  (`MazidiContent/CatalogueModels.swift:47-49`) and a single injected origin, so the object store
  is swappable by changing `MEDIA_BASE_URL` and re-uploading immutable objects.

## Open questions requiring human and legal sign-off

None of these can be closed by engineering. Each blocks moving this ADR to `Accepted`.

| ID | Question | Owner |
|---|---|---|
| OQ-1 | Does the DPIA/procurement position require a SOC 2 or ISO 27001 **report** and a contractual **SLA**? Supabase gates the former to Team ($599/mo) and the latter to Enterprise. A "yes" switches the recommendation to AWS. | Legal + owner |
| OQ-2 | Can a Supabase **Pro**-tier customer execute the signed DPA? The DPA (v. 2025-03-14) is strong — EU SCCs plus the **ICO Approved Addendum B.1.0**, UK GDPR/DPA 2018 named, and a clause 7.2 commitment that region-directed data is *"stored and primarily Processed in that region"* — and the DPA page documents **no** plan restriction. But that is inferred from silence. A "no" is disqualifying. Also review clause 7.1's broader default and the word *"primarily"*. | Legal + owner |
| OQ-2b | Supabase publishes **no public subprocessor page** (`/legal/subprocessors` returns 404); the list is **Schedule 3 of the DPA PDF** and the objection window is only **5 days**. Decide whether that transparency posture is acceptable and how changes will be monitored. | Legal + owner |
| OQ-3 | Is the workout, discomfort and check-in data **special-category health data** under UK GDPR Art. 9? If so a DPIA is very likely mandatory. Engineering must not make this call. | Legal (R-05) |
| OQ-4 | Is UK residency required, preferred, or merely nice to have? UK GDPR contains **no localisation mandate** — transfers are lawful with an IDTA / UK Addendum plus a Transfer Risk Assessment. This changes which candidates are even in scope. | Legal (R-05) |
| OQ-5 | Approve the recurring cost: ~$40/month pilot, plus ~$5/month media, plus ~$100/month if PITR is required. | Owner |
| OQ-6 | Review subprocessor lists before any data flows. **Fly.io lists Anthropic and OpenAI; Bunny.net lists OpenAI.** If either is in the final stack, exactly what customer data can reach those subprocessors must be established and answerable in a coach's due-diligence questionnaire. | Legal + owner |
| OQ-7 | **DL-07 interaction.** A backend does not discharge at-rest encryption on device. Decide SQLCipher vs iOS Data Protection **independently**, and note the account database now holds a coach's whole client roster. | Eng lead + legal |
| OQ-8 | Retention and deletion periods (DL-01, R-05) must be fixed before the provider holds real data, because **deletion ≠ cancellation** is a product rule the server must enforce. | Legal |
| OQ-9 | Confirm the **UNVERIFIED** items in `backend-provider-evaluation.md` §5 that bear on cost or compliance — at minimum U-1, U-2, U-3, U-7. | Owner |

## Phased integration plan — for the milestone AFTER this ADR is accepted

Nothing below happens in this milestone. Each phase is separately reviewable and each preserves
the honesty rules.

**Phase 0 — sign-off (no code).** Close OQ-1…OQ-9. Move this ADR to `Accepted` with the decision
recorded, or record the switch to the runner-up and why. Resolve R-01/R-02 in the risk register
and move DL-11 to a decision.

**Phase 1 — server contract, still no client change.** Implement the server side of
`SyncContracts.swift` against a staging project: the idempotency table with its unique key and
stored canonical result (B-1/B-2), partial batch ack (B-3), typed rejection (B-4), the
monotonic version sequence (B-5), the change feed with tombstones and pagination (C-1…C-6),
rate limiting with retry-after (B-6), and the revocation store (A-3/A-4). Verify it against the
**same expectations `FakeSyncBackend` already encodes** — the fake is the executable spec.
`SYNC_BASE_URL` stays empty; the app is untouched.

**Phase 2 — real transport behind the existing seam.** Add a `URLSessionSyncTransport` in the
**app target** implementing `SyncBackendTransport` — plain HTTPS/JSON, no SDK, no internal retry
(B-10), typed `TransportError`, cancellation-honouring, token fetched at send time from the
injected accessor (B-9). `FakeSyncBackend` remains the test path; there are still **no
live-network tests**. Configure `SYNC_BASE_URL` in **Staging only**; Release stays empty and
therefore inert.

**Phase 3 — real auth provider.** Implement `AuthProviding` against GoTrue's REST endpoints in
the app target: sign-in, refresh with rotation (single-use refresh tokens, 10-second reuse
window), restore, sign-out, and `checkRevocation`. Concretely, `checkRevocation` resolves against
our own revocation store — for the primary recommendation that means checking whether the token's
`session_id` still exists in `auth.sessions`, since the provider offers **no revocation-status
endpoint** — returning `.unknown` when that check cannot be made, and **never** inferring
revocation. Set the access-token expiry short (the documented 5-minute floor) to bound the window
in which an already-issued token still validates; use **asymmetric signing keys with the JWKS
endpoint** so validation needs no network call, and never the legacy HS256 shared secret. Role
claims are issued server-side via the custom-claims hook and stored in provider-controlled
metadata that a user cannot write; the client keeps routing only from
`SessionClaims.routableRole`. Adopt the **new API-key format from day one** — the legacy JWT-based
keys are documented as deprecated by the end of 2026, and the replacement keys must be sent in the
`apikey` header, not as `Authorization: Bearer`. `UnavailableAuthProvider` remains the Release
fallback until this is signed off. **"Sign out everywhere" is only claimed once global
refresh-token revocation is genuinely wired and tested** — until then the honest-limitation copy
stays (A-10), because an access token issued before revocation still verifies until it expires.

**Phase 4 — relationship authorization (the milestone's real prize).** Move the `relationship`
lifecycle from advisory-local to server-enforced: RLS policies plus function-level checks so a
coach may only write assignments for clients they have an **active** relationship with, and no
account can read another's state. Denials return `PermanentRejection.forbidden` /
`.relationshipEnded`, which the client already dead-letters visibly. Then wire real delivery
states — `acceptedByServer` / `availableToClient` from the server, `openedByClient` as a distinct
client receipt — and only then may coach-side copy move off "Queued — delivery confirms with
backend". Close KNOWN_ISSUES **L8**; take `claimSessionEpoch` server-side and close **M4**/**M5**.

**Phase 5 — media origin.** Decide and stand up the object store (R2 + Worker leading, Bunny as
alternative), ingest the 206-clip library with immutable checksum-addressed keys, and issue
short-TTL grants from an authorising endpoint that checks role, relationship and consent **at
issue**. Configure `MEDIA_BASE_URL` in Staging; Release stays empty until the library is
ingested and reviewed (R-03, R-04). Close **L7**, and take the **L6** cache re-hash optimisation
at the same time since downloads finally exist.

**Throughout:** `SYNC_BASE_URL` and `MEDIA_BASE_URL` stay empty in the shipped `Config/*.xcconfig`
until the phase that legitimately needs them, and **no host, tenant id, key, bucket name or
signed URL is ever committed** (ARCHITECTURE.md §9, CLAUDE.md "Never commit").

## Documentation follow-up (not a code change)

ARCHITECTURE.md §4 says exports use "7-day expiring revocable links". Research established that
**no object store supports per-URL revocation** — revocation means signing-key rotation, or an
authorising edge check on every request. Our own wording should be tightened to
"authorised at issue, short-TTL, revocable by grant" when the media slice lands, so the claim
stays true. `design/handoff-current/` is a frozen baseline and is **not** edited.

## Alternatives rejected

- **Firebase** — rejected primarily on residency: Firebase's own privacy page states that
  *"The Firebase Authentication service is run only from US data centers"*, and Auth is absent
  from the list of Firebase services offering data-location selection. Firestore can sit in
  `europe-west2` (London), but every named client's identity data would be processed in the US
  permanently, with no region option — failing **F-1**. Secondarily: Firestore's offline
  persistence is on by default on Apple platforms and resolves concurrent writes
  **last-write-wins**, which ADR-0003 forbids and `MazidiSync` already replaces (**C-10**); and
  while security rules *can* do a relationship lookup (limits are 10 document-access calls for
  single-document/query requests, 20 for multi-document/transactional ones), those lookups are
  **billed as reads even when the request is denied** and are re-charged on reconnect and on rule
  changes, while the alternative — a custom claim — is capped at 1000 bytes and goes **stale until
  the next token refresh**, which is the wrong trade for "active relationship" semantics
  (**D-4/D-5**). Scored 47.8%. Firebase does beat the primary recommendation on two points worth
  recording: it has a genuine revocation-check API (`verifyIdToken(checkRevoked:)`), and Firestore
  carries a 99.99% regional SLA on ordinary pay-as-you-go.
- **CloudKit** — no per-record or per-user-pair authorization (roles are per record *type*, and
  only on the public database), no server-side logic of any kind, the Server-to-Server API cannot
  reach private databases, no confirmable residency guarantee or processor DPA, and GDPR export /
  erasure is structurally unmeetable for data the developer cannot read. Also no Android path.
  Scored 10.6%. Rejected outright — this echoes ADR-0002's rejection of Realm for "external
  dependency risk, sync product entanglement".
- **Auth0 as the identity layer** — genuinely attractive (a GA **UK** region, 25,000 MAU free, a
  clean REST API usable from `URLSession`), but two unresolved blockers: whether a signed DPA is
  available below Enterprise, and Enterprise-gated refresh-token management. Keep as a fallback
  identity provider if the primary's auth proves inadequate.
- **Self-managed on Hetzner** — cheapest, and the contracting is excellent (German Art. 28
  processor, DPA by checkbox). Rejected on operational risk: no UK location, no managed Postgres
  found, and one person owning WAL archiving, PITR, restore drills, failover and patching for
  named clients' health data.
- **Fly.io `lhr` + Fly Managed Postgres + R2** — scored 82.2% and is the strongest "own service"
  option, with real London compute *and* database and the unique advantage that a Swift server
  could import `SyncContracts` directly. Rejected for now because Fly's Managed Postgres backup
  retention and PITR window are **undocumented**, its SOC 2 / ISO status is **unverified**, its
  subprocessor list includes AI vendors, and it still needs a separate identity provider. Revisit
  if the primary's plpgsql ergonomics become the binding constraint.
