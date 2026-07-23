# Implementation roadmap — mapped to the 110-panel handoff

Phases follow the brief; every feature cites its governing panels. A panel is "covered" only when the definition-of-done in the brief is met (domain + states + a11y + tests + docs), not when the screen renders.

## Phase 1 — Foundation *(in progress)*
Project structure & XcodeGen manifest · environment config · design tokens (14i, `design-tokens.md`) · reusable components · Coach/Client role shell + navigation · auth/session abstractions · persistence interfaces + in-memory impl (ADR-0002) · offline operation queue + sync foundation (4i, ADR-0003) · audit-event foundation · feature flags · a11y utilities · logging/error handling · test infrastructure.

## Phase 2 — Client workout vertical slice
Panels: **3a–3f, 4a–4c, 4i, 5a–5g, 7f, 7g, 7h, 7i, 7l, 14b, 14f**.
Client home → open assigned workout → overview → exercise detail (real posters/clips) → type-aware set entry (7j) → rest timer (4a) → approved alternative (4b/7h) → pause/exit/resume (5a/5b/5g) → completion (3e) → offline persistence, reconnection, idempotent sync, duplicate prevention, interruption/crash recovery, one-device rule (5f).
Domain core of this slice is implemented first in MazidiKit (see `VERTICAL_SLICE_1.md`).

## Phase 3 — Coach programming loop
Panels: **6a–6i, 7a–7e, 7j, 7k**. Exercise search/detail, prescription editor, alternatives, cues, custom exercises (7k), progression rules, preview, publish, versioning, live-programme edit rules (6i), completed-history protection, client notification.

## Phase 4 — Coach operating loop
Panels: **1a–1h, 2a–2h, 4d–4h, 5d, 5e, 9a–9d, 14a**. Dashboard/attention signals, client list/profile, check-ins, progress, discomfort alerts (5d), substitution inbox (5e), notification inbox with read-vs-task state, ack/snooze/resolve, deep links, badges (9d), quiet hours (13d rules), messaging (4h), AI-drafted responses (1c/1g — labelled, editable, confirm-before-send).

## Phase 5 — Invitations & onboarding
Panels: **8a–8i**. Invitation create/pending/resend/revoke/history, landing, account matching + verification, wrong-account protection, consent (8e), setup (8f), permission education — off by default, never forced (8g), completion with/without programme (8h), edge states incl. offline/expired/revoked/duplicate (8i).

## Phase 6 — Commercial systems
Panels: **10a–10g, 11a–11f**. Packages, external-payment ledger + state machine (10f/10g), amendments + audit, session balances, client receipts (10e); Mazidi subscription plans, entitlement state machine (11f), billing history, grace/restricted rules with existing-client-care exceptions.

## Phase 7 — Calendar & account systems
Panels: **12a–12f, 13a–13j**. Calendar day/week, event creation, recurring (RRULE+zone), conflicts, proposals with revalidation + race handling (12d/12e/12f), no-shows, device-calendar privacy; settings, security/biometrics/devices (13c), notifications/quiet hours (13d), connected permissions (13e), assistants (13f), export/retention/deletion (13g), client privacy controls (13h), relationship-ended (13i), edge states (13j).

## Cross-phase (every phase)
Accessibility panels **14c–14i** are acceptance criteria for all of the above; light mode (14a/14b) from Phase 2 on; analytics/audit separation; draft-content badge until R-04 clears.

## Sequence-change rule
Material resequencing requires a note here with the reason (per brief). None yet.
