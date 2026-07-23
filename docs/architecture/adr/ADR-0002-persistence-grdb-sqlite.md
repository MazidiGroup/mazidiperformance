# ADR-0002 — Persistence: SQLite (GRDB) behind repository protocols; explicit versioned migrations

**Status:** Accepted · 2026-07-23

## Context
Offline-first workout execution requires durable local writes, transactional operation-queue enqueue, crash recovery, and eventually encrypted storage. SwiftData (iOS 17+) is attractive but its migration story and background-actor behaviour are weaker fits for a sync-heavy, transaction-heavy app; Core Data is mature but verbose and hard to reason about for hand-written SQL migrations.

## Decision
- Local store: **SQLite via GRDB** in the app target. WAL mode. One database per signed-in identity.
- `MazidiPersistence` (in MazidiKit) defines repository protocols and a full **in-memory reference implementation** used by unit tests and Windows builds.
- Migrations: forward-only, numbered, registered in code (`DatabaseMigrator`), each recorded in `docs/architecture/MIGRATIONS.md`. No lightweight/silent migration.
- Domain writes and their audit events and sync operations are committed in **one transaction**.
- Encryption at rest: SQLCipher via GRDB is the intended path — **pending decision DL-07** (license/binary-size review); until then rely on iOS Data Protection (complete-until-first-auth) and document the gap.

## Consequences
- Deterministic, reviewable schema history; testable migrations.
- The in-memory implementation must be kept behaviourally faithful (shared contract test suite runs against both implementations on macOS).

## Alternatives
SwiftData (immature migrations for this workload), Core Data (opaque), Realm (external dependency risk, sync product entanglement) — all rejected.
