# Backend provider evaluation

Companion to `backend-provider-requirements.md`. Scores candidate providers against that
matrix and feeds ADR-0013 (**Proposed**).

**All web facts were checked on 2026-07-29.** Pricing and feature sets move; every claim
below carries a source URL and anything that could not be confirmed from a primary source is
marked **UNVERIFIED** rather than asserted. Nothing here was tested against a live account —
**no account was created, nothing was deployed, no cost was incurred.**

---

## 0. The finding that reframes the whole evaluation

Three facts, established during research, change what "choosing a provider" even means:

1. **No provider offers revocation-aware JWT validation.** Amazon Cognito's own documentation
   states that revoked tokens *"will still be valid if they are verified using any JWT library
   that verifies the signature and expiration of the token"*
   ([docs.aws.amazon.com](https://docs.aws.amazon.com/cognito/latest/developerguide/token-revocation.html),
   2026-07-29). Supabase documents the same shape: an access token cannot be revoked before it
   expires, and the mitigation is a short JWT expiry
   ([supabase.com/docs/guides/auth/sessions](https://supabase.com/docs/guides/auth/sessions),
   2026-07-29). No token-introspection endpoint was found for Auth0 access tokens
   (**UNVERIFIED** that none exists). Requirement **A-3** — an explicit
   `active` / `revoked` / **`unknown`** answer — therefore **cannot be delegated to any
   identity provider.** It must be served by a revocation store we own, checked server-side per
   request, with `.unknown` meaning "the revocation store was unreachable". That is exactly the
   semantic `RevocationCheck` already encodes (`MazidiAuth/AuthProviding.swift:66-72`).

2. **Every candidate requires us to write the server logic anyway.** At-most-once idempotency
   returning a canonical result (B-1/B-2), partial batch acks keyed by mutation id (B-3),
   monotonic server versions (B-5), a cursored change feed with tombstones (C-1…C-6), and
   relationship authorization (D-1) are not features any BaaS ships. So the choice is not
   "buy a backend" — it is **"where do we run the small server we must write, and who supplies
   the database, the identity provider and the object store around it."**

3. **"Revocable URLs" cannot mean "recallable after issue."** Neither S3 presigned URLs, nor
   CloudFront signed URLs, nor R2 presigned URLs, nor Bunny tokens support per-URL revocation.
   CloudFront revocation means removing a public key from a key group — a mass invalidation
   that AWS's own rotation guidance is designed to *avoid*
   ([docs.aws.amazon.com](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-trusted-signers.html),
   2026-07-29). The only evaluated design giving genuine per-grant revocation is an
   **authorising edge check** — a Cloudflare Worker in front of R2 that validates a grant id
   against a revocation source on every request. The achievable, honest semantic elsewhere is
   *authorised at issue + short TTL + break-glass key rotation*.

Point 3 is a **wording correction for our own documents** (ARCHITECTURE.md §4 and
`docs/` copy), not for `design/handoff-current/`, which is a frozen baseline and is not edited.

---

## 1. Scoring method and weights

Each candidate is scored **0–5** per criterion. Weights sum to 100 and were fixed **before**
scoring. Score = Σ(weight × score), max 500, expressed as a percentage.

| # | Criterion | Weight | Why this weight |
|---|---|---|---|
| W1 | **Contract fidelity** — can it satisfy B-1…B-10 and C-1…C-10 | 20 | These are already-shipped client semantics (ADR-0003, ADR-0012). Weakening them is not an option. |
| W2 | **Server-enforced authorization** — D-1…D-8 | 18 | The single biggest thing a backend must add; today advisory-only on device. |
| W3 | **Data protection** — F-1…F-8 | 18 | Personal health data about named individuals. Highest-consequence dimension. |
| W4 | **Architectural fit** — H-1…H-8 | 15 | A bad fit means rewriting merged, tested architecture. |
| W5 | **Auth capability** — A-1…A-13 | 12 | Important, but levelled by finding §0.1: nobody solves revocation for us. |
| W6 | **Operational** — backups/PITR, observability, maturity, SLA | 8 | Data loss is risk K-01. |
| W7 | **Cost & predictability** at S0/S1 | 5 | At this scale every option is cheap; differences are noise against one hour of engineering time. |
| W8 | **Exit / lock-in** | 4 | Real but recoverable, and partly mitigated by the provider-neutral contracts already in place. |

**Deliberately low weights are a judgement call, and W6/W7 being low is the most contestable
choice in this document** — see the sensitivity analysis in §4.

---

## 2. Candidates

Seven stacks, because "provider" is not one product:

| Key | Stack |
|---|---|
| **S** | **Supabase** (London `eu-west-2`) — managed Postgres + GoTrue auth + RLS + Storage; our sync endpoints as Postgres functions over PostgREST RPC / Edge Functions; **no Supabase SDK in the app** |
| **A** | **AWS** (`eu-west-2`) — API Gateway + Lambda + RDS Postgres + Cognito + S3/CloudFront |
| **F** | **Firebase** — Firestore + Firebase Auth |
| **C** | **CloudKit** |
| **Y** | **Custom Swift/Node service on Fly.io `lhr`** + Fly Managed Postgres `lhr` + R2-behind-a-Worker, paired with an identity provider |
| **H** | **Custom service on Hetzner** (self-managed VPS + self-managed Postgres) + Bunny/R2 |
| **0** | **Auth0** — evaluated as an *auth component* for Y/H, not as a stack |

---

## 3. Candidate-by-candidate findings

### S — Supabase (London)

**Verified.** London `eu-west-2` is a selectable region alongside 16 other AWS regions
([supabase.com/docs/guides/platform/regions](https://supabase.com/docs/guides/platform/regions),
2026-07-29). Plans: Free $0 (500 MB DB, 5 GB egress, **projects paused after 1 week of
inactivity** — unusable for production), **Pro $25/mo** (8 GB DB, 100k MAU, 100 GB storage,
250 GB egress, then $0.09/GB), Team $599/mo, Enterprise custom
([supabase.com/pricing](https://supabase.com/pricing), 2026-07-29). Compute add-ons: Micro $10,
Small $15, Medium $60 — a realistic production config is **Pro $25 + Small $15 ≈ $40/mo**.
Backups: **none on Free, 7 days on Pro, 14 on Team**; **PITR is a paid add-on at ~$100/month per
7 days of retention** ([supabase.com/docs/guides/platform/backups](https://supabase.com/docs/guides/platform/backups),
2026-07-29).

Auth (GoTrue): access-token expiry is configurable (default 1 hour; docs advise not above 1 hour
and not below 5 minutes); refresh tokens are **single-use with a 10-second reuse window**, and
reuse outside that window **terminates the session and revokes its tokens**; custom claims come
from a **Custom Access Token Hook**; `signOut` defaults to **`scope: 'global'`**, revoking every
refresh token for the user — a genuine "sign out everywhere" for refresh tokens
([supabase.com/docs/guides/auth/sessions](https://supabase.com/docs/guides/auth/sessions),
[supabase.com/docs/reference/javascript/auth-signout](https://supabase.com/docs/reference/javascript/auth-signout),
2026-07-29). **Time-boxed sessions, inactivity timeout and single-session-per-user are Pro-plan
and above.** An access token still cannot be revoked before `exp` (finding §0.1).

REST-only usage is fully supported: PostgREST at
`https://<ref>.supabase.co/rest/v1/`, RPC at `/rest/v1/rpc/<fn>` for Postgres functions, GoTrue at
`/auth/v1/…` and Storage at `/storage/v1/…`, authenticated with `apikey` +
`Authorization: Bearer <jwt>` headers
([supabase.com/docs/guides/api](https://supabase.com/docs/guides/api), 2026-07-29).
**No `supabase-swift` dependency is required**, so H-2/H-3/H-4 hold and `MazidiKit` stays
Foundation-only.

**Correction (security review, 2026-07-29): PostgREST's upsert does *not* satisfy B-1/B-2.**
An earlier draft of this document claimed that stock PostgREST's
`Prefer: resolution=merge-duplicates` with `?on_conflict=<unique_col>`
([docs.postgrest.org](https://docs.postgrest.org/en/stable/references/api/tables_views.html),
2026-07-29) "maps almost exactly onto" the idempotency contract. It does not:

- `merge-duplicates` is an **UPSERT**. On key replay it **UPDATES** the existing row with the
  retry's payload — it re-applies the mutation, which is last-write-wins on the idempotency row.
  ADR-0012 requires the opposite: a replay must return the **untouched stored canonical result**.
- The alternative one-statement formulation is not implementable either. `ON CONFLICT DO NOTHING
  … RETURNING` **returns no row on conflict**, so the replay path has nothing to return.

The correct pattern is two-step, inside one transaction, in a Postgres function:

1. **First apply** — insert the idempotency row and store the outcome (the assigned
   `server_version` and the result class) alongside the applied mutation.
2. **Replay** — the insert conflicts; the function then **`SELECT`s the stored canonical result**
   and returns `duplicateApplied(storedVersion)`
   (`MazidiNetworking/SyncContracts.swift:177`). Nothing is re-applied and nothing is overwritten.

**Prohibition:** no sync write may be routed through a PostgREST table upsert. Sync writes go
through RPC functions only.

**Caveat on the REST surface.** The Auth REST reference is published under *"Self-Hosting → Auth
Server"* rather than as a first-class platform API, and the individual endpoint pages are thin
(e.g. the `/logout` page documents the 204 response but not the `scope` parameter or what is
actually revoked). **No published stability, versioning or deprecation policy for `/auth/v1` was
found — UNVERIFIED.** The practical reassurance is the `v1` prefix and the fact that all
first-party SDKs are thin wrappers over the same endpoints.

**Exit hatch is real.** The stack is **Apache License 2.0** and fully self-hostable via Docker
Compose, and the wire protocol is identical self-hosted. Supabase documents what is missing when
self-hosted: *"Branching, advanced metrics beyond logs, managed backups and PITR, analytics and
vector buckets, ETL, and the platform management API are unavailable"*
([supabase.com/docs/guides/self-hosting](https://supabase.com/docs/guides/self-hosting),
2026-07-29).

**DPA:** available, but **not automatic** — Supabase prepares a DPA that you request from the
dashboard's legal-documents page and **sign via PandaDoc**
([supabase.com/legal/dpa](https://supabase.com/legal/dpa), 2026-07-29). The DPA text itself
(version dated **14 March 2025**) is strong for a UK controller: it incorporates the **EU SCCs**
(Decision 2021/914) and an explicit **UK Addendum using the ICO's Approved Addendum template
version B.1.0**, defines "UK Data Protection Laws" as UK GDPR + DPA 2018, and commits at clause
7.2 that data directed to a region *"shall be stored and primarily Processed in that region"* —
note **"primarily"**, and note clause 7.1's broader default. Encryption schedule: AES-256 at rest
including backups, per-project keys, TLS in transit. **The DPA page documents no plan
restriction**, which materially reduces (but does not close) the risk that a Pro-tier customer
cannot execute it.

Two real weaknesses on this axis. **There is no public subprocessor page** —
`supabase.com/legal/subprocessors` returns **404**; the authoritative list is **Schedule 3 of the
DPA PDF** (AWS, Cloudflare, Google, Fly.io, Upstash, Vercel, Sentry, OpenAI, PandaDoc and others),
with 30 days' change notice but only a **5-day objection window**. Diffing a PDF is a materially
worse transparency posture than a maintained page. And the pricing page lists "SOC2 & ISO 27001"
as a **Team-plan ($599/mo)** line item with **uptime SLAs Enterprise-only** — *the exact meaning
of that gating (report access versus certification scope) is **UNVERIFIED** and is a procurement
question, not an engineering one.*

**Revocation, precisely.** Supabase has **no revocation-status endpoint**. The documented
technique is to check whether the token's `session_id` claim still exists in the `auth.sessions`
table — a database query, and therefore usable directly inside an RLS policy or one of our own
Postgres functions. That is a workable basis for requirement A-3, with `.unknown` meaning the
query failed. Token validation itself needs no network call: asymmetric signing keys (**ES256** /
**RS256**) are published at a JWKS endpoint with zero-downtime rotation
([supabase.com/docs/guides/auth/signing-keys](https://supabase.com/docs/guides/auth/signing-keys),
2026-07-29); the legacy HS256 shared secret is documented as *"No longer recommended."*

**Operational note with a deadline.** The legacy JWT-based `anon` / `service_role` keys **will be
deprecated by the end of 2026**, replaced by `sb_publishable_…` / `sb_secret_…` keys sent in the
`apikey` header (they cannot be sent as `Authorization: Bearer`)
([supabase.com/docs/guides/api/api-keys](https://supabase.com/docs/guides/api/api-keys),
2026-07-29). Any integration must adopt the new format from day one.

**Uptime, honestly.** No SLA below Enterprise (99.9% there). The public status page reports 90-day
uptime of 100.0% for API Gateway and Compute and 99.99% for Auth and Storage, but a high cadence
of low-severity **control-plane** incidents — roughly 11 resolved in the two weeks to 2026-07-28,
including a Frankfurt regional issue on 2026-07-16 (status.supabase.com, 2026-07-29).

**Storage is the weak spot.** Supabase signed URLs are signed with a dedicated internal key
separate from the Auth JWT key, so they **remain valid until expiry regardless of key changes**,
and immediate revocation requires **contacting Supabase support**. The docs also note the high
CDN cache-hit ratio applies to **public** buckets — private-bucket serving is not described as
CDN-cached ([supabase.com/docs/guides/storage/serving/downloads](https://supabase.com/docs/guides/storage/serving/downloads),
2026-07-29). For a 206-clip library that must be private (E-3), expiring (E-3), revocable (E-4)
**and** poster-first CDN-cached (E-5), Supabase Storage fails E-4 and is questionable on E-5.
**Conclusion: use Supabase for data + auth, and decide the media origin separately.**

**Fit note.** The sync endpoints would be plpgsql functions — a unique index on
`(account_id, idempotency_key)` plus a **stored canonical result read back on conflict**, per the
correction above — or Deno Edge Functions. Writing a complete push/pull engine in plpgsql is
ergonomically awkward and is a genuine cost of this option. An earlier draft added "it is not a
correctness problem"; the security review disagrees, and so does this document now. **The binding
risk in the Supabase path is not the vendor but the plpgsql-only server**, and both factual
errors the review found in the original ADR draft (idempotency-on-upsert, and monotonicity from a
bare sequence) were plpgsql-implementation errors, not provider limitations. The binding
conditions and the named escalation tripwire are recorded in
`adr/ADR-0013-backend-provider-selection.md` §"Binding conditions".

### A — AWS (eu-west-2)

**Cognito pricing (verified,
[aws.amazon.com/cognito/pricing](https://aws.amazon.com/cognito/pricing/), 2026-07-29):** three
tiers — **Lite** $0.0055/MAU (first 90k above free), **Essentials** $0.015/MAU, **Plus**
$0.020/MAU. **10,000 MAU free per month on Lite and Essentials; no free tier on Plus.** At S1
(~1,550 MAU) Cognito is **£0**. **Refresh-token rotation is gated behind Essentials.**

**Revocation (verified,
[docs.aws.amazon.com](https://docs.aws.amazon.com/cognito/latest/developerguide/token-revocation.html),
2026-07-29):** `RevokeToken`, `/oauth2/revoke` (no client secret needed for public native
clients), `GlobalSignOut`, and `AdminUserGlobalSignOut` as a server-side kill switch; disabling a
user revokes tokens. Enabling revocation adds `jti`/`origin_jti` claims — **the hook our own
revocation store keys on.** This is the cleanest path to A-3/A-4 of any candidate, precisely
because it hands us the identifier rather than pretending to solve it.

**AppSync** is usable as a plain HTTPS GraphQL endpoint from `URLSession` with a Cognito JWT
(**partially UNVERIFIED** — inferred from endpoint/auth documentation rather than an explicit
"no SDK required" statement). **Amplify DataStore must be excluded**: it brings its own outbox,
its own `_lastSync` delta cursor, its own `_version`/`_deleted` metadata and fixed
AUTO_MERGE / OPTIMISTIC_CONCURRENCY resolution — a direct competitor to `MazidiSync` and a
blanket policy ADR-0003 forbids. **Aurora Serverless v2 does scale to zero** (min capacity 0,
GA since 2024-11-20) but **resume takes ~15 s, or 30 s+ after a day idle**, and **attaching RDS
Proxy prevents pausing** — a poor fit for a mobile sync endpoint
([docs.aws.amazon.com](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2-auto-pause.html),
2026-07-29). Plain RDS Postgres (up to **35-day PITR**) is the better fit and is the **strongest
backup story of any candidate**.

**Data protection is AWS's decisive advantage.** The DPA and the June-2021 EU SCCs are
**incorporated into the AWS Service Terms automatically — no signature, no sales call, no
enterprise plan** ([aws.amazon.com/compliance/gdpr-center](https://aws.amazon.com/compliance/gdpr-center/),
2026-07-29); subprocessors are published at
[aws.amazon.com/compliance/sub-processors](https://aws.amazon.com/compliance/sub-processors/).
For a solo/small developer that removes an entire procurement blocker.

**UNVERIFIED:** exact `eu-west-2` pricing for API Gateway, Lambda, DynamoDB, RDS and CloudFront
(AWS pricing pages are JS-rendered); and `eu-west-2` service availability should be confirmed
against the Regional Services List before committing.

**Cost:** likely **£5–35/month** at S1 excluding media egress — but across many meters.
**Ops burden is the highest of any candidate**: IaC, IAM, alarms, budget alerts, key rotation.

### F — Firebase

**The decisive finding is about residency, not architecture.** Firebase's own privacy page states
verbatim:

> *"The Firebase Authentication service is run only from US data centers. As a result, Firebase
> Authentication processes data exclusively in the United States."*
> ([firebase.google.com/support/privacy](https://firebase.google.com/support/privacy), 2026-07-29)

The same page lists the many Firebase services that *do* offer data-location selection —
Firestore, Cloud Storage, Cloud Functions, Remote Config and others. **Firebase Authentication is
not among them, and there is no region option.** So while Firestore data can sit in
`europe-west2` (London), every account identifier, email address, phone number and authentication
event for named personal-training clients would be processed in the US, permanently, relying on
DPF/SCC/IDTA transfer machinery. Against requirement **F-1** this is close to disqualifying on its
own, and it forecloses ever saying "personal data stays in the UK/EU".

**Two further structural problems:**

1. **Firestore's own offline layer is last-write-wins.** Firebase documents that for multiple
   changes to the same document, **it is last write wins**
   ([firebase.google.com/docs/firestore/manage-data/enable-offline](https://firebase.google.com/docs/firestore/manage-data/enable-offline),
   2026-07-29), and offline persistence is **enabled by default on Apple platforms**. ADR-0003
   and the ARCHITECTURE.md §5 conflict table forbid blanket last-write-wins, and `MazidiSync`
   already implements a deterministic per-class resolver. It *can* be disabled — but then
   listener re-billing worsens, and we would be paying for and working around a subsystem we do
   not want. Fails **C-10** as shipped.
2. **The authorization model fits badly.** Rules *can* express a relationship lookup via
   `get()`/`exists()` — the limits are **10 document-access calls for single-document and query
   requests, 20 for multi-document reads, transactions and batched writes**, not a hard ceiling of
   two. The problem is the economics and the freshness: those lookups **are billed as reads even
   when the rules deny the request**, and rule evaluation is re-charged when a client reconnects,
   when rules change, and when dependent documents change
   ([firebase.google.com/docs/firestore/security/rules-conditions](https://firebase.google.com/docs/firestore/security/rules-conditions)
   and the Security Rules section of
   [cloud.google.com/firestore/pricing](https://cloud.google.com/firestore/pricing), 2026-07-29).
   The alternative — denormalising the relationship into a custom claim — is capped at **1000
   bytes** and goes **stale until the next token refresh**, which is precisely wrong for "active
   relationship" semantics where revoking a coach's access must take effect promptly. Compare
   Supabase, where the same check is an `EXISTS` join inside the query plan: no extra billable
   unit, no call ceiling, always current. Weak on **D-4/D-5**.

Firebase does two things genuinely better. Auth is free to **50,000 MAU**, then $0.0055/MAU
(50k–100k) ([cloud.google.com/identity-platform/pricing](https://cloud.google.com/identity-platform/pricing),
2026-07-29). And unlike Supabase it **has an actual revocation-check API** —
`verifyIdToken(token, checkRevoked: true)` returns `auth/id-token-revoked`, at the cost of a
network round-trip per checked verification
([firebase.google.com/docs/auth/admin/manage-sessions](https://firebase.google.com/docs/auth/admin/manage-sessions),
2026-07-29). Firestore also carries a real SLA — **99.99% for regional locations including
London** on ordinary Blaze pay-as-you-go ([cloud.google.com/firestore/sla](https://cloud.google.com/firestore/sla),
2026-07-29) — against Supabase's Enterprise-only 99.9%. Firestore's location is **immutable after
provisioning**.

Note also the precedent: **Firebase Dynamic Links was shut down on 2025-08-25** after ~2 years'
notice ([firebase.google.com/support/dynamic-links-faq](https://firebase.google.com/support/dynamic-links-faq)).
No sunset signals were found for Firestore, Auth or Storage.

Firebase would be a reasonable choice for an app that had *not* already built its own sync engine
and did *not* hold UK health data. This one is both. **Not recommended.**

### C — CloudKit — structurally disqualified

Four independent disqualifiers, any one fatal:

1. **No per-record or per-user-pair authorization.** CloudKit security roles apply **only to the
   public database**, and permissions are granted **per role × per record type** (read / write /
   create) — never per record instance and never per user pair. Custom roles can be created;
   user records cannot. Changing security settings requires a production deployment, and
   deployed roles cannot be deleted. **"Coach X may write an assignment readable only by client
   Y" is not expressible.** `CKShare` is the only per-user primitive and requires the *owner* to
   initiate and the participant to *accept via a share URL* — an interactive out-of-band step per
   relationship, with no developer-visible audit trail (conflicting with ADR-0006). Fails
   **D-1/D-2/D-4/D-7**.
2. **No server-side logic of any kind.** There is nowhere to run monotonic version assignment,
   idempotency canonicalisation, conflict classification or role validation. The
   **Server-to-Server API reaches the public database only** — by design, developers cannot
   access users' private databases. Fails **B-1…B-5, C-2, A-5/A-6**.
3. **No residency guarantee and no confirmable processor DPA.** No CloudKit region selection was
   found (**UNVERIFIED** that none exists), and no Apple DPA under which Apple acts as the
   developer's processor could be confirmed (**UNVERIFIED**; the Program License Agreement is
   login-gated and was not accessed). Apple's position for private-database data is that it is
   the *user's* iCloud data — which does **not** remove our controller obligations. Fails
   **F-1/F-2/F-7**.
4. **GDPR export and erasure are structurally unmeetable.** Data we cannot read cannot be
   exported for a subject access request, and erasure cannot be verified. Fails **F-4/F-5**.

Additionally: Sign in with Apple token revocation exists
(`POST https://appleid.apple.com/auth/revoke`,
[developer.apple.com](https://developer.apple.com/support/offering-account-deletion-in-your-app/),
2026-07-29) but it revokes the **sign-in relationship, not access to data** — there is no
developer-controlled kill switch over a user's private database. CloudKit Web Services documentation
lives in Apple's **archive** ([developer.apple.com/library/archive/…](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/index.html),
2026-07-29; **no 2026 deprecation announcement found — UNVERIFIED**), and there is no Android
SDK, so any non-Apple client would require every user to hold an Apple ID. Sync also depends on
the end user's personal iCloud quota, a failure mode we cannot detect or remediate.

Its free pricing is irrelevant against the above.

### Y — Custom service on Fly.io `lhr` + Fly Managed Postgres + R2/Worker

**London everywhere.** Fly regions include `lhr`, and **Fly Managed Postgres (MPG) is available
in `lhr`** ([fly.io/docs/reference/regions](https://fly.io/docs/reference/regions/),
[fly.io/docs/mpg](https://fly.io/docs/mpg/), 2026-07-29). MPG plans: **Basic $38/mo**
(shared-2x/1 GB, HA, backups, pooling), Starter $72, Launch $282; storage $0.28/GB per 30 days.
Machines: `shared-cpu-1x` 256 MB ≈ **$2.02/mo**, `shared-cpu-2x` 1 GB ≈ $6.64/mo; EU/NA egress
$0.02/GB. **The free allowance is now legacy/deprecated** — new signups get a trial. Support is a
paid add-on from $29/mo. The **DPA is pre-signed by Fly and activated when the customer signs**,
and Fly publishes a **DPF commitment covering the UK Extension** (effective 2025-08-18).
**Fly's subprocessor list ([fly.io/legal/sub-processors](https://fly.io/legal/sub-processors/))
includes Anthropic and OpenAI for AI-assisted log analysis and support** — a hard read before
processing health data. **SOC 2 / ISO 27001 status: UNVERIFIED. MPG backup retention and PITR
window: not documented — UNVERIFIED**, which is a serious gap for health data.

**This option has one advantage no BaaS can match.** ADR-0001 makes `MazidiKit` Foundation-only
and buildable on Linux. A Swift server on Fly could **import `MazidiNetworking`'s
`SyncContracts` types directly**, eliminating an entire class of client/server envelope drift by
construction. That is a real, repo-grounded benefit — and a real scope increase.

**Media: R2 behind a Worker is the standout.** R2 storage $0.015/GB-month, Class A $4.50/M,
Class B $0.36/M, **egress free**, with a 10 GB / 1M Class A / 10M Class B free tier
([developers.cloudflare.com/r2/pricing](https://developers.cloudflare.com/r2/pricing/),
2026-07-29). The 206-clip library (~400 MB, ~309k reads/month at S1) sits inside the free tier;
the real cost is the **Workers Paid plan at ~$5/mo**. Presigned R2 URLs max out at **7 days** and
**cannot be revoked** ([developers.cloudflare.com/r2/api/s3/presigned-urls](https://developers.cloudflare.com/r2/api/s3/presigned-urls/),
2026-07-29) — but a **Worker in front of R2 validates a grant id against a revocation source on
every request**, which is the only evaluated design that genuinely satisfies **E-4**. Caveat:
R2 jurisdictional restrictions offer **`eu` and `fedramp` only — there is no UK jurisdiction**,
and jurisdiction cannot be changed after bucket creation.

**Weak spot: identity.** This stack must pair with an IdP. Rolling our own is not acceptable for
health data.

### H — Custom service on Hetzner + Bunny/R2

Cheapest by a wide margin and excellent on contracting — Hetzner is a **German Art. 28
processor**, the DPA is at [hetzner.com/AV/DPA_en.pdf](https://www.hetzner.com/AV/DPA_en.pdf) and
is executed by **ticking a checkbox in the customer account**, with subprocessors at
[hetzner.com/AV/subunternehmer.pdf](https://www.hetzner.com/AV/subunternehmer.pdf) (2026-07-29).
But: **Hetzner raised cloud prices on 2026-06-15** (CPX/CCX up ~2.4–2.7×; the ARM **CAX** line is
now the value play at €5.99–€10.49/mo)
([docs.hetzner.com](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/),
2026-07-29); **there is no UK location** (DE/FI/US/SG only); and **no Hetzner Cloud managed
Postgres could be found** (**strongly indicated but formally UNVERIFIED**). That means we own
Postgres installation, major-version upgrades, WAL archiving, PITR, restore drills, pooling,
failover, OS patching, TLS renewal and disk monitoring — for named clients' health data, with one
person able to restore the database at 2am. Included EU traffic of 20 TB/month at €1/TB overage
is the best media-egress economics available (**UNVERIFIED against Hetzner's own page**).

**Rejected on operational risk, not on cost or contracting.**

### 0 — Auth0 as an auth component

**Verified ([auth0.com/pricing](https://auth0.com/pricing), 2026-07-29):** Free covers **25,000
MAU**; B2C Essentials from **$35/mo at 500 MAU**; B2C Professional from **$240/mo at 500 MAU**;
pricing is **stepped, not linear** — usage between tiers bills at the next tier up. **A UK public
cloud region exists and is GA** ([auth0.com/blog](https://auth0.com/blog/the-uk-joins-existing-emea-regions-for-public-cloud-deployments/)),
selectable at tenant creation — a genuine differentiator for a UK health-data app. Region is
fixed at tenant creation. The Authentication API is a documented public REST API usable from
`URLSession` with Authorization Code + PKCE via `ASWebAuthenticationSession`; the revoke endpoint
works for public native clients without a client secret.

**Two unresolved blockers.** (a) Search evidence indicates Auth0 provides a DPA to **enterprise
customers**; **whether a Free or Essentials customer can execute a signed DPA is UNVERIFIED and
would be disqualifying if the answer is no.** (b) Dedicated **Refresh Token management endpoints
are Enterprise-only**, and no token-introspection endpoint for access tokens was found.
**Whether UK region selection is available on the Free plan is UNVERIFIED.**

---

## 4. Scores

Score 0–5 per criterion; weighted total out of 500.

| Criterion (weight) | **S** Supabase | **A** AWS | **F** Firebase | **C** CloudKit | **Y** Fly+MPG+R2 | **H** Hetzner |
|---|---|---|---|---|---|---|
| W1 Contract fidelity (20) | 5 | 5 | 2 | 0 | 5 | 5 |
| W2 Authorization (18) | 5 | 5 | 2 | 0 | 5 | 5 |
| W3 Data protection (18) | 3 | 5 | 2 | 0 | 3 | 3 |
| W4 Architectural fit (15) | 5 | 4 | 1 | 0 | 5 | 5 |
| W5 Auth capability (12) | 4 | 4 | 4 | 1 | 3 | 2 |
| W6 Operational (8) | 3 | 4 | 5 | 2 | 2 | 1 |
| W7 Cost (5) | 4 | 3 | 4 | 5 | 4 | 5 |
| W8 Exit / lock-in (4) | 5 | 3 | 1 | 0 | 5 | 5 |
| **Weighted total /500** | **431** | **447** | **239** | **53** | **411** | **396** |
| **Percentage** | **86.2%** | **89.4%** | **47.8%** | **10.6%** | **82.2%** | **79.2%** |

Firebase scores **2** on data protection despite Google's otherwise excellent DPA and compliance
posture, because **Firebase Authentication is US-only with no region option** — the identity data
of every named client would leave the UK/EU permanently. That single fact costs it 36 weighted
points and moves it from "poor fit" to "does not meet F-1".

### Reading the table honestly

- **AWS scores highest (89.4%).** Its entire lead over Supabase comes from **W3 (data
  protection, 5 vs 3)** and **W6 (operational, 4 vs 3)** — the automatically-incorporated DPA
  with SCCs, freely available compliance artifacts, published SLAs, and RDS's 35-day PITR. On
  every other criterion Supabase equals or beats it.
- **Firebase (47.8%) and CloudKit (10.6%) fail on requirements, not on price.** Firebase on
  US-only authentication plus a default last-write-wins offline layer; CloudKit on the absence of
  per-record authorization and of server-side logic entirely.
- **Sensitivity.** The AWS lead is 3.2 points, which is **inside the noise of my own weighting
  judgement**. Reading the Supabase DPA text (EU SCCs + the ICO Approved Addendum B.1.0 + a
  region commitment at clause 7.2, with no documented plan gate) makes a W3 score of 4 defensible
  already; add a 7-day backup window supplemented by our own nightly `pg_dump` to a second vendor
  and W6 moves 3→4, closing the gap to about one point. Conversely, if procurement requires a
  SOC 2 report or a contractual SLA, Supabase costs **$599/mo (Team)** and *still* has no SLA
  below Enterprise — and AWS wins outright. **The vendor choice therefore hinges on an input
  engineering does not own.** That is precisely why ADR-0013 is `Proposed`.
- **W6 and W7 at 8 and 5 are the most contestable weights here.** They understate *delivery
  risk* for a small team with no CI (R-09/DL-09) and a single Mac (R-08). That factor is argued
  explicitly in ADR-0013 rather than smuggled into the weights.

### Media is a separate decision

No candidate's bundled object store satisfies E-3 + E-4 + E-5 together. Supabase Storage private
buckets fail E-4 (revocation requires contacting support) and are not documented as CDN-cached.
S3/CloudFront and Bunny give revocation only by key rotation. **Cloudflare R2 behind a Worker is
the only design evaluated that gives per-grant revocation, and its egress is free.** Bunny.net is
the alternative if EU-entity contracting matters more than per-grant revocation — BunnyWay d.o.o.
is a **Slovenian (EU) entity**, so GDPR applies directly rather than via SCCs/IDTA, with **London
Edge Storage** available; note its subprocessor list includes OpenAI.

---

## 5. Facts that could NOT be verified

Recorded so they are not mistaken for settled. Each must be confirmed before the integration
milestone commits money or data.

| # | Unverified item |
|---|---|
| U-1 | Whether Supabase's "SOC2 & ISO 27001" Team-plan line item gates **report access** or **certification scope** — and what a DPIA actually requires here |
| U-2 | Whether a Supabase **Pro**-tier customer can execute the signed DPA. The DPA page documents **no** plan restriction, so the answer is probably yes — but it is inferred from silence, not stated |
| U-2b | Whether Supabase publishes any **stability / versioning / deprecation policy** for the `/auth/v1` REST surface (none found) |
| U-2c | Supabase Storage's **CDN vendor**, whether Smart CDN is plan-gated, and private-object cache-invalidation semantics |
| U-3 | Exact `eu-west-2` pricing for AWS API Gateway, Lambda, DynamoDB, RDS and CloudFront (pricing pages are JS-rendered) |
| U-4 | `eu-west-2` availability confirmation against the AWS Regional Services List, especially Aurora Serverless v2 auto-pause |
| U-5 | Whether Auth0 offers a **signed DPA below Enterprise**, and whether **UK region selection is available on the Free plan** |
| U-6 | Whether Auth0's Sessions Management / back-channel logout closes the access-token introspection gap |
| U-7 | Fly Managed Postgres **backup retention and PITR window** — not documented |
| U-8 | Whether Fly.io holds SOC 2 / ISO 27001 |
| U-9 | Whether the **Databricks acquisition of Neon has closed** (announced 2025-05-14 as an agreement; no closing announcement found) — relevant to Neon's corporate group and subprocessor list |
| U-10 | Whether **Hetzner Cloud** offers a managed Postgres product (strongly indicated that it does not) |
| U-11 | Hetzner's included-traffic allowance and overage rate (secondary-sourced) |
| U-12 | Render's current compute price list (JS-rendered; $7/$25 figures are secondary-sourced) |
| U-13 | Firestore's **`europe-west2` (London)** per-operation and storage prices — the pricing table is per-location and only the `us-central1` row could be extracted; London will be higher |
| U-13b | Whether **Firebase Authentication has any SLA at all** (no Identity Platform SLA document found; the Firebase-branded SLA covers only Hosting and Realtime Database) |
| U-13c | Whether Google's **UK IDTA / UK Addendum** terms are incorporated by default in the Cloud DPA, and the current GCP subprocessor list (the Firebase subprocessor page is **last modified 2021-09-23** and defers to GCP's) |
| U-13d | Firebase Storage download-token revocation and signed-URL behaviour (secondary sources only) |
| U-14 | Whether AppSync is explicitly supported without any SDK (inferred from endpoint/auth docs) |
| U-15 | CloudKit's current storage/transfer quotas — the quota reference page returned HTTP 404 |
| U-16 | Whether any Apple DPA exists under which Apple is the **developer's processor** for CloudKit data (Program License Agreement is login-gated) |
| U-17 | Whether CloudKit Web Services / CloudKit JS has any 2026 deprecation announcement (none found; docs are archived) |
| U-18 | How quickly CloudFront key-group removal propagates to the edge |
| U-19 | Cloudflare Workers overage rates (secondary-sourced) |
| U-20 | The ICO's January 2026 international-transfers guidance update date (secondary-sourced) |

## 6. A correction to our own language

UK GDPR and the DPA 2018 contain **no data-localisation mandate** — personal data may sit outside
the UK with an appropriate transfer mechanism (adequacy, IDTA, or the UK Addendum to EU SCCs)
plus a Transfer Risk Assessment
([ico.org.uk international transfers guidance](https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/international-transfers/),
2026-07-29). Requirement **F-1** should therefore be read as a **trust, DPIA-simplification and
latency** choice rather than a legal obligation — which does not make it less desirable, but does
mean it must not be used to disqualify an otherwise better option on its own. **This is a legal
question and the above is not legal advice.**
