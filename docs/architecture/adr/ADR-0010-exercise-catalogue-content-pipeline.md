# ADR-0010 — Exercise catalogue & media content pipeline

**Status:** Accepted · 2026-07-24

## Context

Exercise identity today is a bare `ExerciseSlug` string: fixtures name slugs directly,
`BundleMediaResolver` probes the app bundle, and there is no canonical catalogue the
coach or client surfaces can search. The full animation library exists only as a
read-only local source of record
(`/Users/mazadi/Documents/MazidiPerformance/Animation_Pack_20-07-26` — three zip
archives: 206 MP4 clips, 206 WebP posters, `metadata.json`/`.csv`), which must never be
modified, committed, or copied wholesale into the repo (CLAUDE.md). The design handoff
(`asset-cdn-integration.md`, `docs/ASSET_PIPELINE.md`) requires a slug-keyed versioned
manifest, poster-first delivery, bounded caching, and honest failure states. No backend
or CDN exists (R-01/R-02); none is fabricated here.

**Source-library audit findings (2026-07-24, read-only `unzip -l`/`unzip -p`):** 206
records with a perfect 1:1:1 slug correspondence between videos, posters and
`metadata.json`; zero duplicate slugs; every `posterFile`/`videoFile` value follows the
`posters/<slug>.webp` / `<slug>.mp4` pattern; the repo's client-content layer
(`content/exercises/client-layer/`) covers exactly the same 206 slugs; all 8 slugs used
by app fixtures (`ClientFixtures`, `WorkoutEditorView`) are canonical library slugs.
These decisions are therefore grounded in verified data, but the pipeline must still
handle the dirty cases (a future library drop will not be this clean).

## Decisions

