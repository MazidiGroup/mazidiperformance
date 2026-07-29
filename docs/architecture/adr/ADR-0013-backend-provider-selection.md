# ADR-0013 — Backend provider selection

**Status:** **Accepted — for provider selection only** · 2026-07-29
(superseded status line: `Proposed`, 2026-07-29)

> **Scope of this acceptance.** What is accepted is the **provider choice**: Supabase Pro,
> London (`eu-west-2`), used narrowly, with AWS `eu-west-2` as the named runner-up. Nothing else
> is accepted. **Integration is still gated** — see "Phase 0 integration gates" below. This ADR
> becomes an authorisation to *build* only when all four gates are closed.

### Sign-off record

The human owner supplied the deciding inputs on 2026-07-29. They are recorded here because the
reasoning below only holds while they hold; if any changes, this ADR must be revisited.

| Input | Owner decision |
|---|---|
| **Compliance evidence** (was OQ-1) | **NO.** No client has requested SOC 2 / ISO 27001 evidence and none is expected within 12 months. |
| **Budget** (was OQ-5) | **Approved up to £50/month**, with **usage alerting required**. Explicitly **not** a hard spend cap — a spend-cap `402` is an outage for paying clients (see "Usage alerting, not a hard cap"). |
| **Provider** | **Confirmed: Supabase Pro, London (`eu-west-2`), used narrowly.** AWS `eu-west-2` remains the named runner-up with updated switch conditions. |
| **Article 9** (was OQ-3) | **YES — treat the workout, discomfort and check-in data as special category data.** Lawful basis assumed to be **explicit consent, Art. 9(2)(a)**. Requires granular unbundled consent, a consent-record table, and a functioning withdrawal path. Design as special category, **never** as ordinary personal data. **The owner is confirming this with a solicitor** — the assumption is recorded, not settled. |
| **Residency** (was OQ-4) | **Not legally required.** UK GDPR contains no localisation mandate. **London chosen as a commercial and simplicity decision** because it is free. Recorded explicitly: region choice does **not** eliminate vendor support access from the US, and the DPA must be confirmed to include the **UK Addendum / IDTA in the document body**. |
| **New deliverables** | **ICO registration** (data protection fee), a **DPIA**, and a **data-flow map covering any AI/model API calls that touch client health data**. |

### Phase 0 integration gates

The provider is chosen. **No integration work begins until all four of these are done:**

1. **DPA executed** with the **UK Addendum verified in the document body** (not merely referenced
   or assumed) — OQ-2 / OQ-2b remain open.
2. **DPIA completed** — mandatory in practice now that Art. 9 applies.
3. **ICO registration** completed and the data protection fee paid.
4. **Solicitor confirmation** of the Art. 9(2)(a) basis, including the retention question raised
   in "Consent and data-protection model" below.

Until then this ADR authorises no adapter, no transport, no account, no key, no configuration.

**No code changed in the commit that introduced this ADR, nor in the commit that accepted it. No
account was created, nothing was deployed, no dependency was added, and no cost was incurred.**
`SYNC_BASE_URL` and `MEDIA_BASE_URL` remain empty (`Config/Base.xcconfig:17,24`) and the real
transport remains inert.

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
7. **Reversibility.** Used narrowly, Supabase **is stock Postgres**: the exit is `pg_dump`, and
   because all sync logic lives in **our own functions against our own schema** rather than in
   vendor machinery, migrating later is a **hosting change, not a rewrite**. This driver is why
   the scored gap to AWS is tolerable rather than decisive — a wrong call here is recoverable at
   the cost of a migration, not at the cost of the product. It is load-bearing: it only stays
   true while the "used narrowly" posture holds (no Realtime, no vendor offline cache, no
   auto-generated table CRUD), so every one of those exclusions is a reversibility control, not a
   style preference.

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

