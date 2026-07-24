# CLAUDE.md — working guide for Mazidi Performance

Operational conventions for anyone (human or AI) working in this repository.
Keep it short; it references the detailed documents rather than repeating them.

Mazidi Performance is a subscription-based native **Swift 6 / SwiftUI** iOS app for
independent personal trainers (Coach) and their clients (Client).

## Approved design source

- **`design/handoff-current/`** is the single approved design source. Tag
  **`design-handoff-v1.0.0`** is the approved handoff baseline — build against it, not
  against memory of earlier prototypes.
- The panel canvas is `design/handoff-current/Mazidi Performance.dc.html` (anchor-addressable,
  e.g. `#7d`). The written specs live in `design/handoff-current/handoff/`.
- Do **not** modify anything under `design/handoff-current/` — it is a frozen baseline.

## Source-of-truth order

When two sources appear to disagree, the higher entry wins:

1. **Final handoff specifications and state machines** — `handoff/state-machines.md`,
   plus the domain state machines in `Packages/MazidiKit` (e.g. `WorkoutSession`).
2. **Latest approved panels** — the newest turn covering the screen (turns are newest-first
   in the `.dc.html`; see `handoff/screen-inventory.md` for the map).
3. **Functional and safety rules** — `handoff/functional-rules.md`.
4. **Screen inventory** — `handoff/screen-inventory.md`.
5. **Earlier panels** — historical context only; never override the above.

## Architecture — reference, don't duplicate

Read these rather than re-deriving structure:

- `docs/architecture/ARCHITECTURE.md` — layers, responsibilities, conflict-resolution table.
- `docs/architecture/adr/ADR-0001…0006` — platform split, persistence (GRDB), offline
  operation queue/idempotency, entitlements, read-vs-task state, audit events.
- `docs/BUILD_AND_TEST.md` — how to build and test both targets.
- `docs/KNOWN_ISSUES.md` — accepted defects and their owning milestones.

**Layout rule:** everything that can live in `Packages/MazidiKit` (domain, services, sync,
persistence contracts, networking contracts) does. The `App/` target holds SwiftUI, navigation
and platform adapters only. MazidiKit imports Foundation only — no UIKit/SwiftUI/GRDB — so it
builds and tests off-Mac.

## Coach / Client role boundary

Coach and Client are **separate role shells with separate navigation graphs**; a signed-in
identity maps to exactly one active role at a time. No shared screens, no cross-role route
leakage. Coach billing/subscription state is never visible to Clients, and client payments are
never a checkout. Keep the two graphs separate by construction.

## Product constraints that must be preserved

These are product/safety rules, not preferences — do not weaken them to ship a feature:

- **Safety & content:** client-facing copy comes only from the client-content layer; draft
  content is always labelled "DRAFT COPY · PENDING REVIEW" and can never be presented as
  approved. This is a rule, not a feature flag.
- **Privacy:** per-coach per-category consent; sharing off stops future sharing, never deletes
  past content; deletion ≠ cancellation; exports are authenticated, expiring, revocable, never
  public URLs. No personal/sensitive data in URLs or analytics payloads.
- **Accessibility:** the acceptance criteria in `handoff/accessibility-qa.md` are
  definition-of-done — Dynamic Type to AX5 (restack, never clip), VoiceOver labels/traits/
  values/order, 44pt targets, Reduce Motion, Increase Contrast, Differentiate Without Colour
  (status is never colour-only), keyboard avoidance. Design tokens are the only colour source.
- **Offline / sync:** every mutation is a durable local operation written before any network
  attempt; idempotency keys make retries safe; replay is ordered per aggregate; conflicts are
  classified per domain (never blanket last-write-wins); no silent data loss. Sync status is
  honest — never claim "synced" while items are pending (`handoff/functional-rules.md`, panel 4i,
  ADR-0003).
- **Payments:** the app never moves money — "mark as paid" is the only acknowledgement; records
  amend, never delete; overdue never auto-locks a client.
- **Subscription:** coach billing is wholly separate from client payments; no plan change or
  cancellation ever removes client records; restricted state still permits full care of existing
  clients.
- **AI:** AI-drafted content (check-in responses, follow-ups, programme drafts) is always
  coach-reviewed and editable before it goes out; never presented as final or automatic; no
  guaranteed-monitoring or diagnostic claims.

## Engineering conventions

- **Honesty about status.** Distinguish, in code and in writing, what is **implemented** vs
  **mocked/fixture-backed** vs **planned** vs **tested**. Fixtures and simulators must be clearly
  labelled (e.g. behind provider protocols, `#if DEBUG`, or explicit `Fixture…` names). No
  backend exists yet (R-01/R-02) — do not fabricate live behaviour.
- **Focused branches and commits.** One concern per branch; small, self-describing commits. Do
  not bundle unrelated changes.
- **Tests and builds before "done."** Before claiming a task complete, run the relevant checks:
  `swift test` for MazidiKit, and for app changes `xcodegen generate` + a Debug simulator build
  (and the UI tests / Release build when the change warrants). Report failures honestly.
- **Generated artifacts stay out of git.** `project.yml` is the canonical project source; the
  `.xcodeproj`, `App/Info.plist`, SwiftPM `.build/`, DerivedData and Xcode user data are
  generated and git-ignored. `MANIFEST.sha256` covers tracked files — regenerate it when tracked
  files change (see the existing "Regenerate MANIFEST.sha256" commits for the recipe).

## Never commit

- Credentials, tokens, API keys, or production secrets. Configuration comes from `.xcconfig` /
  environment, never the repo.
- The full animation library. Only the small representative media set (a few clips + posters)
  belongs in git; the 206-clip library is delivered via the content pipeline / CDN.

## Full animation library — local source

The complete animation pack lives **only** on this machine at:

```
/Users/mazadi/Documents/MazidiPerformance/Animation_Pack_20-07-26
```

This directory is a read-only source of record: **do not modify, rename, delete, move, or commit
it, and do not copy the full library into the repo.** For how the library is eventually ingested
to the staging CDN (slug-keyed manifest, poster-first, cache tiers), see
`design/handoff-current/handoff/asset-cdn-integration.md`.
