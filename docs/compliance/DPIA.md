# Data Protection Impact Assessment — Mazidi Performance

**Status: DRAFT — prepared for owner review. Not a lawyer-approved instrument.**
**Version:** draft-2026-08-02
**Phase 0 gate:** 2 (ADR-0013)

This draft was assembled from the repository's own recorded decisions, constraints and code —
each material claim below cites where it comes from, so a reviewer can check it rather than
trust it. Where something is owner-declared and unverifiable from source, it says so. Where an
answer is genuinely not yet known, it is marked OPEN rather than filled with a plausible guess.

Follows the ICO's DPIA structure.

---

## 1. Identify the need for a DPIA

**Is a DPIA required?** Yes.

Art. 35(1) requires one where processing is likely to result in a high risk to rights and
freedoms. Art. 35(3)(b) names large-scale processing of Art. 9 special category data
specifically. Scale here is currently small, but the ICO's screening criteria are met on
several independent counts:

| Criterion | Engaged? | Why |
|---|---|---|
| Special category data | **Yes** | Owner decision, ADR-0013: workout, discomfort and check-in data treated as Art. 9 health data |
| Data concerning vulnerable subjects | Partly | Clients disclose physical limitations and discomfort to a coach in a position of influence |
| Systematic monitoring | **Yes** | Ongoing tracking of training and self-reported physical state over time |
| Innovative technology | Conditionally | Only if AI-drafted content processes client health data — see §2.6 |
| Denial of service / significant effect | No | The app never gates care on payment (`CLAUDE.md`, payments rule) |

ADR-0013 states plainly that a DPIA is "mandatory in practice now that Art. 9 applies."

**Timing.** This DPIA is being completed *before* any backend exists, any account is created, or
any data leaves a device. That is the correct order and should be recorded as such — Art. 35(1)
requires assessment prior to processing.

---

## 2. Describe the processing

### 2.1 Nature — what is done with the data

**Today (as shipped, 1.0.1 (1)):** all data is created and stored **on the client's own device**
in an account-scoped SQLite database (GRDB, ADR-0002). Nothing is transmitted. `SYNC_BASE_URL`
and `MEDIA_BASE_URL` are empty (`Config/Base.xcconfig`), the real transport is inert, and the
only sync backend that exists is a deterministic fake compiled into DEBUG builds only
(KNOWN_ISSUES L8).

**Proposed (what this DPIA assesses):** introduction of a backend so that a coach can deliver
programmes to a client and receive their training records. Provider selected in ADR-0013:
**Supabase Pro, London (`eu-west-2`)**, used narrowly. No account exists yet.

The distinction matters throughout: the risks below are almost entirely *prospective*. The
current app's risk surface is a lost or stolen phone.

### 2.2 Scope — what data

| Category | Examples | Classification |
|---|---|---|
| Training records | Sets, reps, load, session timing, completion | **Art. 9 health data** (owner decision, ADR-0013) |
| Discomfort / limitation reports | Client-reported pain, injury constraints, exercise swaps | **Art. 9 health data** |
| Check-in content | Free-text client responses to coach prompts | **Art. 9 health data** |
| Identity | Account identifier, role (coach or client) | Ordinary personal data |
| Coach billing | Subscription state | Ordinary personal data — never visible to clients (`CLAUDE.md`) |
| Consent records | Timestamp, notice version, purposes, withdrawal state | Ordinary personal data *about* Art. 9 processing |
| Audit events | Sign-in, sign-out, mutations (ADR-0006) | Ordinary personal data |

**Not collected:** no advertising identifier, no device identifier, no location, no contacts, no
biometric identifiers. The local test profile is a random UUID with no personal content and never
leaves the device (ADR-0014 §2).

**Volumes.** Currently one user (the owner) on TestFlight. Expected initial scale is a single
coach with fewer than ten clients. Small scale does not remove the Art. 9 obligations.

### 2.3 Context

Data subjects are **clients** (who disclose health information) and **coaches** (who receive it).
The relationship is commercial and advisory, with a real asymmetry: the client discloses physical
limitations to someone they are paying for guidance. That asymmetry is why consent must be
genuinely granular and genuinely withdrawable rather than a condition of service.

Children are out of scope. **OPEN:** no age gate exists in the app today, and no minimum age is
stated in the notice. If under-18s are ever in scope, this DPIA must be revisited — Art. 8 and
the Children's Code both engage. Recommend the product decision be recorded explicitly.

### 2.4 Purposes

1. Deliver a training programme from coach to client
2. Record the client's training and return it to their coach
3. Let a coach adjust programming in response to reported discomfort
4. Maintain a payment ledger the coach acknowledges manually — **the app never moves money**
   (`CLAUDE.md`)
