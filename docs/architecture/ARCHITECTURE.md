# Mazidi Performance — production iOS architecture

**Status:** v0.1 — foundation + first vertical slice. Grows with each slice; changes recorded as ADRs in `docs/architecture/adr/`.

## 1. Shape of the system

Native **Swift 6 / SwiftUI**, structured concurrency throughout. Two top-level layers:

```
mazidiperformance/
├── App/                        # Xcode app target (macOS+Xcode required to build)
│   ├── MazidiApp.swift         # entry, role shell selection
│   ├── Navigation/             # Coach + Client routers (separate stacks)
│   ├── DesignSystem/           # tokens (from handoff design-tokens.md), components
│   ├── Features/               # SwiftUI feature modules (thin — bind to MazidiKit)
│   └── Platform/               # iOS-only adapters: Keychain, HealthKit, EventKit,
│                               #   push, AVFoundation media, background tasks
├── Packages/MazidiKit/         # platform-neutral SwiftPM package — builds & tests on
│   ├── Sources/                #   macOS, Linux and Windows (no UIKit/SwiftUI imports)
│   │   ├── MazidiDomain/       # entities, value types, state machines, domain rules
│   │   ├── MazidiServices/     # application services (use-cases), orchestration
│   │   ├── MazidiPersistence/  # persistence protocols + in-memory impl (SQLite/GRDB
│   │   │                       #   adapter lives app-side)
│   │   ├── MazidiSync/         # offline operation queue, idempotency, replay, conflict
│   │   ├── MazidiNetworking/   # API contracts (protocol-first; no live backend yet)
│   │   └── MazidiFoundations/  # ids, clock, logging façade, feature flags, audit events
│   └── Tests/                  # unit tests per module
├── project.yml                 # XcodeGen manifest → generates .xcodeproj on macOS
└── docs/                       # this documentation set
```

**Rule:** everything that can live in `MazidiKit` lives in `MazidiKit`. The app target contains UI, navigation, and platform adapters only. This is what makes domain behaviour testable off-Mac and keeps offline/sync logic UI-independent.

## 2. Layer responsibilities

| Layer | Owns | Never does |
|---|---|---|
| Presentation (SwiftUI) | rendering, accessibility traits, Dynamic Type reflow | business rules, direct persistence |
| Navigation | role-scoped routers, deep links (notification → destination) | cross-role route leakage |
| Domain (`MazidiDomain`) | entities, state machines (workout session, payment, entitlement, calendar proposal, deletion), invariants | I/O of any kind |
| Services (`MazidiServices`) | use-cases, transactions, policy (quiet hours, entitlement checks, permission checks) | UI types |
| Persistence (`MazidiPersistence`) | repository protocols; in-memory reference impl; migration contracts | schema leakage into domain |
| Sync (`MazidiSync`) | durable operation queue, idempotency keys, ordered replay, conflict classification | silent data loss, blanket last-write-wins |
| Networking (`MazidiNetworking`) | endpoint contracts, DTOs, auth token plumbing (protocol-first) | fabricated backend behaviour |
| Platform (app target) | Keychain, biometrics, EventKit, HealthKit, push, AVFoundation, BGTasks | domain decisions |

## 3. Cross-cutting decisions (summaries — full text in ADRs)

- **ADR-0001** Platform-split package layout (Windows-testable core). 
- **ADR-0002** Persistence: SQLite via GRDB in the app; repositories are protocols in `MazidiKit` with an in-memory implementation for tests and for Windows builds. Migrations are explicit, versioned, forward-only.
- **ADR-0003** Offline-first writes: every mutation is a durable `Operation` row written locally *before* any network attempt; server writes are idempotent via client-generated UUID idempotency keys; replay is ordered per-aggregate; conflicts are classified per domain (see §5), never blanket last-write-wins.
- **ADR-0004** Entitlements as domain rules: a single `EntitlementPolicy` in `MazidiServices` answers "may this actor do X"; views never hand-roll checks. Restricted states block growth actions only — existing-client care is always permitted (handoff functional rule, turn 11).
- **ADR-0005** Read state ≠ task state: notification items carry independent `readState` and `taskState` (needsAction/acknowledged/snoozed/resolved). Badges count unresolved needs-action only (turn 9).
- **ADR-0006** Audit events are first-class domain output — a typed, append-only `AuditEvent` written in the same local transaction as the action, synced with the same durability as data, separate from analytics.

