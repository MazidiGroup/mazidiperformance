# Known issues

Accepted, non-blocking defects carried out of the pre-merge review of
`feature/foundation-and-workout-slice` (Client workout slice 1). None is critical or high —
the high-severity findings from that review were fixed on the branch. Each item states its
current impact, why it was deferred, the milestone that should own the fix, and the condition
under which it can be closed.

Do not close an item by deleting it: close it only when the fix is implemented **and** tested,
and record the fixing commit.

Milestone shorthand: **S1-persistence** = slice-1 GRDB persistence adapter (VERTICAL_SLICE_1.md
step 2); **S1-sync-backend** = slice-1 sync against a real `WorkoutSyncEndpoint` (step 4);
**S1-polish** = accessibility/UX polish pass for the client workout screens; **S1-tests** =
additional UI/integration coverage for slice 1.

---

## Medium

### M1 — `resumeWorkout()` calls `service.resume()` on a possibly already-active session
- **Where:** `App/Client/Model/ClientWorkoutModel.swift:135` (`resumeWorkout` → `service.resume()`).
- **Impact:** If a restored session is already in `.active` (not `.paused`), `resume()` throws
  `invalidTransition` and the UI shows a spurious "Can't resume right now" alert.
- **Why not fixed now:** Unreachable today — the in-memory store dies with the process, so a
  restored session is always `.paused` (or absent). It only becomes reachable once sessions
  persist across launches.
- **Owning milestone:** S1-persistence.
- **Acceptance:** `resumeWorkout()` is a no-op (no error) when the session is already active;
  covered by a service/model test that restores an active session and calls resume.

### M2 — Navigation proceeds even if resume fails
- **Where:** `App/Client/ClientRootView.swift:21` (`onResume: … await model.resumeWorkout(); path.append(.active)`).
- **Impact:** `path.append(.active)` runs unconditionally, so a failed resume still navigates
  into the active workout screen (which then reflects the unchanged phase). Tightly coupled to M1.
- **Why not fixed now:** Depends on M1's outcome type; fixing navigation guarding in isolation
  would be speculative before the resume contract is finalized against persistence.
- **Owning milestone:** S1-persistence.
- **Acceptance:** navigation into `.active` occurs only when resume succeeds (resume surfaces a
  success/failure result the router checks); covered by a UI test.

### M3 — Pausing while already paused surfaces a needless alert
- **Where:** `App/Client/Views/ActiveWorkoutView.swift:41` (toolbar Pause → `await model.pause()`).
- **Impact:** If the session is already `.paused` and the user taps the toolbar Pause again,
  `service.pause()` throws `invalidTransition` and shows "Can't pause right now." Minor; the
  inline paused banner is the normal path.
- **Why not fixed now:** Cosmetic; the primary paused-state affordance already works. Belongs
  with the broader transition-guarding cleanup in M1/M2.
- **Owning milestone:** S1-polish.
- **Acceptance:** tapping Pause while paused is a no-op (re-opens the options sheet or does
  nothing), never an error alert.

### M4 — Session epoch hardcoded to `1`
- **Where:** `App/Client/Model/ClientWorkoutModel.swift:126` (`service.start(workout:, epoch: 1)`).
- **Impact:** The one-device epoch is a constant instead of a server-claimed value, so the
  one-device rule can't actually supersede across devices yet.
- **Why not fixed now:** No backend exists (R-01/R-02); `WorkoutSyncEndpoint.claimSessionEpoch`
  is contract-only. Fabricating epoch logic client-side would be dishonest.
- **Owning milestone:** S1-sync-backend.
- **Acceptance:** `epoch` comes from `claimSessionEpoch(workoutID:)`; covered by a sync
  integration test exercising supersession across two simulated devices.

### M5 — No proactive "continued on another device" banner
- **Where:** Client active-workout / today surfaces (superseded state is `WorkoutSession.phase
  == .supersededReadOnly`, handled in the domain but only surfaced on a write attempt).
- **Impact:** A session superseded by a newer epoch becomes read-only, but the client isn't told
  proactively — the state is only surfaced when they next try to write, via the read-only error.
