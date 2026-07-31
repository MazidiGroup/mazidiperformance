# Session handoff — 31 July 2026

Written for a fresh session with no access to the prior conversation. Everything below was
verified against the repos, GitHub and the live site at writing time. **Re-verify before
acting — state moves.** (Supersedes the 24 July handoff.)

## Start here

**Open the new session in `/Users/mazadi/mazidiperformance`** — the iOS app. That is where the
remaining work is. Two other repos exist (below); open them only if the task concerns them.

Read `CLAUDE.md` first, then this file, then `docs/architecture/adr/` (ADR-0001…0014).

## The three repositories

| Path | Repo | State |
|---|---|---|
| `/Users/mazadi/mazidiperformance` | `MazidiGroup/mazidiperformance` | **iOS app — work here.** `main` = `54dd3ac`, clean, 0 open PRs |
| `/Users/mazadi/mazidiperformance-web` | `MazidiGroup/mazidiperformance-web` (private) | Privacy centre. `master` = `7df893a`. **LIVE** |
| `/Users/mazadi/mazidi-platform` | `MazidiGroup/mazidi-platform` | MazidiGroup website. `master` = `1078eee` — **untouched, do not modify** |

## What the product is

Subscription iOS app for independent personal trainers (Coach) and their clients (Client).
Swift 6 / SwiftUI, `App/` + `Packages/MazidiKit`. `CLAUDE.md` holds the working rules — they
are strict and load-bearing (honesty about status, offline-first, accessibility as
definition-of-done, no fabricated backend).

## Where things stand

### Live
Privacy centre at `https://mazidiperformance.mazidigroup.com/privacy` (+ `/privacy/request`,
`/privacy/complaints`). Verified 200, valid certificate, HTTP→HTTPS redirect.
`mazidigroup.com/privacy` correctly **404s** — the app notice must never serve the platform site.

### Merged into the app's `main`
Foundation, GRDB persistence, auth/session/account isolation, Coach programming + assignment,
exercise catalogue (206 exercises) + media pipeline, backend sync foundation (contracts + DEBUG
fake only), health-data consent flow (migration v4), local device profile for TestFlight
(ADR-0014), build config, app icon.

**346 package tests / 44 suites passing. GRDB pinned exactly 7.11.1.**

### Immediate task — get onto TestFlight

Blocked on **one user action**: Apple team `JWAX6S948T` (paid membership, confirmed) has **no
registered devices**, so automatic signing cannot create a provisioning profile.

Fix: connect an iPhone by cable → Trust → Xcode → Window → Devices and Simulators. Or add the
UDID at developer.apple.com → Devices.

Verify: `security find-identity -v -p codesigning` must show a line containing `JWAX6S948T`.
At handoff only an unrelated `D57QP5WB96` certificate existed.

Then: Xcode → destination **Any iOS Device** → Product → Archive → Distribute App →
TestFlight & App Store Connect. Bundle ID is `com.mazidigroup.MazidiPerformance` (capital M's).
Version 1.0.1 (1). Icon is committed and verified 1024x1024 with no alpha.

**The scheme archives with `Staging`, deliberately.** Release has no `LOCAL_IDENTITY`
condition, so a Release archive shows every tester a sign-in wall they cannot pass. Do not
"fix" this by switching to Release.

## Constraints — do not break these

1. **Local-only, TestFlight only. Not the App Store.** The product needs coach↔client delivery,
   which needs a backend that does not exist. Internal testing only — external testing triggers
   Beta App Review.
2. **`LOCAL_IDENTITY` is Debug + Staging only.** Never `#if DEBUG` alone: Staging is a
   release-style build. `Scripts/check-release-isolation.sh <app-bundle>` proves the Release
   binary carries no local-identity or development symbols. Keep it passing.
3. **The published notice must stay true of the app.** It states the app transmits nothing, has
   no third-party processors, and offers no export/deletion/consent-withdrawal. If any of that
   changes, the notice changes **in the same release** (`LEGAL_CHECKLIST.md` #14, web repo).
4. **Release keeps `UnavailableAuthProvider`** so an accidental App Store submission fails closed.
5. **An unsigned Staging build cannot create a local profile** (no keychain-access group). Build
   Staging *signed* to test by hand. See `docs/BUILD_AND_TEST.md`.

## Known gaps — all deliberate, all documented

- **No backend.** ADR-0013 selected Supabase (London) but is **Accepted for provider selection
  only**; four Phase 0 gates open (executed DPA with UK Addendum, DPIA, ICO registration,
  solicitor confirmation of the Art. 9 basis). `SYNC_BASE_URL` / `MEDIA_BASE_URL` empty.
- **No in-app account deletion** — issue #9. Not blocking now (no accounts created), but
  Guideline 5.1.1(v) applies the moment account creation ships.
- **15 open legal questions** in `mazidiperformance-web/LEGAL_CHECKLIST.md`. Only #3 (does
  consent withdrawal require deleting historical records?) changes code.
- The owner approved publishing the notice **without completed solicitor review** — recorded in
  `LEGAL_CHECKLIST.md` under "Owner decision".
- `docs/KNOWN_ISSUES.md` — M4–M8, L1–L12 open, none blocking.

## Working practices that mattered

- Run long `xcodebuild` steps as a **background job writing to a log**, then poll. Silent
  multi-minute foreground builds tripped a watchdog repeatedly.
- **Verify subagent claims independently.** Most reports were accurate; two were not. A
  `git status`, grep or test re-run caught them.
- Git identity is now `MazidiGroup <aimalmazid@gmail.com>`. Historical commits on `main` (87)
  and `mazidi-platform/master` (17) still carry an old address — **deliberately not rewritten**,
  since that would force-push shared history and invalidate merged PRs.

## Verify before acting

```bash
cd /Users/mazadi/mazidiperformance
git status && git log --oneline -5
gh pr list --repo MazidiGroup/mazidiperformance --state open
cd Packages/MazidiKit && swift test          # expect 346 tests / 44 suites
security find-identity -v -p codesigning     # need a JWAX6S948T line before archiving
curl -s -o /dev/null -w "%{http_code}\n" https://mazidiperformance.mazidigroup.com/privacy
```