## 4. Identity, roles & security model

- Coach and Client are separate role shells with separate navigation graphs; a signed-in identity maps to exactly one active role context at a time. No shared screens between coach billing and client payments (turn 11 rule).
- Assistant coaches: least-privilege permission sets, client-scoped grants, every grant/revoke audited; clients can directly revoke sensitive-category assistant access (13f/13h).
- Tokens in Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`); local DB encrypted (SQLCipher — decision pending, DL-07); remote sign-out revokes server-side immediately, local wipe on next connect — the offline-device limitation is stated honestly in UI copy (13c).
- Exports: authenticated + recent-reauth, 7-day expiring revocable links, never unprotected shared storage (13g).

## 5. Conflict-resolution approach (documented before implementation — per brief)

Conflict classes and default resolutions (full algorithm in `docs/architecture/SYNC_DESIGN.md`):

| Class | Example | Resolution |
|---|---|---|
| Append-only facts | completed sets, payments, audit events | never conflict — union by idempotency key; duplicates dropped by key |
| Single-writer aggregates | a client's active workout session | one-device rule (panel 5f): server session epoch; a superseded offline session becomes **read-only recoverable**, surfaced to the user, never silently discarded |
| Coach-authored config | programme drafts | version vector; concurrent edit → explicit merge prompt, later save becomes a new revision, nothing overwritten silently |
| Published programmes | programme versions | append-only versions; completed history is immutable (6i) |
| Counters/status | notification task state | monotonic state lattice (resolved > acknowledged > needsAction); resolution wins over staleness |

## 6. Media delivery

Per `asset-cdn-integration.md`: slug-keyed manifest, poster-first always, muted loop, only the opened exercise animates; cache tiers (auto: metadata+instructions+current-programme posters / opt-in Wi-Fi prefetch: next workout clips / explicit download: full programme); never bundle or auto-download the full 206-clip library; skeleton + name/icon fallback on failure; Reduce Motion disables autoplay (14f). The Design-Canvas video helper is **not** used.

## 7. Accessibility

Acceptance criteria of `accessibility-qa.md` are part of definition-of-done per feature: Dynamic Type to AX5, VoiceOver labels/traits/values/order, 44pt targets, Reduce Motion, Increase Contrast, Differentiate Without Colour, keyboard avoidance, text equivalents for charts. Design tokens are the only colour source (light success `#136B41` etc.); components expose accessibility identifiers for UI tests.

## 8. Analytics vs audit

Two pipelines. Analytics: product usage, no sensitive client content in payloads. Audit: security/safety-consequential actions (permission changes, payment amendments, programme publication, exports, deletions, remote sign-out, sensitive access), tamper-evident (hash-chained locally), synced durably.

## 9. Environment & secrets

`.xcconfig` per environment (Debug/Staging/Release); no secrets in the repo; server URLs and flags via configuration; feature flags default-off for unreviewed content surfaces (e.g. draft-content badge is **on** and cannot be flag-disabled — content status is a product rule, not a flag).

## 10. Testing strategy

- **Unit (MazidiKit, runs on any Swift host):** state machines, sync/idempotency/replay, entitlement policy, notification state, payment rules.
- **Integration (macOS):** GRDB repositories, migration tests.
- **UI (macOS/simulator):** highest-value Coach + Client journeys with accessibility identifiers; snapshot × appearance × type size per `accessibility-qa.md`.
- CI target: macOS runner (GitHub Actions) — pending repo-settings access (DL-09).