- **all sync semantics implemented as our own Postgres functions**, exposed over **plain HTTPS**
  via PostgREST **RPC** and reached from `URLSession`:
  - transactional at-most-once idempotency where the **first apply stores the outcome** (assigned
    `server_version` and result class) in the idempotency table and a **replay detects the
    conflict and `SELECT`s the stored canonical result**, returning `duplicateApplied(storedVersion)`
    (`MazidiNetworking/SyncContracts.swift:177`). A PostgREST upsert
    (`Prefer: resolution=merge-duplicates`) is **not** an acceptable implementation — it re-applies
    the retry's payload on replay, which is last-write-wins on the idempotency row; and
    `ON CONFLICT DO NOTHING … RETURNING` returns no row on conflict, so the one-statement form is
    not implementable. **No sync write may be routed through a PostgREST table upsert.**
  - a **per-account/stream serialized** monotonic `server_version`. A bare Postgres sequence is
    monotonic *as issued*, not *as committed*: sequences are non-transactional, so version 103 can
    commit **after** a pull has already observed 105 and advanced its cursor past it, and the
    client's `serverVersion > lastServerVersion` filter then skips 103 **permanently** — silent
    data loss, which ADR-0003 forbids. Version assignment must therefore be serialized per
    account/stream (a per-stream counter row updated under row lock inside the applying
    transaction, or an advisory lock held for that transaction) so that **assignment order equals
    commit order**. A concurrent-commit test is required.
  - a cursored change feed over that version;
- **RLS on the sync tables treated as a primary control, not defence in depth**, for per-account
  isolation (D-3) and the coach↔client relationship join (D-1/D-4) — the relationship table already
  exists in the `v3` schema. Any table still reachable through PostgREST at `/rest/v1/<table>` is
  enforced *by RLS alone*, so calling it "defence in depth" understates it. The chosen posture is
  to **revoke `authenticated` grants on all sync tables** (or keep them out of the exposed schema)
  so that **RPC is the only sync surface**; where any direct path is ever retained, its RLS must be
  reviewed at primary-control rigor;
- **no `supabase-swift` dependency anywhere**, so ADR-0001, ADR-0012 §1 and requirements
  H-2/H-3/H-4 hold unchanged;
- every Supabase feature that would compete with `MazidiSync` — Realtime, the client-side offline
  cache, auto-generated table CRUD — **simply unused**.

**Why this and not the highest-scoring option — as the reasoning now stands.** The weighted
matrix ranks **AWS first at 89.4% and Supabase second at 86.2%**. That gap comes entirely from
data protection and operations — AWS's DPA is automatically incorporated into its Service Terms
with no signature, its compliance artifacts are freely available via AWS Artifact, it publishes
SLAs, and RDS offers 35-day PITR. Those are genuine advantages and this ADR does not minimise
them. Two owner inputs then reshape the comparison:

- **The "no" on compliance evidence removes the dimension where AWS scored decisively.** No
  client has asked for a SOC 2 report or ISO certificate and none is expected within 12 months,
  so free access to compliance artifacts — the largest single component of AWS's W3 lead — buys
  nothing today. It would buy a great deal the day a corporate client asks; that is exactly the
  switch condition recorded below.
- **The £50/month ceiling independently rules out Supabase Team.** At $599/month, the tier that
  would unlock report access and an SLA is an order of magnitude outside budget. It is not a
  live option and is not being weighed as one.

What remains is therefore a narrow cost comparison — **AWS ≈ £19–39/month against Supabase Pro +
Small compute ≈ £31/month** (the evaluation's own AWS estimate is £5–35/month excluding media
egress and remains **UNVERIFIED**, U-3; either way the two land in the same band and inside
budget). Cost does not decide this. **It is decided on architectural fit and delivery risk:**
Supabase requires no compute to operate, no IAM estate, no IaC and no alarm plumbing, and it
leaves the exit door wide open (plain Postgres, `pg_dump`, self-hostable — decision driver 7).
For a team with no CI and a single Mac, that is the difference between a working transport this
quarter and an infrastructure project.

### Runner-up: AWS, `eu-west-2`

API Gateway + Lambda + RDS Postgres + Cognito + S3/CloudFront.

**Correcting a premise this ADR previously got wrong.** An earlier draft said Supabase "gates
SOC 2 / ISO 27001 to Team". That is imprecise and it mattered, because it made a future
compliance requirement look like an automatic switch to AWS. The accurate statement is:
**Supabase holds SOC 2 Type II and ISO 27001. What is gated behind Team (~$599/month) is
*access to the report / certificate* and the *SLA*** — not the certification itself. So a future
"yes" on compliance evidence is a **cost-and-procurement comparison**, not a disqualification:
**AWS (~$25–50/month, compliance artifacts free via AWS Artifact) versus Supabase Team
($599/month)**. AWS would very likely win that comparison on price alone, but it must actually be
run, against the requirement as stated by the client, at the time it is stated.

