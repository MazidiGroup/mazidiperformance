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

## Resolved

### M1 — `resumeWorkout()` on an already-active restored session *(resolved)*
- **Fixed in:** the GRDB durable-persistence milestone (`1b19ace`, `d4e8555`).
  `WorkoutSessionService.resume()` (and `pause()`) are idempotent no-ops when the session is
  already in the target phase; a restored still-`.active` session resumes silently.
- **Proven by:** `pauseAndResumeAreIdempotent` and `restoredActiveSessionResumesWithoutError`
  in `MazidiServicesTests`.

### M2 — Navigation proceeded even if resume failed *(resolved)*
- **Fixed in:** `d4e8555`. `ClientWorkoutModel.resumeWorkout()` returns success and
  `ClientRootView` appends the active route only when resumption held; failures surface the
  error and stay on Today.
- **Proven by:** the resume path of `testRelaunchRestoresUnfinishedWorkoutAndCompletionIsFinal`
  (successful-resume navigation) plus the idempotent-resume service tests removing the
  spurious-failure path that previously made this reachable.

### M3 — Pausing while already paused surfaced a needless alert *(resolved)*
- **Fixed in:** `1b19ace`. `service.pause()` is idempotent; re-tapping Pause while paused
  opens the options sheet without an error alert.
- **Proven by:** `pauseAndResumeAreIdempotent` in `MazidiServicesTests`.

---

## Medium

### M7 — Local-lock state has no enforcement policy or biometrics
- **Where:** `AuthPhase.locked`, `SessionRootView` lock surface (ADR-0008).
- **Impact:** The locked state exists in the machine and UI (with unlock wiring), but
  nothing triggers it automatically and no biometric/passcode check gates unlock — it is
  scaffolding, honestly labelled, not a security control yet.
- **Why not fixed now:** Biometric policy (13c) needs product decisions (when to lock,
  fallbacks, grace) and LocalAuthentication wiring — its own slice.
- **Owning milestone:** security/settings slice (turn 13c).
- **Acceptance:** lock triggers per policy, unlock requires biometric/passcode, states
  and copy match 13c, tested.

### M8 — Sign-out audit event is best-effort and unordered with close
- **Where:** `ClientEnvironment.invalidate()`.
- **Impact:** The local `signedOut` audit event is appended in a detached task just
  before the store closes; on a race it may be dropped (sign-out still completes). No
  data loss, but the audit trail can miss the entry.
- **Why not fixed now:** Making it strictly ordered means teaching the session layer to
  await account-store writes during teardown; deferred with the backend audit-sync work
  (ADR-0006 R-02).
- **Owning milestone:** backend sync slice.
- **Acceptance:** sign-out awaits the audit append (with timeout) before close; test
  proves presence after relaunch.

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

### L5 — Quarantined-database retrieval waits on support/export UI
- **Where:** `GRDBStore.open` corruption policy (MIGRATIONS.md); Today's
  `store_recovery_notice`.
- **Impact:** A damaged database is preserved as `.corrupt-<timestamp>` and the client is
  told honestly that data was set aside — but there is no in-app way yet to export the
  quarantined file or hand it to support, and no repair attempt is made (deliberately —
  no speculative repair engine).
- **Why not fixed now:** Retrieval/export belongs to the account/support/export surface
  (turn 13g), which does not exist yet; building it ad hoc here would fabricate flows the
  design hasn't approved.
- **Owning milestone:** account/privacy settings slice (turn 13).
- **Acceptance:** a support/export path can surface and transmit the quarantined file with
  the user's consent, after which this notice links to it; quarantined files remain
  preserved untouched until then.

### L6 — Media cache validated-read re-hashes on the presentation path
- **Where:** `MediaCacheReader.validatedURL` (`Packages/MazidiKit/Sources/MazidiContent`),
  used by `CatalogueMediaResolver.posterURL/clipURL` (ADR-0011 §4/§5).
- **Impact:** To guarantee a corrupt/same-size-tampered cache entry is never presented,
  the synchronous read re-hashes the file (SHA-256) each time it is resolved. Today this
  has **zero runtime cost** because the cache is always empty (no media backend exists,
  R-02, so nothing is ever downloaded and every slug resolves at the bundled tier). Once a
  real origin lands, re-hashing a multi-MB video on every resolve would be wasteful.
- **Why not fixed now:** A validation memo (cache the "validated" verdict keyed by object
  key + file size/mtime so re-hash runs once per file) is a backend-era optimization; the
  bytes correctness rule takes precedence and there is no cost to pay until downloads exist.
- **Owning milestone:** media-backend slice (with `MEDIA_BASE_URL` / the download path).
- **Acceptance:** validated cache reads re-hash at most once per cached file version;
  same-size corruption is still rejected before presentation; covered by a test.

### L7 — Remote media tier is inert until a media origin is configured
- **Where:** `RemoteMediaOrigin` from `MEDIA_BASE_URL` (empty in all shipped
  `Config/*.xcconfig`); `CatalogueMediaResolver` remote tier; `MediaRequestCoordinator` /
  `MediaCache` download path (ADR-0011 §4/§6).
- **Impact:** The full 206-clip library is not deliverable on device yet: with no origin,
  the remote fetch/download/cache path is never exercised at runtime, and only the bundled
  representative set (2 clips + 8 posters) plays; everything else shows the honest
  name+icon fallback. This is by design (no backend, R-01/R-02) — the contracts, cache,
  fetcher, coordinator and their tests all exist and are green.
- **Why not fixed now:** No content backend/CDN exists; fabricating live delivery would
  violate the honesty rule.
- **Owning milestone:** media-backend slice.
- **Acceptance:** with `MEDIA_BASE_URL` configured, media downloads validate + cache +
  present through the existing tiers; retry surfaces on failure; verified end to end.

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