- **Why not fixed now:** Superseding requires the real epoch/sync path (M4); building the banner
  before there's a way to actually get superseded would be untestable end-to-end.
- **Owning milestone:** S1-sync-backend.
- **Acceptance:** entering a superseded session shows an honest, non-colour-only banner
  explaining the one-device rule with the data preserved; verified in the simulator and by a UI
  test driving a simulated supersession.

### M6 — Misleading cross-aggregate enqueue-order comment
- **Where:** `Packages/MazidiKit/Sources/MazidiSync/SyncEngine.swift:39` ("Aggregates are
  processed in enqueue order").
- **Impact:** Comment-only. Aggregates are grouped with `Dictionary(grouping:)`, whose iteration
  order is unspecified across aggregates. The *actual* guarantee — strict ordering **within** an
  aggregate — is correct and unit-tested; only the comment overstates the cross-aggregate
  behaviour.
- **Why not fixed now:** Documentation nit with zero behavioural effect; batched here to avoid an
  unrelated touch to the validated sync engine.
- **Owning milestone:** S1-sync-backend (next time the engine is edited).
- **Acceptance:** comment corrected to state that only within-aggregate order is guaranteed;
  cross-aggregate order is unspecified (or made deterministic if a reason emerges).

---

## Low

### L1 — Legacy accessibility announcement API
- **Where:** `App/Client/Views/ActiveWorkoutView.swift:269` (`UIAccessibility.post(notification:
  .announcement, argument:)`).
- **Impact:** Works correctly; uses the older UIKit announcement API rather than SwiftUI's
  `AccessibilityNotification.Announcement`.
- **Why not fixed now:** Functional; migration is a tidy-up, not a fix.
- **Owning milestone:** S1-polish.
- **Acceptance:** announcements use `AccessibilityNotification.Announcement` (or a documented
  reason to keep the UIKit path); rest-timer-complete announcement still verified with VoiceOver.

### L2 — "Swap" button label wraps at AX5
- **Where:** `App/Client/Views/ActiveWorkoutView.swift:106` (`Label("Swap", …)` beside a long
  exercise title).
- **Impact:** At the largest Dynamic Type sizes the inline Swap control can wrap to "Swa/p".
  Readable and reachable; purely cosmetic.
- **Why not fixed now:** Cosmetic; the row is usable and the accessible label is intact.
- **Owning milestone:** S1-polish.
- **Acceptance:** at AX5 the Swap control reads cleanly (e.g. moved below the title or icon-only
  with an accessible label); verified in the simulator at AX5.

### L3 — `AVPlayer` constructed in `body` in `FullScreenClip`
- **Where:** `App/Client/Views/ExerciseMediaView.swift:213` (Reduce Motion branch:
  `VideoPlayer(player: AVPlayer(url: url))`).
- **Impact:** Under Reduce Motion the full-screen player builds its `AVPlayer` inline in `body`,
  so it is recreated on re-render. Minor inefficiency; the non-Reduce-Motion path uses the
  looping player correctly.
- **Why not fixed now:** Low impact; the full-screen cover is short-lived.
- **Owning milestone:** S1-polish.
- **Acceptance:** the player is held in `@State` (built once); Reduce Motion full-screen playback
  still works (no autoplay/loop) and is verified in the simulator.

### L4 — Missing UI coverage for the swap and offline→synced journeys
- **Where:** `UITests/ClientWorkoutUITests.swift` (covers open / record / pause+resume /
  complete / debug-gating; not swap or connectivity transitions).
- **Impact:** The approved-alternative swap flow and the honest offline→waiting→synced status
  transition are verified only manually / at the unit level (the sync engine has unit tests).
- **Why not fixed now:** The four required slice-1 journeys plus debug-gating are covered; these
  two are additive and were out of scope for the milestone's test set.
- **Owning milestone:** S1-tests.
- **Acceptance:** UI tests cover (a) swapping to an approved alternative and seeing the swapped
  content, and (b) toggling the dev connectivity control and observing the badge move through
  waiting → synced.
