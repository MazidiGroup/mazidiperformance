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

## Current verification status (honest)

- **Dev host is Windows 11.** Xcode targets cannot build here; the app target is scaffolded and documented but **unbuilt** until run on macOS.
- **MazidiKit tests are written but have NOT been executed anywhere yet.** Attempted on this host 2026-07-23:
  - Swift 6.3.3 for Windows installed via `winget install Swift.Toolchain` (twice, both reported success); MSVC 14.51 + Windows SDK 10.0.26100 present; `swift-package.exe --version` ran correctly.
  - **Norton 360 for Gamers silently deletes the toolchain's driver stubs** (`swift.exe`, `swiftc.exe`, `swift-test.exe`, `swift-build.exe`) within seconds of installation — verified by directory listings before/after; no threat log visible via `Get-MpThreatDetection` (Defender is passive; Norton is the active AV). Without `swiftc`, no build can run.
  - Security software was deliberately **not** modified or bypassed. To unblock local testing, the machine's owner can restore the files from Norton's quarantine and add an exclusion for `%LOCALAPPDATA%\Programs\Swift`, then re-run `winget install --id Swift.Toolchain --source winget --force` and `swift test` in `Packages/MazidiKit`.
  - Until then, the definitive test run should happen on macOS (Xcode 16+) or Linux with Swift 6+.