**Switch conditions — re-evaluate AWS if any of the following becomes true:**

1. **PRIMARY — a corporate client requires a SOC 2 report or a contractual SLA.** This is the
   trigger the owner's "no" on compliance evidence is holding at bay, and it is the most likely
   of these to fire. It does **not** mean "switch to AWS"; it means **re-evaluate AWS against
   Supabase Team**, on the corrected premise above. Note that Supabase has **no SLA below
   Enterprise**, so a contractual-SLA requirement specifically is harder for Supabase to meet
   than a report requirement.
2. **The DPIA requires an automatically-incorporated processor agreement** with published SCC /
   UK-Addendum coverage rather than a per-customer signed DPA.
3. **A Supabase Pro customer cannot execute the signed DPA at all** (OQ-2), **or the UK Addendum
   is not present in the document body** (Phase 0 gate 1). Either is disqualifying immediately.
4. **Platform risk materialises** — a pricing model change, an acquisition, or a service posture
   that no longer suits a health-data workload.
5. **Recurring cost breaches the approved £50/month ceiling** and cannot be brought back under
   it, or PITR stops being an acceptable thing to go without (see "Backups and PITR" under
   Consequences).

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
  accessibility acceptance criteria are unaffected. One caveat now exists and is recorded rather
  than smoothed over: **OQ-10 identifies a genuine tension** between Art. 9(2)(a) consent
  withdrawal and the *deletion ≠ cancellation* / *sharing off never deletes past content* rules.
  This ADR does not resolve it and does not weaken either rule; it routes the question to the
  solicitor and blocks the affected behaviour until answered.
- **It does not weaken ADR-0003, ADR-0006, ADR-0008 or ADR-0012.** Every contract stands as
  merged.

## Consequences

**On integration — i.e. once the four Phase 0 gates close, not on acceptance of this ADR:**

- The `SyncBackendTransport` gains a second implementation — a plain `URLSession` adapter in the
  **app target**, alongside the DEBUG `FakeSyncBackend`, which remains the test path.
  `MazidiKit` gains no dependency.
- `AuthProviding` gains a real implementation in the app target. `UnavailableAuthProvider`
  remains the Release fallback until that implementation is configured, so Release stays honest.
- **We take on a server codebase.** Postgres functions implementing push, pull, relationship
  authorization, delivery acknowledgement and revocation become a maintained artifact with its
  own migrations, review and test story. Writing a complete push/pull engine in plpgsql is
  ergonomically awkward; that is an accepted cost of avoiding a separate compute tier, and is the
  first thing to revisit if it bites. **The security review's conclusion is that this — not the
  vendor — is the binding risk in this path**, and both factual errors it found in the original
  draft (idempotency-on-upsert, sequence monotonicity) were plpgsql-implementation errors rather
  than provider limitations. **BC-11** makes the escape hatch a named tripwire rather than a
  sentiment.
- **We take on a revocation store we own** (finding above), which is the only way A-3/A-4 can be
  satisfied by anyone.
- **Recurring cost begins** — roughly $40/month (≈£31) at pilot scale, plus ~$5/month for media,
  before VAT. That sits inside the approved £50/month ceiling with little headroom, which is why
  usage alerting is a condition of the approval and not a nicety.
- KNOWN_ISSUES **L8** and **M4** become closable in the milestone after next; **L7** (inert
  remote media tier) closes with the media slice.

**Accepted consequence — daily backups, not point-in-time recovery.** This is named as a
consequence rather than buried in a cost line because it is a real reduction in recoverability
and the owner accepted it knowingly.

- Supabase **PITR is a ~$100/month add-on per 7 days of retention** — on its own it more than
  doubles the bill and puts it outside the approved £50/month ceiling. It is therefore **not
  purchased**.
- The posture is consequently **daily backups with a 7-day retention window, not point-in-time
  recovery**. The practical meaning is a **recovery point objective of up to 24 hours** on the
  server copy, against **AWS RDS's 35-day PITR, which would have been within budget**. That is a
  genuine advantage of the runner-up and this ADR does not pretend otherwise.
