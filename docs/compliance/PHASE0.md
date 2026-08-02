# Phase 0 — backend integration gates

**Opened:** 2 August 2026
**Governing decision:** ADR-0013 (backend provider selection), "Phase 0 integration gates"
**Status:** all four gates OPEN. No integration work may begin.

> **ADR-0013 is not on `main`.** It lives on the unmerged branch
> `feature/backend-provider-decision` together with `backend-provider-evaluation.md` and
> `backend-provider-requirements.md`. Merging it is a prerequisite for this workstream to be
> coherent — these documents cite an ADR the default branch does not contain. Docs-only,
> three commits, conflict-free.

ADR-0013 authorises **no adapter, no transport, no account, no key, no configuration** until
every gate below is closed. Nothing here changes that. `SYNC_BASE_URL` and `MEDIA_BASE_URL`
stay empty.

## The four gates

| # | Gate | Owner | Can be drafted here | Status |
|---|---|---|---|---|
| 1 | DPA executed, UK Addendum verified **in the document body** | Owner | Verification checklist only — execution is a signature | OPEN |
| 2 | DPIA completed | Owner signs; drafted here | **Yes — draft at [DPIA.md](DPIA.md)** | OPEN — draft ready for review |
| 3 | ICO registration + data protection fee paid | Owner | Application details assembled below | OPEN |
| 4 | Solicitor confirmation of the Art. 9(2)(a) basis + the retention question | Solicitor | **Yes — brief at [solicitor-brief.md](solicitor-brief.md)** | OPEN — brief ready to send |

Gates 2 and 4 are the ones with drafted material. Gates 1 and 3 are transactions only the
owner can perform — this file records exactly what each needs so neither stalls on ambiguity.

## Sequencing

Gate 4 should go out **first**. It is the longest lead time, and its answer to the retention
question changes the DPIA's risk assessment and the withdrawal path's behaviour on existing
data. Sending the solicitor brief before the DPIA is finalised avoids drafting the retention
section twice.

Gate 3 is independent and can be done today. Gate 1 depends on nothing but Supabase's
contracting process. Gate 2 is the only one with a real dependency — on gate 4.

```
Gate 4 (solicitor)  ──────────────────┐
Gate 3 (ICO)        ──┐               ├──> Gate 2 (DPIA finalised) ──> Phase 0 closed
Gate 1 (DPA)        ──┘               │
                                      │
        retention answer ─────────────┘
```

## Gate 1 — DPA with the UK Addendum

**What must be true.** An executed data processing agreement with Supabase, and the UK
Addendum (or IDTA) present **in the body of the document that is signed** — not referenced by
a link, not "available on request", not assumed from a web page. ADR-0013 is explicit that
referencing is insufficient (OQ-2 / OQ-2b).

**Why the body matters.** Supabase's region choice (London, `eu-west-2`) does not eliminate
vendor support access from the United States. That access is a restricted transfer under UK
GDPR, and the Addendum is the transfer mechanism. A DPA whose transfer terms live behind a URL
can change without a signature.

**Verification checklist — read the executed PDF against this:**

- [ ] Controller and processor are named, and the controller matches the entity in gate 3
- [ ] The UK Addendum (or IDTA) text is **inside** the executed document
- [ ] Approved EU SCCs are attached where the Addendum modifies them
- [ ] Sub-processor list is enumerated, with a notification mechanism for changes
- [ ] Support access from outside the UK is described, not silent
- [ ] Art. 28(3) terms present: documented instructions, confidentiality, security, sub-processor
      conditions, assistance with data-subject rights, breach notification, deletion/return at
      end of contract, audit rights
- [ ] Special category data is contemplated — a generic DPA that assumes ordinary personal data
      is a gap given the Art. 9 decision
- [ ] Breach notification has a stated time bound

**Store the executed PDF outside this repository.** Do not commit contracts.

## Gate 2 — DPIA

Draft at [DPIA.md](DPIA.md). It is mandatory in practice: Art. 35(3)(b) is engaged by
processing special category data on a large scale, and the ICO's own screening criteria are met
on several counts independent of scale.

The draft is complete except for the retention section, which is deliberately left open pending
gate 4. **It requires owner review and sign-off** — it is a structured first draft prepared from
the repository's own decisions and constraints, not a lawyer-approved instrument.

## Gate 3 — ICO registration and fee

**This can be done today and blocks nothing else.** Legal checklist item 13 records it as an
outstanding statutory obligation independent of the backend, and the published privacy notice
already routes complaints to the ICO — being unregistered while doing so is the position to get
out of first.

Register at `ico.org.uk` → Data protection fee.

**Details the application asks for, as they currently stand:**

| Field | Value | Confidence |
|---|---|---|
| Legal entity | Mazidi Homes Limited | **Owner-declared, unverified** — legal checklist item 9 is OPEN |
| Company number | 15350516 | Owner-declared |
| Registered address | Flat 55 Banstead Court, 60 Westway, London, England, W12 0QJ | Owner-declared |
| Turnover / staff | Determines the fee tier | Owner |
| Processing special category data | **Yes** — health data, per ADR-0013 | Decided |
| Public authority | No | — |

**Resolve legal checklist item 9 before submitting.** Registering the wrong legal person is
worse than registering late: every right on the published pages, and the ICO complaint route
itself, depends on naming the correct controller. That item is owner-answerable and has been
open since 30 July.

Expected fee tier for a micro-organisation is the lowest band, but the tier follows turnover and
headcount — do not assume it.

**Record the registration number here once issued.** It belongs in the privacy notice.

## Gate 4 — solicitor confirmation

Brief at [solicitor-brief.md](solicitor-brief.md). Two questions, one of which has a direct and
currently-blocking design consequence.

ADR-0013 records the Art. 9(2)(a) basis as **assumed, not settled** — "the assumption is
recorded, not settled". Everything built on it inherits that caveat until this closes.

## What is NOT blocked by Phase 0

Phase 0 blocks *integration*. It does not block:

- TestFlight testing of the local build (already distributed, 1.0.1 (1), 2 Aug)
- Closing known issues that need no backend (M6, L1, L2)
- The account-deletion work in issue #9
- Correcting the privacy notice — see the live issue below, which is **not** a Phase 0 item and
  should not wait for one

## Live issue found while opening Phase 0 — not a Phase 0 gate

**Legal checklist item 14 has triggered.** The health-data consent flow shipped to TestFlight in
1.0.1 (1) on 2 August. The shipped build contains an in-app consent screen
(`App/Client/Views/HealthDataConsentView.swift`) and an in-app withdrawal control
(`HealthDataConsentModel.withdraw(_:)`).

The published notice does not describe either, and was written on the express premise that
neither exists — `app/privacy/page.tsx` carries a guard note that it "must NOT describe an in-app
consent screen, an in-app withdrawal control". Item 14's obligation is that the notice change
ships **in the same release**, not after it. That release has gone out.

Scope is currently narrow: internal TestFlight, owner only, no third-party data subject has used
it. That limits the practical consequence but does not unmake the obligation, and the window
closes the moment another tester is added.

Item 14 also requires narrowing `FORBIDDEN_WITH_MECHANISM` in
`scripts/check-privacy-placeholders.mjs` (web repo) — deliberately, with both-direction injection
testing. Do not delete the guard.

**This is tracked here only because it was found here. It belongs to the web repo and should be
fixed independently of, and sooner than, Phase 0.**
