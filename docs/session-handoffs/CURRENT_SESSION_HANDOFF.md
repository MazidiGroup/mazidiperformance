# Session handoff — 2026-07-24 (evening)

Written for a fresh Claude Code session with no access to the prior conversation.
Everything below was verified against the repository with Git/`gh`/`swift test` at
writing time — re-verify before editing (state moves).

## Repository state (verified)

- **Root:** `/Users/mazadi/mazidiperformance`
- **Branch:** `main`, tracking `origin/main`, **0 ahead / 0 behind**
- **HEAD:** `c6a86027467f19481b620e0206da3665146b8cb1`
  ("Merge Coach programming and Client workout assignment slice")
- **origin/main:** same commit (level)
- **Working tree:** clean — no staged, modified, or untracked files (this handoff file
  is the only untracked artifact once written, left uncommitted on purpose so `main`
  isn't polluted; commit it to the next milestone branch if wanted)
- **No running/interrupted commands.** All background builds/tests from the previous
  session completed; nothing needs rerunning.
- **PR #5** (Coach programming slice) is **MERGED** (2026-07-24T18:32Z, merge commit
  `c6a8602`). Branch CI for its head `6240b10` completed **success**
  (run 30116429434). A post-merge CI run on `main` (run 30117340209, sha `c6a8602`)
  was in progress at handoff time — check its outcome:
  `gh run list --repo MazidiGroup/mazidiperformance --limit 3`
- **The next milestone branch `feature/exercise-library-content-pipeline` does NOT
  exist** locally or on origin. **Work on that milestone has NOT begun.** No product
  changes exist beyond `main`.

## Completed milestones (merged into `main` — do not recreate or broadly refactor)

1. **Foundation + Client workout slice** — `Packages/MazidiKit` split
   (MazidiFoundations/Domain/Persistence/Sync/Services/Networking), workout-session
   state machine, type-aware prescriptions, offline outbox with idempotency keys +
   per-aggregate ordering (ADR-0003), audit chain (ADR-0006), Client UI (Today →
   overview → active → complete) with design tokens + accessibility, honest sync
   status wording (4i).
2. **Durable GRDB persistence** — leaf target `MazidiPersistenceGRDB` (the only
   GRDB importer, ADR-0007), migration `v1-workout-persistence`, atomic
   session+outbox transactions, typed corruption recovery (quarantine, never
   silent-empty), rest-timer/position restoration, relaunch UI journey.