### 1. Canonical exercise identifier: the stable source slug
The library `slug` **is** the canonical exercise ID, formalised as the existing
`ExerciseSlug` value type. It is the join key across technical metadata, the
client-content layer, posters, videos, prescriptions, assignments and recorded sets —
exactly as the handoff manifest contract requires ("join key is the stable slug — never
renamed"). Display corrections live in the client-content layer's `displayName` and
never change the slug. Validity: lowercase ASCII letters, digits and single hyphens
(`^[a-z0-9]+(-[a-z0-9]+)*$`); the audit tool rejects anything else. Known-misspelled
slugs (e.g. `parralel-bar-dips`) stay as-is with corrected display names — renaming a
slug is a catalogue-breaking event and is forbidden.

### 2. Immutable media identity: slug + kind + content version, pinned by checksum
A media asset is identified by `(slug, kind, contentVersion)` where
`kind ∈ {poster, video}` and `contentVersion` is a per-asset monotonic integer starting
at 1. Each `(slug, kind, contentVersion)` is permanently bound to one SHA-256 checksum:
replacing an asset's bytes mints `contentVersion + 1`; an existing version's checksum
never changes. This makes cache entries and remote keys immutable and cache-busting
structural rather than TTL-based.

### 3. Catalogue schema and versioning
A generated, committed `content/exercises/catalogue/catalogue.json` (plus
`media-manifest.json`) is the app's source of truth:

- **Catalogue record:** `slug`, classification passthrough (`primaryMuscles`,
  `secondaryMuscles`, `equipment`, `movementPattern`, `difficulty`, `tags`),
  `durationMs`, media refs (`poster`, `video` as §2 identities with checksum and byte
  size), `availabilityStatus` (`available` / `posterOnly` / `retired`), and
  `contentReviewStatus` (client-facing wording continues to come only from the
  client-content layer, joined by slug — the catalogue never carries client copy).
- **Catalogue envelope:** `catalogueVersion` (monotonic integer, bumped only when
  content changes), `schemaVersion` (currently 1), and `sourceFingerprint` (SHA-256 of
  each source zip) — **no timestamps and no machine paths**, so generation is
  byte-deterministic: same inputs → byte-identical output (stable slug sort, LF, sorted
  JSON keys). CI/review can verify a regenerated catalogue matches the committed one.
- Catalogue versions are append-style: entries gain `retired` status rather than being
  removed, so historical references always resolve to *something* (§12).

### 4. Mapping confidence and review status
The audit tool classifies every source file ↔ metadata pairing:
`exact` (slug identical across metadata, poster and video — the only class that enters
the manifest automatically), `normalised` (differs only by case/extension/known
transform — enters the manifest but is listed in the review report),
`ambiguous` (multiple candidates or colliding normalisations — excluded, must be
resolved by a human), `unmatched` (file with no metadata record, or record with no
file — excluded, reported). The review report (`review-report.json` + Markdown
rendering) is a generated working artifact, not a tracked file, except that a summary
count lands in the ADR/PR description. Nothing ambiguous is ever silently auto-mapped.
(Current library: 206 exact, 0 in every other class.)

### 5. Legacy fixture-slug policy: no migration, one resolution path
All existing fixture slugs are canonical library slugs (verified), so there is **no
legacy-slug mapping table**. Fixtures, coach programming and client execution all
resolve media through the same catalogue-backed resolver. A slug absent from the
catalogue (a future coach-custom exercise, or a corrupted install) resolves to the
existing name+icon fallback — never a crash, never a black box (7i). The bundled
representative media set stays as-is and is served by the same resolver as its last
local tier (§11).

### 6. Remote object-key convention: provider-neutral relative keys
Manifest records carry **relative object keys only**:
`exercises/<slug>/poster-v<contentVersion>.webp` and
`exercises/<slug>/video-v<contentVersion>.mp4`. The base URL comes from `.xcconfig`
configuration at runtime (`MEDIA_BASE_URL`); the manifest never contains hostnames,
bucket names, credentials, signed URLs, or absolute local paths. This satisfies the
handoff's `{slug}`-pathed CDN layout while keeping the manifest valid for any future
provider. No upload tooling is built in this milestone — ingestion to a real CDN is a
backend-era task (asset-cdn-integration.md); recorded, not fabricated.

### 7. Poster/video relationship: poster mandatory, video optional
Every catalogue entry must have a poster (`video` without `poster` is a validation
error → review report). `posterOnly` is a legal availability status (video missing or
retired); poster-first rendering is already the app rule. Poster and video for a slug
version independently (a re-encoded video does not bump the poster).

### 8. Checksums and bounded cache policy
Every manifest media record carries `sha256` and `bytes`. The client cache
(`MediaCache`, app-side under `Caches/`, per ADR-0001 platform-adapter placement, with
the policy contract in MazidiKit):
- Validates every download against the manifest checksum **before** admission; a
  mismatch is discarded and retried, never served.
- Is bounded: configurable byte budget (default 512 MB), LRU eviction; posters are
  evicted only after videos.
- Cache keys are the immutable object keys (§6), so stale content is impossible by
  construction — a new `contentVersion` is a different key.
- Tier policy follows `asset-cdn-integration.md`: auto (current-programme posters),
  opt-in Wi-Fi prefetch (next workout's clips), explicit download (full programme).
  Never auto-download the full library.

### 9. Unsupported/malformed media handling
Audit-time: entries that are zero-byte, unreadable, of unexpected extension, or that
fail decode probing are classified `malformed` and excluded from the manifest (review
report, §4). Runtime: a cached or downloaded asset that fails checksum or decode is
evicted and the UI falls back per §11 — the failure is logged (path + category only,
never user content) and never crashes playback surfaces.

### 10. Ambiguous filename handling
Filenames whose normalisation collides with another slug, duplicate slugs across
sources, or one slug with multiple candidate files are `ambiguous` (§4): excluded from
the manifest, itemised in the review report with every candidate listed, resolved only
by an explicit human decision recorded in a small tracked overrides file
(`content/exercises/catalogue/mapping-overrides.json`, empty today). The tool never
guesses.

### 11. Offline fallback order (client media resolution)
Deterministic resolution order for a slug's media:
1. bounded validated cache (§8) — offline-capable, "Offline ✓" badge on posters;
2. bundled representative media (the tracked 2-clip/8-poster set);
3. remote fetch via manifest key + configured base URL (when configuration exists —
   none does yet, honestly absent, so this tier is inert until R-02-era config lands);
4. poster-only rendering when video is unavailable;
5. name+icon fallback (existing 7i behaviour).
Workout execution never blocks on media at any tier.

### 12. Historical assignment compatibility
Assignments and sessions already snapshot their content and store raw slugs
(ADR-0009); catalogue updates never rewrite them. Because slugs are never renamed (§1)
and catalogue entries are retired rather than deleted (§3), any historical slug either
resolves normally or reaches a `retired` entry whose poster remains resolvable; a slug
predating the catalogue follows §5's fallback. No migration touches historical rows.

## Tooling and layout

- New Foundation-only MazidiKit target **`MazidiContent`**: catalogue/manifest/review
  models, slug validation, deterministic serialisation, mapping classification —
  unit-testable with `swift test`, no GRDB/UIKit.
- New executable target **`mazidi-content-audit`** (same package, depends on
  `MazidiContent`): reads the source zips **in place, read-only** (stream via zip
  APIs / `unzip -p`; if extraction is unavoidable it targets only the git-ignored
  working directory), writes all generated artifacts to `.content-pipeline-work/`
  (git-ignored; rule added this milestone). It never writes inside the source
  directory, never commits media, and refuses to run if pointed at a path inside the
  repo's tracked tree.
- Committed outputs are text only: `catalogue.json`, `media-manifest.json`,
  `mapping-overrides.json`. Tracked media remains exactly the approved representative
  set.

## Consequences

- One resolver path (fixtures = production shape) removes the fixture/production media
  divergence; the fixture provider becomes a catalogue-backed resolver with the bundle
  as a lower tier.
- Byte-deterministic generation makes the committed catalogue reviewable and
  regenerable; MANIFEST.sha256 continues to cover it like any tracked file.
- The remote tier ships as contracts + tests with no live endpoint — the app remains
  honest that full-library media is unavailable until the content backend exists.
- Coach search/filter/preview and client resolution build on `MazidiContent` models in
  subsequent commits of this milestone; UI copy for draft content continues to obey the
  client-content layer rules (DRAFT COPY · PENDING REVIEW).
