# ADR-0009 — Coach programming & workout assignment (first Coach→Client slice)

**Status:** Accepted · 2026-07-24

## Context
Slice 1 executes a client workout from a fixture `AssignedWorkout`. This slice adds the
smallest complete Coach→Client workflow (turn 6 panels 6a–6i, prescriptions 6e/7d/7j,
alternatives 7e): coach authors and publishes a workout, assigns it to a client, the
client executes it through the existing session architecture, completion links back.
No backend exists (R-01/R-02); account databases are deliberately isolated (ADR-0008).

## Identities & domain model (MazidiDomain, Foundation-only)
- **`WorkoutTemplate`** — coach-owned, mutable *draft* container: `Identifier<WorkoutTemplate>`,
  title, ordered `[PrescribedExercise]`, `updatedAt`, `publishedVersionCount`. Lives only
  in the coach's account database (ownership implicit in account scoping).
- **`WorkoutTemplateVersion`** — **immutable** publication snapshot:
  `Identifier<WorkoutTemplateVersion>`, `templateID`, monotonic `versionNumber`, frozen
  content (title + exercises), `publishedAt`. Never edited after creation.
- **`PrescribedExercise`** — id, `ExerciseSlug`, explicit `order`, `SetPrescription`,
  `restSeconds`, optional `tempo`, optional `coachNotes`, `approvedAlternatives` (7e).
- **`SetPrescription`** — type-aware target (mirrors execution's `Prescription`):
  repsAndLoad(sets, repRange, loadKg?) · repsOnly · timed · distance ·
  effort(sets, targetRPE) — each with optional per-set RIR/RPE annotation — plus
  **`.unsupported(description)`**: a combination the execution engine cannot yet run is
  representable and displayed, never coerced; validation blocks *publishing* a template
  containing one (drafts may hold them).
- **`WorkoutAssignment`** — `Identifier<WorkoutAssignment>`, `templateID` + `versionID`
  (immutable reference), `versionNumber`, frozen `content` snapshot, `assigneeAccountRef`
  (opaque account string — domain stays MazidiAuth-free), `assignedAt`, `status`,
  `completedSessionID?`, `completedAt?`.
- **Assignment lifecycle:** `queued → started → completed`, with `cancelled` allowed from
  queued/started. `queued` means *created locally and queued for delivery* — never
  presented as "client has received it" (no backend can confirm delivery yet).
  Transitions are guarded domain methods; completion is idempotent-guarded (a completed
  assignment cannot complete again — relaunch cannot duplicate it).
- **Completion linkage:** `WorkoutSession` gains optional `assignmentID`; completing such
  a session marks the assignment completed with the session id in the same local
  transaction (client DB holds both rows).

## Editing & immutability rules
- Editing a template mutates the **draft** only. Publishing snapshots the draft into a
  new immutable version (`versionNumber = previous + 1`).
- Assignments freeze both the version reference **and a content snapshot** — later
  template edits/publications never rewrite existing assignments, in-progress sessions,
  or completed history (the session additionally snapshots its `AssignedWorkout`, as in
  slice 1). Completion records preserve exactly what was prescribed at assignment time.
- Template deletion is **not implemented** this slice (MVP rule): the UI offers no
  delete, so no orphaning is possible; a future deletion must archive, not cascade.

## Mapping to execution
`WorkoutTemplateVersion.content.assignedWorkout()` converts prescriptions into the
existing `AssignedWorkout`/`AssignedExercise`/`Prescription` values that seed a
`WorkoutSession` — the session engine, set logging, swaps, rest timers, restoration and
completion finality are unchanged. Per-set RIR/RPE annotations and tempo ride along as
coach-note text in this MVP (documented simplification: execution targets remain
per-exercise, per 7d).

## Persistence (migration v2, forward-only)
New tables in the shared schema (account-scoped databases, ADR-0008):
- `workout_template` (draft content as JSON blob — coach-authored config snapshot,
  ADR-0007 §3 blob rule), `template_version` (immutable rows; UNIQUE(template_id,
  version_number)), `workout_assignment` (status columns typed; content snapshot blob;
  index on status + assignee).
- `workout_session` gains nullable `assignment_id`.
`ProgrammingRepository` contract in MazidiPersistence + in-memory reference impl;
GRDBStore implements it. Every coach mutation and assignment operation commits with its
outbox operation in **one transaction** (ADR-0003 invariant, same
`saveAtomically`-style writes).

## Outbox & audit (typed, additive)
- `SyncOperation.Kind` += `templateDraftSaved`, `templatePublished`,
  `assignmentCreated`, `assignmentStatusChanged`. Aggregates: template id for template
  ops; assignment id for assignment ops. Idempotency keys and per-aggregate sequences as
  before; identifiers deterministic.
- `AuditEvent.Kind` += `workoutDraftCreated`, `workoutAssigned`, `assignmentStarted`,
  `assignmentCompleted`, `assignmentCancelled` (uses existing `programmePublished` for
  publication). Audit subjects carry ids only — never notes or prescription content.

## Authorization boundaries (local now, server later — stated honestly)
- Programming write APIs are reachable only from the Coach shell (coach role claims,
  ADR-0008 routing); the client surface only reads assignments addressed to its account.
  Account-scoped databases make cross-account isolation structural: another coach's
  drafts or another client's assignments are in databases this session cannot open.
- Signed-out: stores close on sign-out (ADR-0008) — programming repositories throw.
- **Remaining server requirement (R-01/R-02):** relationship-level authorization
  (which coach may assign to which client) and delivery cannot be enforced locally and
  are explicitly deferred; recorded in SECURITY_BOUNDARIES.md.

## Delivery: DEBUG-only development relay
Account databases are isolated and there is no backend, so a **`DevelopmentAssignmentRelay`**
(app target, `#if DEBUG`, fixture-labelled) hands a published assignment from the dev
coach's database to the dev client's database on the same device — it stands in for the
future delivery backend so the end-to-end journey is exercisable and testable. Honesty
rules: the coach-side status remains **"Queued — delivery confirmation arrives with the
backend"** even after the local relay copies it; the relay never runs in Release; the
outbox operation remains the durable record of intent. Completion flows back the same
dev-only way (client → coach status), with the same honest labelling.

## Offline behaviour
Drafts, publications and assignments are local-first writes with queued outbox ops —
fully offline-capable. The client opens already-delivered assignments offline; completion
enters the existing outbox. UI language: "Saved on this phone" / "Queued to send" —
never claiming remote delivery or receipt (4i honesty).

## Consequences
- The client fixture workout remains as the **no-assignment fallback** for Today until
  the backend exists (documented; keeps existing journeys/tests meaningful).
- Deletion, template libraries (6g), AI drafts, assistant permissions, periodisation,
  and live-programme editing rules (6i) are out of scope; 6i's "editing a live
  programme" is satisfied structurally by version immutability this slice.
