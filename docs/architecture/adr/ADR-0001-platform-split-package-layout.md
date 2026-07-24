# ADR-0001 — Platform-split layout: Xcode app shell + platform-neutral MazidiKit package

**Status:** Accepted · 2026-07-23

## Context
The product is a native iOS app (Swift/SwiftUI per the brief). The current development host is Windows 11 with no Xcode and no macOS available; the brief requires domain behaviour to be genuinely tested, offline/sync logic to be robust, and progress to be real rather than claimed.

## Decision
1. All domain logic, state machines, services, sync, persistence contracts and networking contracts live in a SwiftPM package `Packages/MazidiKit` that imports only Foundation-compatible APIs — no UIKit, SwiftUI, Combine-on-Apple-only, GRDB or other Apple-only frameworks in its dependency graph.
2. The Xcode app target (`App/`, generated from `project.yml` via XcodeGen on macOS) contains SwiftUI views, navigation, and platform adapters (Keychain, EventKit, HealthKit, AVFoundation, push, GRDB persistence adapter).
3. `MazidiKit` must build and pass tests with `swift build` / `swift test` on macOS, Linux and Windows.

## Consequences
- Domain tests run on the current Windows host and on cheap Linux CI, not just macOS runners.
- Persistence in the package is protocol + in-memory reference implementation; the GRDB/SQLite adapter is app-side and integration-tested on macOS.
- Slight duplication (DTO/entity mapping at the adapter seam) accepted as the cost of testability.
- The one-device rule, offline queue, idempotency and conflict logic — the highest-risk behaviour in the product — are all unit-testable without a simulator.

## Alternatives considered
- Single Xcode project, no package: untestable off-Mac, rejected.
- Kotlin Multiplatform / C++ core: violates the native-Swift direction, rejected.