- **Structural mitigation — the server is not the sole copy of anything recent.** The app is
  offline-first by construction (ADR-0002, ADR-0003): every client device holds a durable **GRDB
  copy of its own recent data**, and the **outbox preserves unsynced mutations locally** until
  they are acknowledged. A server-side loss of the last few hours is therefore a
  *reconciliation* problem across devices that still hold the data, not an unconditional data
  loss. This mitigation is real but **partial** — it does not cover data whose only copy was
  server-side (server-assigned versions, relationship state changes, anything a device has
  already pruned), and it degrades for a client who has since deleted the app.
- **Regardless of provider we must run our own scheduled `pg_dump` to separate storage and
  actually test-restore it** — UK GDPR Art. 32 makes the ability to restore availability in a
  timely manner an explicit obligation, and a backup never restored is not a backup. With PITR
  not purchased, this is the load-bearing control, not a supplement to one.
- **Revisit trigger:** if the RPO of up to 24 hours ever becomes unacceptable — real client
  volume, or a near-miss — PITR (or the AWS re-evaluation) returns as a budget question.

**If a Phase 0 gate fails, or integration is deferred:** nothing breaks. The app continues to
ship contracts + a DEBUG fake with honest UI, exactly as ADR-0012 designed. Selecting a provider
committed no money and created no account; the cost so far is the evaluation effort, not a
commitment. A failed gate returns the question to this ADR's switch conditions — most likely to
the AWS re-evaluation — rather than stalling the product.

## Consent and data-protection model (Phase 0 / cross-cutting)

The owner has decided that the workout, discomfort and check-in data is **special category data
under UK GDPR Art. 9**, with the lawful basis assumed to be **explicit consent, Art. 9(2)(a)**.
That decision is a design input, not a paperwork exercise. **Design as special category data;
never as ordinary personal data.** The solicitor confirmation is Phase 0 gate 4.

**What Art. 9(2)(a) requires of the design:**

- **Granular, unbundled consent per purpose.** Consent to be coached is not consent to analytics,
  and neither is consent to model inference. A single "I agree" covering several purposes is not
  valid explicit consent. This extends — it does not replace — the existing **per-coach
  per-category consent** rule in `CLAUDE.md` ("Privacy") and in
  `handoff/functional-rules.md`: that rule governs *what a given coach may see*; Art. 9(2)(a)
  additionally governs *whether we may process the category at all, and for which purpose*. Both
  must hold simultaneously.
- **A consent-record table** — the evidential core, since under Art. 7(1) the controller must be
  able to *demonstrate* consent. Minimum fields:

  | Field | Purpose |
  |---|---|
  | `granted_at` (timestamp) | when consent was given |
  | `notice_version` | which privacy notice / wording was shown — consent is to a specific text, so the text must be versioned and retained |
  | `purposes` | the specific purposes consented to, granularly — not a boolean |
  | `withdrawal_state` (+ `withdrawn_at`) | current state and when it changed |

  Consent records are **append-only history, never overwritten in place** — a withdrawal must not
  erase the evidence that consent previously existed, or we lose the ability to demonstrate the
  lawfulness of past processing.
- **A functioning withdrawal path.** Art. 7(3) requires withdrawal to be *as easy as* giving
  consent. It must be reachable in the app, not by emailing support, and it must actually stop
  future processing for the withdrawn purpose.

### Open question for the solicitor — with a direct design consequence

**Art. 9(2)(a) consent is withdrawable at will. Two existing product rules assume data survives
that withdrawal.** `CLAUDE.md` states that **deletion ≠ cancellation** and that **turning sharing
off stops future sharing but never deletes past content**. If **consent is the sole lawful
basis**, then withdrawing it removes the grounds for continuing to hold training history — history
a coach may need to retain for **professional or liability reasons**. These cannot both be
unconditionally true.

The question to put to the solicitor: **does Art. 9(2)(h)** (health/social care and the
management of health care systems, subject to the professional-secrecy condition) **or a separate
retention basis cover historical training records after consent for ongoing processing is
withdrawn** — and if so, for which records and for how long?

**Consequence, stated plainly: the withdrawal path's behaviour on *existing* data cannot be
finalised until this is answered.** Building the withdrawal path so that it stops future
processing is safe and can proceed on the current answer. Deciding whether withdrawal also
deletes, anonymises, or merely restricts historical records is **blocked**, and must not be
guessed at in code. Whatever is decided must be reflected in the retention periods still open at
OQ-8, and in the product copy — a withdrawal control that implies deletion while retaining data
would be a false statement to the client.

