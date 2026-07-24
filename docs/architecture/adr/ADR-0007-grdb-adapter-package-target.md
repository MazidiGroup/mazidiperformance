# ADR-0007 — GRDB adapter as a leaf package target; typed rows + restoring initializers

**Status:** Accepted · 2026-07-24

## Context
Slice 1 shipped with the in-memory reference store only: sessions, set entries, outbox
operations and audit events die with the process, so "survives crash and relaunch"
(VERTICAL_SLICE_1.md, ADR-0003) is only half-true. This milestone adds the durable
SQLite/GRDB store that ADR-0002 decided on. Two placement questions had to be settled:

1. **Where does GRDB-importing code live?** ADR-0001/0002 said "the GRDB adapter lives
   app-side". But the durable store must also persist the **concrete** `SyncOperation`
   (status machine, idempotency key, retry metadata) — and `MazidiSync` depends on
   `MazidiPersistence`, so the adapter can never live inside the `MazidiPersistence`
   target itself without a dependency cycle. An app-side adapter would also be untestable
   by `swift test`, while this milestone's largest deliverable is a persistence test suite.
2. **How do domain values map to rows?** Domain types must not conform to GRDB protocols
   (layering; ADR-0001), yet restored aggregates need states (e.g. a completed session
   with entries) that the mutation-only domain API cannot reach.

## Decision
1. **New leaf target `Packages/MazidiKit/Sources/MazidiPersistenceGRDB`** (product
   `MazidiPersistenceGRDB`), depending on `MazidiPersistence`, `MazidiSync`,
   `MazidiDomain`, `MazidiFoundations` and **GRDB 7 (resolved 7.11.1)**. It implements the
   existing store protocols — `WorkoutSessionRepository`, the **generic**
   `SyncOperationStore` (specialised to `SyncOperation`), `AuditEventStore` — in one
   `GRDBStore` over a `DatabaseWriter`. Nothing else may import GRDB: not `MazidiDomain`,
   not services, not sync transports, not SwiftUI views. The app's composition root is the
   only app-side code that touches the new product, and only to construct the store.
   *This amends ADR-0001/0002's "adapter lives app-side" placement.* The layering intent
   (GRDB confined behind the persistence contracts) is unchanged; only the physical home
   moves into the package so `swift test` covers it and the in-memory/GRDB contract test
   suite required by ADR-0002 can exist.
2. **Mapping via dedicated record types + restoring initializers.** Private GRDB record
   structs (`FetchableRecord`/`PersistableRecord`) map columns; domain types stay free of
   GRDB. Aggregates gain explicit `init(restoring:)` initializers (`WorkoutSession`,
   `SyncOperation`) documented as persistence-restoration entry points — reconstruction is
   explicit and typed rather than smuggled through Codable blobs of whole aggregates.
3. **Typed columns first; Codable blobs only where a value is an opaque snapshot:**
   the assigned-workout snapshot (immutable per-session copy of coach config — no query
   reaches inside it; normalising it would pre-build the programme-builder domain),
   the type-aware `SetEntry.Value`, the `RestTimer` value, and operation/audit payloads
   (already `Data`/dictionary by contract). Everything queried, ordered, or constrained —
   ids, phases, epochs, sequences, statuses, idempotency keys, timestamps — is a real column.
4. **One transaction per atomic unit** (ADR-0003): `saveAtomically` writes the session row,
   its child rows and the outbox rows inside a single `DatabaseWriter.write`. WAL journal
   mode via `DatabasePool` in the app; in-memory `DatabaseQueue` in tests.
5. **Corruption/open policy:** if the database cannot be opened or migrated, the store
   moves the damaged file aside (`<name>.corrupt-<timestamp>`, preserved for diagnostics —
   never silently deleted) and starts a fresh database; the event is logged. Destructive
   reset is never a normal migration strategy (see MIGRATIONS.md).

## Consequences
- Building/testing the **whole** package now requires a platform GRDB supports (Apple
  platforms; this repo's CI runs macOS). The platform-neutral targets remain individually
  buildable off-Mac (`swift build --target MazidiDomain` etc.); ADR-0001's Windows-host
  motivation is historical — development and CI are macOS now. Recorded honestly here.
- `MazidiPersistenceGRDB → MazidiSync` is a new edge, but a leaf one — no cycle, and the
  generic outbox contract in `MazidiPersistence` is unchanged.
- The shared contract test suite runs against both `InMemoryStore` and `GRDBStore`,
  keeping the reference implementation behaviourally faithful (ADR-0002 requirement).
- Encryption at rest remains **pending DL-07** (SQLCipher decision). This milestone relies
  on iOS Data Protection (complete-until-first-unlock class) and documents the gap — no
  fabricated security claims.