3. **Auth/session/account boundaries (ADR-0008)** — `MazidiAuth` (AuthPhase reducer,
   SessionCoordinator with generations + deduplicated refresh, CredentialStore),
   Keychain adapter (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`),
   role-claim routing, account-scoped DB dirs
   `accounts/<hex32 SHA-256 domain-tagged>` under
   `Application Support/MazidiPerformance/`, close-before-transition, DEBUG dev
   provider (`dev-client-001/002`, `dev-coach-001`) with Release exclusion proven by
   binary greps + tests, Keychain-free UI-test credential stores (CI builds unsigned).
4. **Coach programming + assignment slice (ADR-0009)** — templates → immutable
   versions → assignments with frozen snapshots, migration `v2-coach-programming`,
   ProgrammingRepository (generic outbox param, atomic writes), service
   start/completion linkage with duplicate-completion prevention, Coach UI (list/
   editor/prescription/assign/status), Client Today assignment surfacing with fixture
   fallback, DEBUG-only `DevelopmentAssignmentRelay` (delivery stand-in; coach status
   stays "Queued — delivery confirms with backend").

**Boundaries that must hold:** GRDB only inside `MazidiPersistenceGRDB`; provider
SDKs/auth types out of domain/views/services; role from validated claims only;
account DBs isolated + closed on transition; immutable versions/snapshots never
rewritten; no fabricated backend; every mutation atomic with its outbox op;
DEBUG-only fixtures with Release-isolation proofs; Swift 6.1 CI constraints
(no parameterized protocols in compositions; XCUITest is @MainActor).

## Current milestone: `feature/exercise-library-content-pipeline`

**NOT STARTED.** No branch, no ADR, no code. Objective (from the milestone brief):
canonical exercise catalogue; deterministic exercise + media identifiers; read-only
source-library audit tooling; deterministic versioned media manifest; review
reporting for ambiguous/unmatched mappings; provider-neutral remote-media
resolution; bounded validated media caching; coach search/filter/preview with
stable-ID selection; client media resolution + legacy-fixture compatibility.

## NON-NEGOTIABLE source-library rule

`/Users/mazadi/Documents/MazidiPerformance/Animation_Pack_20-07-26` is **strictly
read-only** (also stated in CLAUDE.md). Never rename/move/delete/rewrite its files,
never generate anything inside it, never commit it, never copy the complete library
into the repo or app bundle. **Verified contents at handoff:** three zip archives —
`full-library-NTRkdOevZfhYISO5pBWekIctpb7YNr.zip`, `full-library-metadata.zip`,
`full-library-posters.zip` (audit tooling must therefore read from zips or extract to
an isolated working area). All generated audit/manifest/report/poster/staging output
goes to a **Git-ignored** working directory (add an ignore rule for it).

## Approved design & media boundaries

- Approved design source: `design/handoff-current` (frozen; tag
  `design-handoff-v1.0.0`); asset rules:
  `design/handoff-current/handoff/asset-cdn-integration.md`, `docs/ASSET_PIPELINE.md`;
  client copy layer: `content/exercises/client-layer/` (draft status; slugs are the
  join key).
- Tracked media stays limited to the approved representative set (2 app-bundled
  clips + the 12-clip/posters handoff sample). No full library in Git.
- No production CDN provider/upload fabrication; no credentials, bucket keys,
  signed URLs, or machine-specific absolute paths inside generated manifests.

## Facts verified from the repository (not chat memory)

- Package tests: **134 tests / 18 suites — pass** (run on `main` at `c6a8602`).
- UI tests: **13 methods** (6 ClientWorkoutUITests, 3 ClientAuthUITests,
  3 CoachProgrammingUITests, 1 PlaceholderUITests).
- Migrations registered: `v1-workout-persistence`, `v2-coach-programming`
  (`Packages/MazidiKit/Sources/MazidiPersistenceGRDB/GRDBSchema.swift`).
- GRDB pinned **exact: "7.11.1"** in `Packages/MazidiKit/Package.swift`
  (manifest-as-lockfile; upgrade procedure in `docs/BUILD_AND_TEST.md`).
- `MANIFEST.sha256` convention: covers all tracked files (committed-blob sha256,
  excludes itself); regenerate after tracked changes (recipe in git history:
  "Regenerate MANIFEST.sha256" commits).

## Decisions still required (exercise-library milestone — none made yet)

Canonical exercise-ID strategy; immutable media-ID strategy; catalogue schema and
versioning; mapping confidence + review-status model; legacy fixture-slug migration;
remote object-key convention; poster/video relationship; checksum + cache policy;
unsupported/malformed media handling; ambiguous filename handling; offline fallback
order; historical assignment compatibility. **Record these in the milestone ADR
(ADR-0010) before implementation. Do not invent decisions as already made.**

## Work completed in this session

The prior session completed the Coach programming milestone (merged as PR #5) and
opened/verified that PR. **No product changes exist for the exercise-library
milestone: "No product changes completed in this session" applies to the new
milestone.** No uncommitted work exists.

## Current failures and risks

- **No failing tests or compiler errors.** All 134 package tests and 13 UI tests
  pass; Debug and Release simulator builds succeed.
- Post-merge CI on `main` (run 30117340209) was still in progress — verify it
  finished green before branching (expected to: the identical tree passed on the
  branch as run 30116429434).
- CI toolchain gap (recurring, documented in `docs/BUILD_AND_TEST.md`): CI pins
  **Xcode 16.4 / Swift 6.1 / iOS 18.5 sim, unsigned builds** — local is Xcode 26.6 /
  Swift 6.3 / iOS 26.5. Known 6.1 breakers: parameterized protocols in protocol
  compositions; non-@MainActor XCUITest code; Keychain unusable in unsigned builds
  (use the existing DEBUG env-keyed test credential stores). Reproduce CI locally by
  adding `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` to xcodebuild test.
- Known issues tracker: `docs/KNOWN_ISSUES.md` (M4-M8, L1-L5 open; none blocking).

## Next actions, in order

1. Read `CLAUDE.md`.
2. Read this handoff.
3. Verify Git state independently (`git status`, `git log --oneline -5`,
   `gh run list --limit 3`).
4. Read ADR-0001…0009 (`docs/architecture/adr/`), `docs/architecture/ARCHITECTURE.md`,
   `docs/architecture/MIGRATIONS.md`, `docs/architecture/SECURITY_BOUNDARIES.md`,
   `docs/ASSET_PIPELINE.md`, `design/handoff-current/handoff/asset-cdn-integration.md`,
   `content/exercises/client-layer/README.md`, `docs/KNOWN_ISSUES.md`.
5. Create the milestone branch from current `main` and push with tracking:
   `git checkout -b feature/exercise-library-content-pipeline` +
   `git push -u origin feature/exercise-library-content-pipeline`.
6. Audit the source library **strictly read-only** (list zip contents without
   extraction first, e.g. `unzip -l`; if extraction is needed, extract into a NEW
   git-ignored working dir, never into the source folder).
7. Write ADR-0010 (exercise catalogue / content pipeline) covering every
   "decisions still required" item above, before any implementation.
8. Implement in focused commit groups with tests; run the full validation ladder;
   regenerate `MANIFEST.sha256`; push. Never merge into `main`.

## Validation commands (from docs/BUILD_AND_TEST.md, .github/workflows/ci.yml, and session history)

```bash
# Package tests
cd Packages/MazidiKit && swift test

# Clean dependency resolution check (pin must stay exactly 7.11.1)
cd Packages/MazidiKit && rm -rf .build Package.resolved && swift package resolve

# Project generation
xcodegen generate

# Debug build + full app/UI suite (add the CODE_SIGNING flags to mirror CI)
xcodebuild -project MazidiPerformance.xcodeproj -scheme MazidiPerformance \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test

# Release build
xcodebuild -project MazidiPerformance.xcodeproj -scheme MazidiPerformance \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

# Manifest regeneration (after committing tracked-file changes)
git ls-files | grep -vx "MANIFEST.sha256" | LC_ALL=C sort | while read -r f; do
  printf '%s  ./%s\n' "$(git cat-file blob "HEAD:$f" | shasum -a 256 | cut -d' ' -f1)" "$f"
done > MANIFEST.sha256

# Hygiene checks
git status --porcelain
git ls-files | grep -iE "\.sqlite|\.xcresult|\.xcodeproj/|\.build/" || echo clean
```
