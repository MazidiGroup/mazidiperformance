# Risk & dependency register

**Updated:** 2026-07-23. Severity: H/M/L. Review each slice.

## Dependencies (external, blocking at the noted phase)

| ID | Dependency | Needed by | Status |
|---|---|---|---|
| R-01 | **Backend API does not exist** — no auth, sync, messaging, media endpoints | Phase 2 end-to-end sync (local-first works without it) | Open. All networking is protocol-first contracts in `MazidiNetworking`; contracts double as the backend spec |
| R-02 | Server-side **idempotency-key support** (ADR-0003) | Phase 2 sync | Open — backend requirement, documented |
| R-03 | **Full 206-clip video library** via content/CDN pipeline (12 bundled dev clips only) | Phase 2 polish / Phase 3 | Open — per `asset-cdn-integration.md` |
| R-04 | **Fitness-professional review** of client-content draft (101 flagged, 206 draft) | Production release gate, not dev | Open — draft badge stays visible in-product until cleared |
| R-05 | **Legal/privacy review**: retention periods, deletion wording (13g/13i/13j) | Phase 7 | Open — rules kept configurable |
| R-06 | **App Store**: subscription products, entitlements, review guidelines (3.1 IAP vs web billing) | Phase 6 | Open — no App Store config exists; do not fabricate |
| R-07 | **APNs/push infrastructure** + quiet-hours/"notify now" delivery semantics | Phase 4 | Open |
| R-08 | **macOS/Xcode build environment** — current dev host is Windows (no Xcode/Swift initially; Swift-for-Windows toolchain install attempted, see BUILD_AND_TEST.md) | Now, for app-target build & UI tests | **Active constraint** — MazidiKit designed Windows-testable (ADR-0001); app target needs a Mac or macOS CI (R-09) |
| R-09 | **CI (GitHub Actions macOS runner)** — needs repo admin | Phase 1 hardening | Open |

## Risks

| ID | Risk | Sev | Mitigation |
|---|---|---|---|
| K-01 | Sync/conflict logic subtly wrong → data loss or duplicates in workout history | H | ADR-0003 design-first; property-style unit tests for replay/idempotency/crash points; superseded sessions read-only recoverable, never deleted |
| K-02 | Building UI against a fabricated backend shape → rework when real API lands | M | Contract-first protocols; in-memory server simulator clearly labelled as simulator; no fabricated capabilities in docs |
| K-03 | Accessibility treated as polish → fails acceptance criteria late | M | A11y in definition-of-done per feature; checklist from `accessibility-qa.md` per PR |
| K-04 | Draft exercise copy shipped as approved | H | `contentStatus` carried through the pipeline; "DRAFT COPY · PENDING REVIEW" badge non-flaggable; release gate on R-04 |
| K-05 | Entitlement checks scattered in views → care-blocking bugs (violates turn-11 safety rule) | H | Single `EntitlementPolicy` domain service (ADR-0004); tests for existing-client-care exceptions |
| K-06 | Recurring events stored as UTC → DST bugs | M | RRULE + IANA zone + local start stored (12f); DST transition tests |
| K-07 | Notification badge counts unread instead of unresolved | M | ADR-0005 separate read/task state; unit tests |
| K-08 | Payment amendments overwrite history | H | Append-only amendments, void-with-reason, audit trail; tests |
| K-09 | Windows-authored Swift breaks under Xcode (SDK differences) | M | Keep MazidiKit Foundation-only; first macOS build ASAP; CI both platforms |
| K-10 | Handoff HTML/docs drift vs implementation | L | Panel IDs referenced in feature docs/PRs; source-of-truth order documented |
| K-11 | CRLF checkout altering text fixtures (autocrlf=true observed) | L | `.gitattributes` added pinning JSON/CSV/HTML fixtures to LF |
