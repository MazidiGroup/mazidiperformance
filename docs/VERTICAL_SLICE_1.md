# Vertical slice 1 — Client workout journey (Phase 2)

**Goal:** a client opens today's assigned workout, performs it (sets, rest, swaps, pause/resume), completes it, and the record survives offline, crash, and sync — honestly.

Governing panels: 3a–3f, 4a–4c, 4i, 5a–5g, 7f–7l, 14b, 14f. Governing rules: `functional-rules.md` (exercise content, media), `asset-cdn-integration.md`, ADR-0003.

## Increment order

1. **Domain core (MazidiKit — no UI, runs on Windows):** ✅ started in this branch
   - `WorkoutSession` state machine: notStarted → active ⇄ paused → completed | abandoned; interruption snapshot/restore; one-device epoch supersession → `.supersededReadOnly`.
   - Type-aware `Prescription`/`SetEntry` (reps, load, time, distance, RPE) per 7d/7j.
   - `RestTimerModel` (pure time arithmetic; accessible-numeric-countdown-friendly).
   - Approved-alternative swap honouring coach-ordered alternatives (7e).
   - `SyncOperationQueue`: durable enqueue-with-write, idempotency keys, per-aggregate ordering, retry classification, duplicate prevention, crash-recovery invariant.
   - Unit tests for all of the above (status: written; execution per BUILD_AND_TEST.md).
2. **Persistence adapter (macOS):** GRDB schema v1 (sessions, set entries, operation queue, audit events) + migration 001; contract tests shared with in-memory impl.
3. **UI (macOS):** Client Today (3a) → Workout details (3c/7f) → Active workout (3d/7g) with poster-first media, rest timer (4a), swap sheet (7h), pause/exit/resume (5a/5b/5g), completion (3e). Design tokens only; Dynamic Type AX5; VoiceOver labels; Reduce Motion (14f); accessibility identifiers.
4. **Sync (contract-first):** `WorkoutSyncEndpoint` protocol + simulator; reconnection replay; duplicate-prevention integration tests; honest sync-status UI (4i wording).
5. **QA gate:** accessibility checklist rows for these screens; offline/crash test matrix from 5f/14h.

## Explicitly out of scope for slice 1
Check-ins (3f/4d), progress dashboard (4e/4f), messaging (4h), discomfort report coach side (5d/5e — client report 4c is in), programme building (turn 6).

## Fixtures
Real slugs from `metadata.json` (e.g. `barbell-squat`, `barbell-bent-over-row` — both have bundled MP4s); client copy from the draft content layer **with draft badge**.