5. Coach subscription billing — wholly separate from client payments

Each is a distinct purpose requiring its own consent under the granularity rule in ADR-0013.
Consent to be coached is not consent to analytics, and neither is consent to model inference.

### 2.5 Processors and transfers

| Party | Role | Status |
|---|---|---|
| Supabase | Processor (database, auth, storage) | **Selected, not contracted** — gate 1 |
| Apple | App distribution; iOS platform | Legal checklist item 7 OPEN — whether to name them |
| AI provider | Processor, *if* AI features touch client health data | **None selected. See §2.6** |

**Transfers.** London region means data at rest is in the UK. It does **not** mean no
international access: ADR-0013 records explicitly that "region choice does not eliminate vendor
support access from the US." That access is a restricted transfer and depends on the UK Addendum
being in the executed DPA body — gate 1.

### 2.6 AI processing — a required data-flow map

ADR-0013 lists as an owner deliverable "a data-flow map covering any AI/model API calls that
touch client health data."

**Current state: no AI feature processes client health data, because no such feature is
implemented and no model provider is selected.** `CLAUDE.md` describes AI-drafted content
(check-in responses, follow-ups, programme drafts) as always coach-reviewed and editable, never
automatic, with no diagnostic or guaranteed-monitoring claims.

**This section must be completed before any model API call is made.** Sending a client's
discomfort report or check-in text to a third-party model is a disclosure of Art. 9 data to a new
processor and requires: its own consent purpose, its own DPA, an entry in the sub-processor list,
and a revision of this DPIA. Treat it as a new gate, not an implementation detail.

---

## 3. Consultation

- **Data subjects:** not yet consulted. At current scale (owner only) this is proportionate.
  Recommend a plain-language consent walkthrough with the first real clients before onboarding.
- **Solicitor:** engaged via gate 4. The Art. 9(2)(a) basis is **assumed, not settled** —
  ADR-0013's own words.
- **Processor:** Supabase's published security documentation informed the evaluation
  (`backend-provider-evaluation.md`); no direct engagement yet.
- **ICO:** no prior consultation. Art. 36 prior consultation would be required only if a high
  residual risk cannot be mitigated. On the current assessment, none is.

---

## 4. Necessity and proportionality

**Lawful basis — Art. 6:** performance of a contract (Art. 6(1)(b)) for delivering the coaching
service the client has paid for. **OPEN for solicitor confirmation** alongside the Art. 9 basis.

**Lawful basis — Art. 9:** explicit consent, Art. 9(2)(a). Owner decision, ADR-0013, pending
gate 4.

**Is the processing necessary?** Yes for purposes 1–3: a coach cannot programme around an injury
they have not been told about. Purpose 4 (payment ledger) is necessary to the commercial
relationship but does not require health data and is separated by design.

**Proportionality measures already designed in** — these are existing architecture, not
aspirations:

| Measure | Where |
|---|---|
| Per-coach per-category consent — a coach sees only what that client permitted | `CLAUDE.md`; `handoff/functional-rules.md` |
| Account-scoped databases keyed by a domain-separated hash; no cross-account reads | ADR-0008 §4 |
| Coach and Client are separate navigation graphs — no shared screens, no route leakage | `CLAUDE.md` |
| Credentials in Keychain only, no plaintext fallback | ADR-0008 |
| No personal or sensitive data in URLs or analytics payloads | `CLAUDE.md` |
| Exports authenticated, expiring, revocable — never public URLs | `CLAUDE.md` |
| Offline-first: data need not leave the device to be usable | ADR-0003 |
| Audit events as first-class records | ADR-0006 |
| Sync status must be honest — never claims "synced" while pending | ADR-0003; functional rules |

**Data minimisation.** The app collects what a coach needs to programme safely. The one place to
watch is free-text check-ins, where a client may volunteer more than required. Mitigation is copy,
not code: prompts should not invite clinical disclosure the coach has no basis to hold.

**Retention. OPEN — this is the blocking question.** ADR-0013 identifies a direct conflict:
`CLAUDE.md` states deletion ≠ cancellation and that turning sharing off never deletes past
content, but Art. 9(2)(a) consent is withdrawable at will. If consent is the *sole* basis,
withdrawal removes the grounds to keep training history a coach may need for professional or
liability reasons. **These cannot both be unconditionally true.** Put to the solicitor as gate 4,
question 2. Retention periods (ADR-0013 OQ-8) cannot be set until it is answered.

---

## 5. Risks

Likelihood and severity assessed for the **proposed** backend state unless noted.

