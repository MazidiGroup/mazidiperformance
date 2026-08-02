# Session handoff — 2 August 2026

Written for a fresh session with no access to the prior conversation. Everything below was
verified against the repos, GitHub, the keychain and the live site at writing time.
**Re-verify before acting — state moves.** (Supersedes the 31 July handoff.)

## Start here

**Open the new session in `/Users/mazadi/mazidiperformance`** — the iOS app. That is where the
remaining work is. Two other repos exist (below); open them only if the task concerns them.

Read `CLAUDE.md` first, then this file, then `docs/architecture/adr/`. Note the ADR set on
`main` is 0001–0012 plus 0014 — **ADR-0013 is not on `main`**; see "Documentation gaps".

## The three repositories

| Path | Repo | State |
|---|---|---|
| `/Users/mazadi/mazidiperformance` | `MazidiGroup/mazidiperformance` | **iOS app — work here.** `main` = `4e36e3e`, clean, pushed, 0 open PRs |
| `/Users/mazadi/mazidiperformance-web` | `MazidiGroup/mazidiperformance-web` (private) | Privacy centre. `master` = `7df893a`. **LIVE** |
| `/Users/mazadi/mazidi-platform` | `MazidiGroup/mazidi-platform` | MazidiGroup website. `master` = `4cc9477` — **do not modify** |

The platform repo moved since the last handoff (it was `1078eee`); the newest commit adds
privacy-centre screenshots. It is still not something to work in.

## What the product is

Subscription iOS app for independent personal trainers (Coach) and their clients (Client).
Swift 6 / SwiftUI, `App/` + `Packages/MazidiKit`. `CLAUDE.md` holds the working rules — they
are strict and load-bearing (honesty about status, offline-first, accessibility as
definition-of-done, no fabricated backend).

## Where things stand

### Live
Privacy centre at `https://mazidiperformance.mazidigroup.com/privacy` (+ `/privacy/request`,
`/privacy/complaints`) — verified 200. `mazidigroup.com/privacy` correctly **404s**; the app
notice must never serve the platform site.

### Merged into the app's `main`
Foundation, GRDB persistence, auth/session/account isolation, Coach programming + assignment,
exercise catalogue (206 exercises) + media pipeline, backend sync foundation (contracts + DEBUG
fake only), health-data consent flow (migration v4), local device profile for TestFlight
(ADR-0014), build config, app icon, iPhone-only portrait declaration.

**346 package tests / 44 suites passing. GRDB pinned exactly 7.11.1.**

### TestFlight — the 31 July blocker is CLEARED

The iPhone is registered to team `JWAX6S948T` (UDID `00008150-001E683111F0401C`), and
**1.0.1 (1) was uploaded to App Store Connect on 2 Aug and began processing.**

Route that worked, all from the command line:

```bash
xcodegen generate
xcodebuild -project MazidiPerformance.xcodeproj -scheme MazidiPerformance \
  -configuration Staging -destination 'generic/platform=iOS' \
  -archivePath <path>.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath <path>.xcarchive \
  -exportOptionsPlist <opts>.plist -exportPath <dir> -allowProvisioningUpdates
```

with `method: app-store-connect`, `teamID: JWAX6S948T`, `signingStyle: automatic`, and
`destination: upload`. `destination: export` writes a local `.ipa` without uploading — use that
to inspect a build before committing to a build number.

Uploading authenticates through Xcode's signed-in account; **no API key exists** in
`~/.appstoreconnect/private_keys/` and none is needed for this path.

### Outstanding in App Store Connect (owner actions, not code)

1. **Export Compliance** must be answered before the build is installable. The app transmits
   nothing and has no backend — the standard no-non-exempt-encryption answer applies.
2. **Internal testers only.** External testing triggers Beta App Review, and a coaching app
   that cannot yet connect coaches to clients is exactly what a reviewer would question.

## Constraints — do not break these

1. **Local-only, TestFlight only. Not the App Store.** The product needs coach↔client delivery,
   which needs a backend that does not exist.
2. **Archive with `Staging`, never `Release`.** Release has no `LOCAL_IDENTITY`, so a Release
   archive shows every tester a sign-in wall they cannot pass. The scheme is already configured;
   do not "fix" it. Verified in the uploaded build: 4 `LOCAL_IDENTITY` symbols present.
3. **`LOCAL_IDENTITY` is Debug + Staging only.** Never `#if DEBUG` alone — Staging is a
   release-style build. `Scripts/check-release-isolation.sh <app-bundle>` proves a Release
   binary carries no local-identity or development symbols. Keep it passing.