## Usage alerting, not a hard cap

The budget approval is **up to £50/month with alerting**, and it is explicitly **not** a hard
spend cap. The reason is recorded because it will look like an oversight to someone later:
**a spend cap converts a billing event into an outage.** When the cap trips, the provider stops
serving requests — a `402`/`403` at the API boundary — and paying clients lose their coach's
service at the moment the product is most in demand. The failure mode is the familiar
free-tier/quota-exhaustion behaviour of hosted platforms (Firebase's Spark plan being the
commonly cited example; **note that specific precedent is not itself recorded in
`backend-provider-evaluation.md`, so it is cited here as general platform behaviour rather than
as a verified finding of ours**). Degrading paying clients' service to protect a £50 budget is
the wrong trade, and would also strain the app's honesty rules — the UI has no truthful way to
explain a billing-induced sync failure to a client, and "sync is unavailable" while the coach is
mid-programme is exactly the kind of silent-failure surface ADR-0003 exists to prevent.

Required instead, configured before any real data flows:

| Threshold | Action |
|---|---|
| **60% of the £50/month ceiling** (~£30) | Informational alert to the owner — expected to fire routinely once Pro + compute is running; its job is to confirm alerting works and to make the baseline visible. |
| **85% of the ceiling** (~£42.50) | Actionable alert — investigate before month end. |
| **100% of the ceiling** | Alert, **not** a cut-off. Service continues; the overspend is a decision for the owner, not for the platform. |
| **Any new billable line item appearing** | Alert regardless of amount — this is the one that catches a feature silently enabling a metered service, which is how small bills become large ones. |

Alerting must reach the owner **outside the app** (email/provider notification), since a sync
outage is precisely when in-app delivery cannot be relied on. Egress and storage are the meters
most likely to move unexpectedly once the media slice lands; media has its own ~$5/month baseline
and should be alerted separately so the two budgets do not mask each other.

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

None of these can be closed by engineering. They no longer block the **provider selection**,
which is accepted — they block **integration**, via the Phase 0 gates.

**Four are now closed** by the sign-off record above (OQ-1, OQ-3, OQ-4, OQ-5). They are kept in
the table with their answers rather than deleted, because the reasoning in this ADR depends on
those answers and a future reader must be able to see what was assumed.

