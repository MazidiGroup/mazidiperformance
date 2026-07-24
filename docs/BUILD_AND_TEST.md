# Build & test commands

## MazidiKit (domain package — macOS / Linux / Windows)

Requires Swift 6.0+ (`swift.org` toolchain on Windows/Linux; Xcode 16+ on macOS).

```bash
cd Packages/MazidiKit
swift build
swift test
```

On Windows PowerShell the same commands apply once the Swift toolchain is on PATH.

## App target (macOS only — requires Xcode 16+)

The `.xcodeproj` is generated, not committed:

```bash
brew install xcodegen        # once
xcodegen generate            # from repo root, reads project.yml
open MazidiPerformance.xcodeproj
```

Command-line build & test:

```bash
xcodebuild -project MazidiPerformance.xcodeproj -scheme MazidiPerformance \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build test
```

## Dependencies — updating GRDB (deliberate, never silent)

GRDB is pinned **exactly** in `Packages/MazidiKit/Package.swift`
(`.package(url: …GRDB.swift.git, exact: "7.11.1")`). `Package.resolved` is not
committed, so the manifest's exact requirement *is* the lockfile: local builds, package
tests and CI all resolve the identical version, and CI can never drift to a newer release
without a reviewed manifest change.

To move to a later GRDB deliberately:

1. Read the GRDB release notes for every version being crossed (migration notes,
   SQLite/WAL behaviour, minimum platforms, Swift version).
2. Edit the `exact:` requirement to the new version in `Packages/MazidiKit/Package.swift`.
3. Clean-resolve and verify: `rm -rf .build Package.resolved && swift package resolve`,
   confirm the resolved version matches the new pin.
4. Run the full ladder locally: `swift test` (all suites, including
   `MazidiPersistenceGRDBTests`), `xcodegen generate`, Debug simulator test suite,
   Release simulator build.
5. Commit the manifest change on its own with the release-notes rationale; let CI confirm
   on the PR before merge.

## Static checks

```bash
swiftformat --lint .   # config in .swiftformat (pending)
swiftlint              # config in .swiftlint.yml (pending)
```

## Authentication in development and tests (ADR-0008)

- **Dev identities (DEBUG only):** `dev-client-001`, `dev-client-002`, `dev-coach-001`
  (plus deliberately broken `dev-no-role` / `dev-conflicted` fixtures for error-state
  tests). Compiled out of Release entirely; Release's provider slot fails typed and
  honest (no backend exists — R-01).
- **UI-test launch environment (DEBUG only):**
  - `MAZIDI_STORE_MODE=ephemeral` — fresh in-memory database for the process.
  - `MAZIDI_STORE_DIR=<base>` — account-scoped durable store under an explicit base.
  - `MAZIDI_AUTH_RESET=1` — forget any stored session at launch (the simulator Keychain
    outlives app launches; journeys state their starting condition explicitly).
- Tokens live in the Keychain only (`com.mazidigroup.mazidi.auth`,
  after-first-unlock-this-device-only). Never commit, log, or store credentials anywhere
  else; `AuthCredentials`' description redacts tokens by construction.
- **Credential store under UI test (DEBUG only):** CI builds the app unsigned
  (`CODE_SIGNING_ALLOWED=NO`), and an unsigned app on the simulator cannot use the
  Keychain (`SecItemAdd` → missing entitlement). So when a UI-test launch variable is
  present, `SessionModel` substitutes a Keychain-free store: `DevelopmentFileCredentialStore`
  under `MAZIDI_STORE_DIR` (fixture `dev.*` tokens in the test's own temp directory, so a
  development session survives relaunch) or `InMemoryCredentialStore` under
  `MAZIDI_STORE_MODE=ephemeral`. Normal Debug runs and **all** Release runs use the real
  Keychain — the substitution is `#if DEBUG` and only ever engaged by explicit test
  configuration. To reproduce CI locally, add `CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO` to `xcodebuild … test` — a **signed** local run hides this
  class of failure because the app then has a keychain-access group.

## Coach programming slice (ADR-0009)

The Coach shell authors workouts against the bundled fixture exercise library; the dev
relay (`DevelopmentAssignmentRelay`, DEBUG only) stands in for the delivery backend so
the Coach→Client journey runs end-to-end on one device. Coach-side assignment status
stays "Queued — delivery confirms with backend" by design; started/completed states
shown to the coach are real client-recorded facts pulled back by the relay. UI tests
share one isolated `MAZIDI_STORE_DIR` base per journey, under which each dev account
gets its hashed directory.

## CI toolchain gap — build against Swift 6.1 (Xcode 16.4), not just local

Local validation runs Xcode 26.x (Swift 6.3); CI pins **Xcode 16.4 (Swift 6.1)** on a
macOS 15 runner with the **iOS 18.5** simulator (see `.github/workflows/ci.yml`). Swift
6.1 is stricter than 6.3 in two ways that have each broken a green-locally build on CI, so
check both before pushing:

- **XCUITest is `@MainActor`-isolated** in the iOS 18.5 SDK — UI-test methods and helpers
  that touch `XCUIApplication`/`XCUIElement` must be `@MainActor`.
- **Parameterized protocols cannot appear in a protocol composition** — `any A & B &
  SyncOperationStore<SyncOperation>` compiles under 6.3 but is rejected by 6.1 with
  "Non-protocol, non-class type … cannot be used within a protocol-constrained type".
  Use a plain parameterized existential (`SyncOutboxStore = any SyncOperationStore<…>`) or
  a small struct of role handles instead of composing it.

The reliable pre-push check is CI itself (the first PR run is required confirmation); a
clean local run does not guarantee CI.

## Current verification status (honest)

- **Dev host is Windows 11.** Xcode targets cannot build here; the app target is scaffolded and documented but **unbuilt** until run on macOS.
- **MazidiKit tests are written but have NOT been executed anywhere yet.** Attempted on this host 2026-07-23:
  - Swift 6.3.3 for Windows installed via `winget install Swift.Toolchain` (twice, both reported success); MSVC 14.51 + Windows SDK 10.0.26100 present; `swift-package.exe --version` ran correctly.
  - **Norton 360 for Gamers silently deletes the toolchain's driver stubs** (`swift.exe`, `swiftc.exe`, `swift-test.exe`, `swift-build.exe`) within seconds of installation — verified by directory listings before/after; no threat log visible via `Get-MpThreatDetection` (Defender is passive; Norton is the active AV). Without `swiftc`, no build can run.
  - Security software was deliberately **not** modified or bypassed. To unblock local testing, the machine's owner can restore the files from Norton's quarantine and add an exclusion for `%LOCALAPPDATA%\Programs\Swift`, then re-run `winget install --id Swift.Toolchain --source winget --force` and `swift test` in `Packages/MazidiKit`.
  - Until then, the definitive test run should happen on macOS (Xcode 16+) or Linux with Swift 6+.