4. **The published notice must stay true of the app.** It states the app transmits nothing, has
   no third-party processors, and offers no export/deletion/consent-withdrawal. If any of that
   changes, the notice changes **in the same release** (`LEGAL_CHECKLIST.md` #14, web repo).
5. **Release keeps `UnavailableAuthProvider`** so an accidental App Store submission fails closed.
6. **An unsigned Staging build cannot create a local profile** (no keychain-access group). Build
   Staging *signed* to test by hand. See `docs/BUILD_AND_TEST.md`.

## Signing state — read before the next archive

- Local keychain holds **two Apple Development certificates only** (both common-named
  `D57QP5WB96`; `codesign` resolves the team correctly to `JWAX6S948T`).
- **No Apple Distribution certificate is in the local keychain**, yet the uploaded IPA was
  signed `Apple Distribution: AIMAL MAZIDI (JWAX6S948T)`. Xcode minted one during export and did
  not persist it. Whether one now exists in the Apple account can only be confirmed in the
  portal. This matters: Apple caps distribution certificates at 3, and each export may create
  another. **Check the portal before repeated archives** rather than discovering the cap later.
- Registering the phone created a *personal-team* (`D57QP5WB96`) certificate, not a team one.
  Connecting a device is not the same as registering it to the team; the device list at
  developer.apple.com is what `-allowProvisioningUpdates` reads.

## Documentation gaps — one is significant

- **ADR-0013 is not on `main`.** `docs/architecture/adr/` jumps 0012 → 0014. ADR-0013 and its
  two supporting documents live only on the unmerged branch `feature/backend-provider-decision`
  (local and on `origin`), 3 commits, **documentation only**:
  - `docs/architecture/adr/ADR-0013-backend-provider-selection.md`
  - `docs/architecture/backend-provider-evaluation.md`
  - `docs/architecture/backend-provider-requirements.md`

  This matters because **merged code cites ADR-0013 in roughly ten places** (`UITests/`,
  `App/Client/Support/HealthPrivacyNotice.swift`, `App/DesignSystem/AccessibilityIdentifiers.swift`)
  for the Art. 9 lawful basis and "Phase 0 gate 4" — pointing at a document `main` does not
  contain. `main` is 27 commits ahead of the branch, but the branch adds only these three files,
  so merging is trivial and conflict-free. **Not merged in this session — it is a call for the
  owner.** Decide deliberately; do not leave it dangling.
- Note ADR-0013 covers *both* the Supabase provider selection and the health-data Art. 9 basis.
  `ADR-0008` separately states no concrete provider is chosen — read ADR-0013 before assuming
  the two conflict.

## Known gaps — all deliberate, all documented

- **No backend.** ADR-0013 selected Supabase Pro (London) but is **Accepted for provider
  selection only**; four Phase 0 gates open (executed DPA with UK Addendum, DPIA, ICO
  registration, solicitor confirmation of the Art. 9(2)(a) basis). `SYNC_BASE_URL` /
  `MEDIA_BASE_URL` empty. **This is the real long pole and none of it is blocked by code.**
- **No in-app account deletion** — issue #9, the only open issue. Not blocking now (no accounts
  created), but Guideline 5.1.1(v) applies the moment account creation ships. Note it would also
  make the published privacy notice untrue — the notice must change in the same release.
- **15 open legal questions** in `mazidiperformance-web/LEGAL_CHECKLIST.md`. Only #3 (does
  consent withdrawal require deleting historical records?) changes code.
- The owner approved publishing the notice **without completed solicitor review** — recorded in
  `LEGAL_CHECKLIST.md` under "Owner decision".
- `docs/KNOWN_ISSUES.md` — M4–M8, L1–L12 open, none blocking. M6, L1 and L2 need no backend and
  are the cheapest things to close.

## Working practices that mattered

- **`xcodebuild` exits 0 on a failed archive.** A failed Staging archive returned exit status 0
  and produced no `.xcarchive`. Never trust the exit code — check for the artefact and grep the
  log for `ARCHIVE SUCCEEDED` / `error:`.
- **XcodeGen silently overrides `TARGETED_DEVICE_FAMILY` set in `settings.base`**, writing its
  own `"1,2"` onto every iOS application target. It must be set on the *target*. The first fix
  attempt regenerated without error and still produced a universal binary. Verify generated
  output: `grep TARGETED_DEVICE_FAMILY MazidiPerformance.xcodeproj/project.pbxproj`.
- Run long `xcodebuild` steps as a **background job writing to a log**, then poll. Silent
  multi-minute foreground builds tripped a watchdog repeatedly.
- **Verify subagent and tool claims independently.** A `git status`, grep or test re-run has
  repeatedly caught claims that were wrong.
- `MANIFEST.sha256` recipe (reproduces the committed file exactly — 635 entries):

  ```bash
  git ls-tree -r HEAD --name-only | grep -v '^MANIFEST.sha256$' | sed 's|^|./|' \
    | LC_ALL=C sort | tr '\n' '\0' | xargs -0 shasum -a 256 > MANIFEST.sha256
  ```

  The null delimiter is required — one tracked path contains a space
  (`design/handoff-current/Mazidi Performance.dc.html`) and plain `xargs` drops it.
- Git identity is `MazidiGroup <aimalmazid@gmail.com>`. Historical commits carry an old address —
  **deliberately not rewritten**, since that would force-push shared history.

## Verify before acting

```bash
cd /Users/mazadi/mazidiperformance
git status && git log --oneline -5
gh pr list --repo MazidiGroup/mazidiperformance --state open
cd Packages/MazidiKit && swift test          # expect 346 tests / 44 suites
security find-identity -v -p codesigning     # expect JWAX6S948T-signed builds; see "Signing state"
shasum -a 256 -c MANIFEST.sha256 | grep -v ': OK$'   # expect no output
curl -s -o /dev/null -w "%{http_code}\n" https://mazidiperformance.mazidigroup.com/privacy
```