| # | Risk | Likelihood | Severity | Inherent |
|---|---|---|---|---|
| R1 | Health data of client A visible to coach B, or to another client | Low | **High** | **High** |
| R2 | Consent invalid — bundled, or not demonstrable under Art. 7(1) | Medium | High | **High** |
| R3 | Withdrawal does not actually stop processing, or implies deletion that does not happen | Medium | High | **High** |
| R4 | Processor breach at Supabase | Low | High | Medium |
| R5 | Unlawful transfer via US support access without a valid mechanism | Medium | Medium | Medium |
| R6 | Device loss — unencrypted local health data | Low | Medium | Medium |
| R7 | Art. 9 data sent to a model provider without basis or DPA | Low | **High** | **High** |
| R8 | Retention indefinite because the question is unresolved | **High** | Medium | **High** |
| R9 | Published notice does not match what the app does | **Materialised** | Medium | **High** |
| R10 | Subject access / erasure cannot be fulfilled — no tooling exists | Medium | Medium | Medium |

**R9 has already occurred** and is not hypothetical. The consent flow shipped in 1.0.1 (1) on
2 Aug while the published notice states no in-app consent or withdrawal mechanism exists. See
`PHASE0.md`, "Live issue". Scope is currently limited to internal TestFlight with no third-party
data subject.

---

## 6. Measures to reduce risk

| Risk | Measure | Status |
|---|---|---|
| R1 | Server-enforced relationship authorization — the client cannot be trusted to scope its own reads | **Not built.** Requires the backend. KNOWN_ISSUES L8 names it explicitly. **Must be a launch blocker, not a follow-up** |
| R1 | Account-scoped databases; separate role graphs | Built (ADR-0008 §4) |
| R2 | Consent-record table: `granted_at`, `notice_version`, `purposes`, `withdrawal_state` — append-only, never overwritten | Designed in ADR-0013; **schema not built** |
| R2 | Versioned notice text retained, so it is provable *what* was consented to | `HealthPrivacyNotice.version` exists (`draft-2026-07-30`) |
| R3 | In-app withdrawal, as easy as granting (Art. 7(3)) | **Built and shipped** — `HealthDataConsentModel.withdraw(_:)`, per-purpose |
| R3 | Withdrawal copy must not imply deletion while data is retained | **Blocked on gate 4.** Do not guess in code — ADR-0013 says so directly |
| R4 | DPA with Art. 28(3) terms and breach notification | Gate 1 |
| R4 | Narrow use of the provider; minimal surface | ADR-0013 |
| R5 | UK Addendum in the executed DPA body, not by reference | Gate 1 — the checklist exists in `PHASE0.md` |
| R6 | iOS Data Protection; Keychain-only credentials | Built. **Legal checklist item 5 asks whether this is sufficient for health data — OPEN** |
| R7 | Treat any model API call touching health data as a new gate: consent purpose, DPA, sub-processor entry, DPIA revision | Policy stated here; **no feature exists yet** |
| R8 | Set retention periods once gate 4 answers | Blocked |
| R9 | Ship the notice change in the same release as the mechanism | **Overdue.** Fix in the web repo, independent of Phase 0 |
| R10 | Build export and deletion tooling | Issue #9 open. Note the notice currently states no export/deletion is offered — that statement is true today and must change in the same release as the capability |
| All | Usage alerting at 60/85/100% of the £50 ceiling, and on any new billable line item — **alerting, not a hard cap**, because a cap converts a billing event into an outage | ADR-0013; configure before real data flows |

---

## 7. Residual risk and sign-off

**Residual risk after measures: acceptable, conditional on four things.**

1. Gate 4 answers the retention question before the withdrawal path's behaviour on existing data
   is finalised
2. Server-enforced relationship authorization is treated as a launch blocker for R1
3. The consent-record schema is built before real consent is captured from a real client
4. R9 is corrected in the web repo now, not as part of Phase 0

No residual high risk requires Art. 36 prior consultation with the ICO **on this assessment** —
but that conclusion depends on gate 4, and must be revisited if the solicitor disagrees with the
Art. 9(2)(a) basis.

### Sign-off

| Role | Name | Date | Outcome |
|---|---|---|---|
| Controller / owner | | | |
| Solicitor review | | | Gate 4 |
| DPO | Not appointed — **assess whether Art. 37(1)(c) requires one given regular systematic Art. 9 processing.** Add to the solicitor brief | | |

**Review triggers.** Revisit this DPIA on any of: backend integration beginning; a model provider
being introduced; a new sub-processor; a change of lawful basis; the retention answer; the first
real client onboarding; or any change to what the published notice claims.
