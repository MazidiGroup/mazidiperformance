# Exercise library — app integration review

**Milestone:** `feature/exercise-library-app-integration` (Phase 1, foundation only)
**Date:** 2026-07-24
**Baseline:** `main` @ `6cc4bfd` ("Merge canonical exercise catalogue and content audit
pipeline"). The canonical catalogue + read-only content-audit pipeline (ADR-0010) is
merged; `Packages/MazidiKit/Sources/MazidiContent/` exists.

This document is the grounded, code-cited answer to the ten integration questions plus the
release/UI-test isolation requirements, the migration determination, the complete legacy
fixture-slug → canonical-ID mapping table, and the architecture decision (new ADR vs
ADR-0010 sufficient). It defines *what* the next phases build; it changes no application
code.

---

## 1. How catalogue data is generated and decoded; what to bundle

**Types (`Packages/MazidiKit/Sources/MazidiContent/`):**

- `ExerciseCatalogue` (`CatalogueModels.swift:118`) — envelope: `schemaVersion` (currently
  `1`, `CatalogueModels.swift:119`), `catalogueVersion` (monotonic, bumped only on real
  change — `CatalogueModels.swift:123`), `sourceFingerprint: [String: String]`
  (`metadata.zip`/`posters.zip`/`videos.zip` SHA-256s, no timestamps/paths), and
  `records: [CatalogueRecord]` always sorted by slug (`CatalogueModels.swift:135`). Lookup
  helper `record(for:)` (`CatalogueModels.swift:138`).
- `CatalogueRecord` (`CatalogueModels.swift:73`) — `slug`, classification passthrough
  (`primaryMuscles`, `secondaryMuscles`, `equipment`, `movementPattern`, `difficulty`,
  `tags`), `durationMs`, `poster`/`video` (`MediaAssetRef?`), `availabilityStatus`,
  `contentReviewStatus`. **Carries no client copy** — display names/instructions join by
  slug from the client-content layer (`CatalogueModels.swift:70-72`).
- `MediaAssetRef` (`CatalogueModels.swift:29`) — immutable identity `(kind, contentVersion,
  sha256, bytes, objectKey)`. `objectKey` is a provider-neutral relative key
  `exercises/<slug>/<kind>-v<version>.<ext>` (`CatalogueModels.swift:47-49`); poster ext
  `webp`, video ext `mp4` (`CatalogueModels.swift:18-23`).
- `AvailabilityStatus` (`CatalogueModels.swift:53`) — `available` / `posterOnly` /
  `retired`. `CatalogueReviewStatus` (`CatalogueModels.swift:65`) — `pendingReview` /
  `approved`.
- `MediaManifest` (`CatalogueModels.swift:145`) — derived from the catalogue
  (`init(catalogue:)`, `CatalogueModels.swift:163`), `retired` entries filtered out
  (`CatalogueModels.swift:168`); records are `slug` + `poster`/`video` refs only.

**Serialization (`CatalogueSerialization.swift`):** deterministic JSON — `.sortedKeys`,
`.prettyPrinted`, `.withoutEscapingSlashes`, trailing `0x0A` (`CatalogueSerialization.swift:11-17`);
`decode(_:from:)` is a plain `JSONDecoder` (`CatalogueSerialization.swift:19-21`). Same
inputs → byte-identical output, so CI can verify a regeneration matches the committed file.

**Generation:** `CatalogueBuilder.build(...)` (`CatalogueBuilder.swift:23`) is a pure
function of `(classification, digests, previous, sourceFingerprint)`. The
`mazidi-content-audit` executable (`Sources/mazidi-content-audit/`) reads the source zips
read-only and emits into `content/exercises/catalogue/` (recipe in
`docs/ASSET_PIPELINE.md:10-17`).

**Committed generated files** (`content/exercises/catalogue/`): `catalogue.json`
(206 records, `schemaVersion 1`, `catalogueVersion 1`, `sourceFingerprint` over the three
zips), `media-manifest.json` (206 records, same envelope), `mapping-overrides.json`
(`schemaVersion 1`, empty `overrides` — no human resolutions were needed).

**Bundle decision (for Phase ≥2):** bundle **both** `catalogue.json` and
`media-manifest.json` as read-only app resources.
- `catalogue.json` drives coach search/filter/preview and the availability/checksum a
  resolver needs. `media-manifest.json` is the delivery projection (checksums + object
  keys, retired entries removed) used by the media cache/fetcher.
- Neither is currently referenced by the app: `grep` over `App/` and `project.yml` for
  `MazidiContent`/`catalogue`/`ExerciseCatalogue` returns nothing, and the app target's
  `dependencies` (`project.yml:24-26`) does **not** list `MazidiContent`. Phase ≥2 must add
  the `MazidiContent` product to the app target and add the two JSON files to the bundle
  (mirroring how `App/Resources/Fixtures/exercise-content.json` and `App/Resources/Media/`
  are already bundled and read via `Bundle.main.url(...)`).
- The 206-entry manifest is text only (~120 KB) — safe to bundle. The full media library is
  **not** bundled (CLAUDE.md; ADR-0010 §11) — only the approved representative set stays in
  `App/Resources/Media/` (8 posters, 2 clips).

## 2. How Coach drafts store exercise identifiers and labels

`PrescribedExercise` (`Packages/MazidiKit/Sources/MazidiDomain/Programming.swift:53`) stores
`slug: ExerciseSlug` (`Programming.swift:55`) plus `order`, `prescription`, `restSeconds`,
`tempo`, `effortAnnotation`, `coachNotes`, and `approvedAlternatives: [ExerciseSlug]`
(`Programming.swift:66`). **Drafts store the stable slug only — no display label is
stored.** The label is resolved live: `WorkoutEditorView` renders
`modelContent.content(for: exercise.slug)?.displayName ?? exercise.slug.rawValue`
(`App/Coach/Views/WorkoutEditorView.swift:116`, and the picker at `:239`). Drafts live in
the coach account DB as a JSON blob (`workout_template.draft_json`, MIGRATIONS.md v2).

## 3. How assignment snapshots preserve historical labels (ADR-0009)

The frozen container is `WorkoutTemplateContent` (`Programming.swift:93`): `title: String`
(`:95`) + `exercises: [PrescribedExercise]` (`:96`) — each exercise a raw `slug` +
prescription. Both the immutable version and the assignment snapshot it:

- `WorkoutTemplateVersion.content: WorkoutTemplateContent` (`Programming.swift:210`) — set
  once at publish (`Programming.swift:189-196`), never edited.
- `WorkoutAssignment.content: WorkoutTemplateContent` (`Programming.swift:246`), assigned
  from the version's content (`Programming.swift:265`); the doc-comment states later
  template edits "can never rewrite what was prescribed" (`Programming.swift:231`).
- The executing session additionally snapshots its `AssignedWorkout`
  (`workout_session.workout_json`, MIGRATIONS.md v1), and recorded sets store
  `performed_slug` (survives approved swaps — `WorkoutSession.swift:17`, MIGRATIONS.md v1).

**Nuance:** what is frozen is the **title + slugs + prescription**, not a rendered display
name. The client-facing *label* is always re-derived from the slug via the client-content
layer. Because slugs are never renamed (ADR-0010 §1) and catalogue entries are retired, not
deleted (§3/§12), that re-derivation is stable over time — the historical prescription and
its resolved label both remain correct without storing the label text.

## 4. How Client views resolve fixture posters and videos today

`MediaResolving` (`App/Client/Support/ClientEnvironment.swift:20`) —
`posterURL(for:)` / `clipURL(for:)` returning `URL?`. The concrete impl is
`BundleMediaResolver` (`App/Client/Support/ClientFixtures.swift:89`), which probes the app
bundle: posters under `Media/posters` (`ClientFixtures.swift:90-92`), clips under
`Media/clips` (`ClientFixtures.swift:95-97`), each keyed by `slug.rawValue`; a miss returns
`nil`. It is injected via `ClientEnvironment.init(media:)` defaulting to
`BundleMediaResolver()` (`ClientEnvironment.swift:105`).

`ExerciseMediaView` (`App/Client/Views/ExerciseMediaView.swift:10`) consumes
`any MediaResolving`: poster first (`:22` → `PosterImage`, WebP decoded off-main at `:96`),
clip overlay on demand as a muted loop (`:28`, autoplay gated by `isOpen && !reduceMotion`
at `:33`), and a **name+icon fallback** (`MediaFallback`, `:107`) when `posterURL` is `nil`
— never a black box, matching panel 7i. `ExercisePosterThumbnail` (`:51`) is the list/swap
thumbnail with the same fallback. Same resolver is consumed by `ExerciseDetailView`,
`ActiveWorkoutView`, and `ClientHomeView`.

## 5. Which fixture slugs map directly to canonical catalogue IDs

**Bundled fixture slug inventory (deduped union of all fixtures):**

- `App/Client/Support/ClientFixtures.swift:20-62` (`todaysWorkout`): `band-wood-chopper`,
  `barbell-squat`, `barbell-bent-over-row`, `barbell-high-incline-bench-press`,
  `cable-seated-rope-face-pull`, plus approved alternatives `kettlebell-sumo-deadlift`,
  `barbell-rack-pull`, `dumbbell-row-bilateral`.
- `App/Coach/Views/WorkoutEditorView.swift:228-231` (`ExercisePickerSheet.slugs`): the same
  eight slugs.
- Bundled media on disk: `App/Resources/Media/posters/` has all eight `.webp`;
  `App/Resources/Media/clips/` has `barbell-bent-over-row.mp4`, `barbell-squat.mp4`.

**Checked against `content/exercises/catalogue/catalogue.json` (all eight present, all
`availabilityStatus: available`, all poster+video):** see the mapping table below. **Every
bundled fixture slug is a direct canonical catalogue ID** — confirming ADR-0010 §5/Context
("all 8 slugs used by app fixtures are canonical library slugs").

## 6. How unknown legacy slugs should be displayed (policy)

Per ADR-0010 §5 and §11, a slug **absent** from the catalogue (a future coach-custom
exercise, or a corrupted install) resolves to the existing **name+icon fallback**
(`MediaFallback`, panel 7i) — never a crash, never a fabricated match. The label shown is
the client-content `displayName` if the client layer has the slug, else `slug.rawValue`
(the current `?? exercise.slug.rawValue` behaviour, `WorkoutEditorView.swift:116`). A
catalogued-but-`retired` slug still resolves its poster (retirement retains media,
`CatalogueBuilder.swift:83-99`). **The resolver never guesses a different slug's media for
an unknown id.**

## 7. Is a schema migration needed? — NO

**Determination: no new GRDB migration (no `v3`).** Justification:

1. **Assignments/sessions already freeze content and store raw slugs** (ADR-0009;
   MIGRATIONS.md v1/v2). The catalogue is a **read-side join** by slug for search, media,
   and labels — it is not written into `workout_template`, `template_version`,
   `workout_assignment`, or `workout_session`.
2. **Slugs are never renamed** (ADR-0010 §1) and **catalogue entries are retired, not
   deleted** (§3/§12). Therefore every historical slug already stored resolves — either
   normally or to a `retired` record whose poster remains resolvable, or (pre-catalogue) to
   the §5 name+icon fallback. Nothing needs rewriting to "adopt" the catalogue.
3. **The catalogue and manifest are bundled read-only JSON resources, not database
   tables** — adding them changes no schema.
4. **The media cache is a filesystem cache under `Caches/`** (ADR-0010 §8), keyed by
   immutable object keys — not a GRDB table, so no migration governs it.

Rewriting historical assignments to reference the new catalogue would **violate** ADR-0009
immutability and ADR-0010 §12 and is explicitly forbidden. Historical frozen content must
be preserved exactly.

## 8. Cache ownership, directory, limit, eviction — proposal

- **Directory:** app-side under `Caches/` per ADR-0001 platform-adapter placement and
  ADR-0010 §8. Proposed: `Library/Caches/MazidiPerformance/exercise-media/`.
- **Scope — device-global (NOT account-scoped):** exercise media is **immutable, content-
  addressed, non-private** shared reference content (public exercise demonstrations),
  identical for every account. `SECURITY_BOUNDARIES.md` scopes **databases and credentials**
  per account (the account DB path derivation, "Account-scoped databases"); it does **not**
  require caches of non-private shared assets to be account-scoped, and says nothing that
  forbids a device-global media cache. A device-global cache avoids duplicate downloads
  across accounts on a shared device and needs no teardown on account switch. **Hard rule:
  cache paths and metadata contain no raw account id and no user/workout content** — keys
  are `(mediaId, sha256)` object keys only (ADR-0010 §8, §9). This must be stated as an
  invariant in the ADR and covered by a test.
- **Limit / eviction:** bounded byte budget, **default 512 MB**, deterministic **LRU**;
  **posters evicted only after videos** (ADR-0010 §8). A file currently being presented is
  **never** evicted. Keys are immutable object keys, so a new `contentVersion` is a
  different key — stale content is impossible by construction.
- **Tiers** follow `asset-cdn-integration.md`: auto (current-programme posters), opt-in
  Wi-Fi prefetch (next workout clips), explicit download (full programme). **Never**
  auto-download the full library.

## 9. Remote URL injection boundary

Per ADR-0010 §6: manifest records carry **relative object keys only**
(`exercises/<slug>/<kind>-v<version>.<ext>` — verified in `catalogue.json`/
`media-manifest.json`); **no** hostname, bucket, credential, signed URL, or absolute path
ever appears in a generated artifact (enforced by `MediaAssetRef.objectKey`,
`CatalogueModels.swift:47`). The base URL is injected at runtime from `.xcconfig`
(`MEDIA_BASE_URL`, ADR-0010 §6; ARCHITECTURE.md §7 "server URLs and flags via
configuration"). **Today no such config exists** — the app has **no** app-owned `.xcconfig`
(only GRDB checkout files match `*.xcconfig`), and `project.yml` defines no `xcconfigFiles`.
So the remote tier is **honestly inert** until a base URL is configured (ADR-0010 §11
tier 3). Phase ≥2 introduces per-configuration `.xcconfig` (Debug/Staging/Release) wired via
`project.yml`, reads `MEDIA_BASE_URL` from the Info.plist/Bundle, and treats absent/empty as
"remote tier disabled". No hard-coded CDN host anywhere.

## 10. Checksum-validation flow

Every manifest media record carries `sha256` + `bytes` (`MediaAssetRef`,
`CatalogueModels.swift:33-35`). Runtime admission (ADR-0010 §8/§9): download to a **temp
file** → compute SHA-256 → **compare against the manifest checksum** → only on match
**atomically promote** (rename) into the cache under the immutable object key; on mismatch
or decode failure, **discard** the temp file and surface a fetch failure (retry later) —
never serve unvalidated bytes. A cached/downloaded asset that later fails checksum or decode
is evicted and the UI falls back per §11; the failure logs path + category only, never user
content (§9). Validation runs off the main thread.

## 11. Release and UI-test isolation requirements

From `docs/BUILD_AND_TEST.md` and CLAUDE.md, the CI toolchain is **Xcode 16.4 / Swift 6.1 /
iOS 18.5 simulator, unsigned** (`CODE_SIGNING_ALLOWED=NO`). Constraints Phase ≥2 code must
honour:

- **XCUITest is `@MainActor`-isolated** on the iOS 18.5 SDK — any new UI-test method/helper
  touching `XCUIApplication`/`XCUIElement` must be `@MainActor` (BUILD_AND_TEST.md §CI).
- **No parameterized protocol inside a protocol composition** under Swift 6.1 — use a plain
  parameterized existential or a small struct of role handles (the existing `ClientStore`
  pattern, `ClientEnvironment.swift:39-54`, exists precisely for this). Any new
  catalogue/media store abstraction must not compose parameterized protocols.
- **Keychain unavailable in unsigned test builds** — irrelevant to media (no secrets), but
  the media cache must not depend on Keychain and must not write anything account-sensitive.
- **DEBUG-only isolation:** dev fixtures / `DevelopmentAuthProvider` /
  `DevelopmentAssignmentRelay` are `#if DEBUG` and compiled out of Release (proven by binary
  grep + tests, ADR-0008/0009). Any new fake media fetcher / dev media affordance must be
  `#if DEBUG` (or test-target-only) and **must not** run in Release. The media-fetching
  protocol must ship a **deterministic fake fetcher** for tests with **no live network** —
  package tests stay offline and hermetic (MazidiKit imports Foundation only).
- Media resolution must **degrade honestly** (name+icon fallback) so unsigned/offline UI
  tests never depend on network or full-library media.

---

## Legacy fixture-slug → canonical-catalogue-ID mapping table

Every bundled fixture slug, checked against `content/exercises/catalogue/catalogue.json`.
There are **8 distinct fixture slugs**; **all 8 are direct canonical IDs**; **0 need a
mapping entry**. The deterministic known-fixture-slug map is therefore the **identity map
(empty today)** — but the code path must still exist for future unknown ids (§6 policy).

| # | Fixture slug | Source(s) | In catalogue? | Canonical status | Availability (poster/video) | Mapping needed |
|---|---|---|---|---|---|---|
| 1 | `band-wood-chopper` | ClientFixtures (warm-up), Editor picker, bundled poster | Yes | direct canonical id | available (poster+video) | No |
| 2 | `barbell-squat` | ClientFixtures (main), Editor picker, bundled poster+clip | Yes | direct canonical id | available (poster+video) | No |
| 3 | `barbell-bent-over-row` | ClientFixtures (main), Editor picker, bundled poster+clip | Yes | direct canonical id | available (poster+video) | No |
| 4 | `barbell-high-incline-bench-press` | ClientFixtures (main), Editor picker, bundled poster | Yes | direct canonical id | available (poster+video) | No |
| 5 | `cable-seated-rope-face-pull` | ClientFixtures (cool-down), Editor picker, bundled poster | Yes | direct canonical id | available (poster+video) | No |
| 6 | `kettlebell-sumo-deadlift` | ClientFixtures (squat alternative), Editor picker, bundled poster | Yes | direct canonical id | available (poster+video) | No |
| 7 | `barbell-rack-pull` | ClientFixtures (squat alternative), Editor picker, bundled poster | Yes | direct canonical id | available (poster+video) | No |
| 8 | `dumbbell-row-bilateral` | ClientFixtures (row alternative), Editor picker, bundled poster | Yes | direct canonical id | available (poster+video) | No |

**Consequence for implementation:** the legacy-slug resolution policy (ADR-0011) is
`canonical-ID lookup → known-fixture-slug deterministic map (empty) → preserve frozen label
→ media-unavailable`. Because tier 2 is empty, in practice every current fixture slug
resolves at tier 1; the later tiers are the honest fallback for ids that predate or fall
outside the catalogue. **No fixture data needs editing to adopt the catalogue.**

---

## Architecture decision: focused ADR-0011 (app integration)

**Decision: write a focused `ADR-0011-exercise-library-app-integration.md`**, scoped to the
**app-facing** contracts, that **defers to ADR-0010** for the already-settled
pipeline/policy decisions rather than restating them.

**Rationale.** ADR-0010 is comprehensive at the **pipeline and policy** level and already
settles: canonical id (§1), immutable media identity (§2), catalogue schema/versioning (§3),
mapping confidence (§4), legacy-slug *policy* (§5), remote object-key convention +
`MEDIA_BASE_URL` (§6), poster/video relationship (§7), checksum + bounded-cache *policy*
(§8), malformed handling (§9), ambiguous handling (§10), offline fallback order (§11), and
historical-assignment compatibility / no-migration (§12). Those are **not** re-decided.

However, several genuine **app-integration** decisions are **not** fixed by ADR-0010 and
warrant a focused ADR (not a redundant restatement):

1. **App-facing catalogue repository / query boundary** — the concrete read model the coach
   picker/search and client resolution consume (ADR-0010 gives the data, not the app query
   surface).
2. **Cache scope: device-global vs account-scoped** — ADR-0010 §8 places the cache under
   `Caches/` but does **not** decide scope; this review decides **device-global** for
   immutable non-private media, an app-boundary decision that belongs in an ADR with its
   no-raw-account-id invariant.
3. **Provider-neutral media-location contracts and the injected media-fetching protocol** —
   typed failures, cancellation, no retry loops, deterministic fake fetcher, stale-request/
   version protection. ADR-0010 §6/§11 say the remote tier is inert and config-injected but
   do **not** specify these app-side contracts.
4. **The composed fallback resolver** (validated cache → bundled representative → injected
   remote → poster-only → name+icon) as an app component with a single resolution path.

A focused ADR-0011 keeps these app-boundary decisions reviewable and consistent with
ADR-0010 and ARCHITECTURE.md §6, without duplicating §1-4/§7/§9/§10/§12. ADR-0011 is
committed alongside this review in commit group 1.