| ID | Question | Owner | Status |
|---|---|---|---|
| OQ-1 | Does the DPIA/procurement position require a SOC 2 or ISO 27001 **report** and a contractual **SLA**? | Legal + owner | **CLOSED — NO.** No client has requested such evidence; none expected within 12 months. Note the corrected premise: **Supabase holds SOC 2 Type II and ISO 27001; Team (~$599/mo) gates *report/certificate access* and the SLA.** A future "yes" therefore triggers an **AWS vs Supabase Team comparison**, not an automatic switch. Reopens on the primary switch condition. |
| OQ-3 | Is the workout, discomfort and check-in data **special-category health data** under UK GDPR Art. 9? | Legal (R-05) | **CLOSED — YES**, treat as special category. Basis assumed **Art. 9(2)(a) explicit consent**; **DPIA now required**. See "Consent and data-protection model". **Solicitor confirmation outstanding (Phase 0 gate 4)**, including the Art. 9(2)(h) retention question. |
| OQ-4 | Is UK residency required, preferred, or merely nice to have? | Legal (R-05) | **CLOSED — not legally required.** UK GDPR has no localisation mandate. **London chosen as a commercial and simplicity decision** (it is free). Recorded explicitly: this does **not** eliminate **vendor support access from the US**, and the **UK Addendum / IDTA must be confirmed present in the DPA document body** (Phase 0 gate 1) — region selection is not a transfer mechanism. |
| OQ-5 | Approve the recurring cost. | Owner | **CLOSED — approved up to £50/month with usage alerting; no hard spend cap.** Consequence: **PITR (~$100/mo) is not purchased** — daily backups with 7-day retention instead. |
| OQ-2 | Can a Supabase **Pro**-tier customer execute the signed DPA? The DPA (v. 2025-03-14) is strong — EU SCCs plus the **ICO Approved Addendum B.1.0**, UK GDPR/DPA 2018 named, and a clause 7.2 commitment that region-directed data is *"stored and primarily Processed in that region"* — and the DPA page documents **no** plan restriction. But that is inferred from silence. A "no" is disqualifying. Also review clause 7.1's broader default and the word *"primarily"*. **Phase 0 gate 1** additionally requires the **UK Addendum to be verified in the document body**. | Legal + owner | **OPEN — blocking** |
| OQ-2b | Supabase publishes **no public subprocessor page** (`/legal/subprocessors` returns 404); the list is **Schedule 3 of the DPA PDF** and the objection window is only **5 days**. Decide whether that transparency posture is acceptable and how changes will be monitored. | Legal + owner | **OPEN** — now sharper, since Schedule 3 lists **OpenAI** and the data is Art. 9 (see OQ-6). |
| OQ-6 | Review subprocessor lists before any data flows. **Fly.io lists Anthropic and OpenAI; Bunny.net lists OpenAI**, and Supabase's own Schedule 3 lists OpenAI. If any is in the final stack, exactly what customer data can reach those subprocessors must be established and answerable in a coach's due-diligence questionnaire. | Legal + owner | **OPEN — escalated.** Now an Art. 9 question, and the input to the **AI/model data-flow map** (Phase 0 deliverable). |
| OQ-7 | **DL-07 interaction.** A backend does not discharge at-rest encryption on device. Decide SQLCipher vs iOS Data Protection **independently**, and note the account database now holds a coach's whole client roster. | Eng lead + legal | **OPEN — escalated.** Art. 9 data raises the bar for the Art. 32 "appropriate measures" argument on device. |
| OQ-8 | Retention and deletion periods (DL-01, R-05) must be fixed before the provider holds real data, because **deletion ≠ cancellation** is a product rule the server must enforce. | Legal | **OPEN — now coupled to OQ-10.** Retention periods cannot be fixed before the consent-withdrawal/retention basis is settled. |
| OQ-9 | Confirm the **UNVERIFIED** items in `backend-provider-evaluation.md` §5 that bear on cost or compliance — at minimum U-2, U-3, U-7. (U-1 is now answered: certification is held; Team gates report access and the SLA.) | Owner | **OPEN** |
| OQ-10 | **New — for the solicitor, with a direct design consequence.** Art. 9(2)(a) consent is withdrawable at will, but **deletion ≠ cancellation** and **sharing off never deletes past content**. If consent is the sole basis, withdrawal removes the grounds for retaining training history a coach may need for professional/liability reasons. Does **Art. 9(2)(h)** or a separate retention basis cover historical records, for which records and for how long? | Legal (solicitor) | **OPEN — blocking the withdrawal path's behaviour on existing data.** See "Consent and data-protection model". |

## Phased integration plan — for the milestone AFTER the Phase 0 gates close

Nothing below happens in this milestone. Provider selection being accepted does **not** start
Phase 1; the Phase 0 gates do. Each phase is separately reviewable and each preserves the honesty
rules.

**Phase 0 — sign-off and data-protection groundwork (no code).** Partially done: OQ-1, OQ-3,
OQ-4 and OQ-5 are closed and the provider is selected. What remains in Phase 0 is the work that
**gates integration**. No Phase 1 work starts until every item here is complete.

| # | Deliverable | Why it gates |
|---|---|---|
| 0.1 | **DPA executed**, with the **UK Addendum / IDTA verified in the document body** — not inferred, not merely referenced (OQ-2, OQ-2b). | London region selection is a commercial choice, **not** a transfer mechanism, and it does not eliminate **vendor support access from the US**. Without a verified Addendum there is no lawful transfer basis for the support-access path. |
| 0.2 | **DPIA completed.** | Art. 35 — large-scale processing of special category data. Now that Art. 9 is confirmed, this is required in practice rather than "very likely". It must cover the residency position, the subprocessor list, the backups/PITR posture, and the AI question below. |
| 0.3 | **ICO registration** completed and the **data protection fee** paid. | A statutory obligation for a UK controller processing personal data; it is not contingent on anything else here and should be done first as it is the cheapest and most easily forgotten item. |
| 0.4 | **AI / model API data-flow map.** | See below — a live concern, not a precaution. |
| 0.5 | **Solicitor confirmation of the Art. 9(2)(a) basis**, including OQ-10 (retention after withdrawal). | Phase 0 gate 4. The withdrawal path's behaviour on existing data cannot be built before this. |
| 0.6 | **Usage alerting configured** at the thresholds above, before any real data or real traffic. | The budget approval was conditional on it. |
| 0.7 | Record the decision in the risk register: resolve **R-01/R-02** and move **DL-11** to a decision. | Housekeeping, but these have been open since the register was written. |

**On 0.4 — the AI/model data-flow map is a live concern, not a precaution.** Two facts make it
so. First, the **product roadmap already includes AI-drafted check-in responses, follow-ups and
programme drafts** (`CLAUDE.md`, "AI") — all three process client health data by definition, so
this is not hypothetical future functionality. Second, the evaluation established that
**Fly.io lists Anthropic and OpenAI as subprocessors, and Bunny.net lists OpenAI**; Supabase's
own Schedule 3 lists OpenAI as well. The combination means model vendors could end up in the data
path either deliberately (our own AI features) or incidentally (a subprocessor of a chosen
vendor).

The map must therefore answer one question explicitly and in writing: **does Article 9 data ever
leave the estate for model inference — and if so, which fields, to which processor, under what
contract, and with which consent purpose?** "We haven't built it yet" is not an answer; the
decision is required *now* because it constrains the consent wording (a granular purpose cannot
be added retroactively to consent already collected) and the subprocessor position.

**That decision must be recorded in the ROPA and in the DPIA**, not only in this ADR. If the
answer is "no", it should be recorded as a *constraint on future development* — meaning the AI
features are designed against de-identified or coach-authored input — rather than as a passive
observation that will quietly lapse the first time someone wires an inference call.

**Phase 1 — server contract, still no client change.** Implement the server side of
`SyncContracts.swift` against a staging project: the idempotency table with its unique key and
stored canonical result (B-1/B-2), partial batch ack (B-3), typed rejection (B-4),
**per-account serialized** monotonic version assignment (B-5), the change feed with tombstones and
pagination (C-1…C-6), rate limiting with retry-after (B-6), and the revocation store (A-3/A-4).
Verify it against the **same expectations `FakeSyncBackend` already encodes** — the fake is the
executable spec. Binding conditions **BC-1…BC-11** below apply from this phase onward.
`SYNC_BASE_URL` stays empty; the app is untouched.

Three tests are gating for this phase and are named here so they cannot be quietly dropped: the
**concurrent-commit** version test (BC-6), the **mixed-batch partial-ack** conformance test
(BC-7), and the **cursor-replay-under-another-JWT** test (BC-9).

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
endpoint**. The mapping is explicit and must be implemented exactly this way:

- the query runs and **returns no session row → `revoked`**;
- the query **fails or times out → `.unknown`**.

It must **never** be implemented as "any non-row result = unknown" (which would silently downgrade
a genuine revocation), nor as "any non-row result = revoked" (which would sign users out on a
transient database error, violating ADR-0008's rule that `.unknown` is never inferred as revoked).
The same per-request session-existence check is embedded in **every sync RPC**, not only in
`checkRevocation`. Set the access-token expiry short (the documented 5-minute floor) to bound the window
in which an already-issued token still validates; use **asymmetric signing keys with the JWKS
endpoint** so validation needs no network call, and never the legacy HS256 shared secret. Role
claims are issued server-side via the **Custom Access Token Hook** and live in **`app_metadata`
only** — `user_metadata` is self-writable through the update-user endpoint and must **never**
carry role (BC-4). Relationship `status = 'active'` is **checked at query time and never cached in
a claim**; the client keeps routing only from `SessionClaims.routableRole`. Adopt the **new
API-key format from day one** — the legacy JWT-based
keys are documented as deprecated by the end of 2026, and the replacement keys must be sent in the
`apikey` header, not as `Authorization: Bearer`. `UnavailableAuthProvider` remains the Release
fallback until this is signed off. **"Sign out everywhere" is only claimed once global
refresh-token revocation is genuinely wired and tested** — until then the honest-limitation copy
stays (A-10), because an access token issued before revocation still verifies until it expires.

**Phase 4 — relationship authorization (the milestone's real prize).** Move the `relationship`
lifecycle from advisory-local to server-enforced: RLS policies plus function-level checks so a
coach may only write assignments for clients they have an **active** relationship with, and no
account can read another's state. The account is derived from **`auth.uid()`** throughout, never
from the request body (BC-1); every `SECURITY DEFINER` function performs its own explicit
relationship check and owned tables carry `FORCE ROW LEVEL SECURITY` (BC-2); cursor tokens are
never capabilities (BC-9). Denials return `PermanentRejection.forbidden` /
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

## Binding conditions on the integration milestone

A security review of this ADR (2026-07-29) independently concurred with the recommendation —
Supabase, London, used narrowly — but found two factual overstatements in the original draft (the
`merge-duplicates` idempotency claim and the sequence-monotonicity claim), both corrected above.
The reviewer's framing is worth recording verbatim in substance: **the binding risk in the
Supabase path is not the vendor but the plpgsql-only server** — and that is precisely where both
corrected flaws lived. Nothing about Postgres, London or the narrow-usage posture caused them;
hand-writing transactional sync semantics in plpgsql did.

The following conditions are **binding** on Phases 1–5. They are not aspirations; a phase is not
done while one is open.

| ID | Condition |
|---|---|
| **BC-1** | **Account derives from `auth.uid()` everywhere.** The client-supplied `MutationEnvelope.accountContext` / `PushMutationBatch.accountContext` (`SyncContracts.swift:101,146`) is **verified and rejected on mismatch**, never trusted. `PullChangesResponse.accountContext` (`:248-249`) echoes the **JWT-derived** value, never the request-supplied one. |
| **BC-2** | **`SECURITY DEFINER` is not a bypass.** Every `SECURITY DEFINER` function performs its own explicit `auth.uid()`-derived relationship check, and owned tables carry **`FORCE ROW LEVEL SECURITY`** — without it RLS does not apply to the definer/owner. |
| **BC-3** | **RPC is the only sync surface.** `authenticated` grants are revoked on all sync tables (or the tables are kept out of the exposed schema). The service/secret key exists **only in migration and ops tooling** — never in the app, never in any `.xcconfig`, never in client-reachable config. |
| **BC-4** | **Role claims live in `app_metadata`**, issued by the Custom Access Token Hook only. `user_metadata` is self-writable via the update-user endpoint and must never carry role. Relationship `status = 'active'` is checked **at query time**, never cached in a claim — this document makes exactly that criticism of Firebase custom claims, and it applies with equal force to our own design. |
| **BC-5** | **Idempotency uniqueness is `(account_id, idempotency_key)`** with `account_id` derived from `auth.uid()`. A global unique constraint on the client-minted UUID alone would let a replay lookup return **another account's** canonical result, or let a hostile client poison a key before its legitimate owner uses it. |
| **BC-6** | **Per-account serialized `server_version` assignment** so assignment order equals commit order (see the Recommendation section), plus a **concurrent-commit test** proving no version can commit behind an already-observed cursor. |
| **BC-7** | **Partial acks require per-mutation subtransactions.** A single function transaction that raises on mutation *k* rolls back 1…*k*−1 — that is all-or-nothing and violates the partial-ack contract (`SyncContracts.swift:184-187`). Each mutation runs in its own `BEGIN … EXCEPTION` savepoint block per loop iteration. A **mixed-batch conformance test** (applied + duplicate + rejected + retryable in one batch) is required. |
| **BC-8** | **Revocation mapping is explicit** — absent session row → `revoked`; query failure/timeout → `.unknown`. The per-request session-existence check is embedded in **every sync RPC**, not only in `checkRevocation`; otherwise a revoked token retains a server-side write window that a malicious client can exploit for the remainder of its `exp`. |
| **BC-9** | **A cursor token is never a capability.** The pull function filters strictly by the authenticated subject's relationship graph, so replaying Account A's `nextCursorToken` under Account B's JWT yields only B-visible rows. This is tested explicitly, not assumed. |
| **BC-10** | **Identifiers never travel in URLs.** Sync RPCs use **POST bodies only** — never PostgREST GET filters carrying identifiers, because request logs capture URLs (this is what satisfies the no-personal-data-in-URLs rule). **Exports** are served through the same grant-checking edge as media, **never presigned URLs** — otherwise the "revocable" claim weakens for exports specifically. |
| **BC-11** | **Named tripwire.** If the Phase 1 plpgsql implementation cannot pass the `FakeSyncBackend`-derived conformance tests for **partial acks** and **cursor monotonicity** within that phase, **escalate to a thin compute tier** — Edge Function orchestration, or a small Swift service importing `SyncContracts` directly (ADR-0001 keeps `MazidiKit` Linux-buildable) — **rather than weakening the contract**. The contract does not move. |

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
