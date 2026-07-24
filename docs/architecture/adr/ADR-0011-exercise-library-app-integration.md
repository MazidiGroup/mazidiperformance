# ADR-0011 — Exercise library app integration (catalogue-backed resolution, media cache & fetch)

**Status:** Accepted · 2026-07-24

## Context

ADR-0010 established the canonical exercise catalogue, the read-only content-audit pipeline,
immutable media identity, the deterministic committed `catalogue.json` /
`media-manifest.json`, and the **policy** for legacy slugs (§5), remote object keys (§6),
bounded caching (§8), offline fallback order (§11) and historical-assignment compatibility
(§12). What ADR-0010 deliberately did **not** fix are the **app-facing contracts** that turn
that data into working Coach and Client surfaces: the catalogue read/query boundary, the
media-location contracts, the injected media-fetching protocol, and the composed fallback
resolver — plus one decision ADR-0010 left open: the cache **scope** (device-global vs
account-scoped).

This ADR decides those app-integration contracts. It **defers to ADR-0010** for everything
ADR-0010 already settled (§1 canonical id, §2 media identity, §3 schema/versioning, §4
mapping confidence, §7 poster/video, §9 malformed, §10 ambiguous, §12 no-migration) and does
not restate them. No backend or CDN exists (R-01/R-02); nothing here fabricates live network
behaviour. Grounding for every decision below is in
`docs/architecture/exercise-library-app-integration-review.md` (file:line citations).

Verified facts this ADR builds on: all 8 bundled fixture slugs are direct canonical
catalogue IDs (review §5), so **no legacy mapping table and no data migration are needed**
(review §7); the app does not yet depend on `MazidiContent` and does not yet bundle the
catalogue/manifest (review §1); no app-owned `.xcconfig` exists yet (review §9).

## Decisions

### 1. App-facing catalogue repository / query boundary

A Foundation-only read model in `MazidiContent` loads the bundled `catalogue.json`
(source of truth for records + availability + checksums) and exposes a small query surface:
lookup by slug, and coach search/filter (by name via the client-content join, muscle,
equipment, movement pattern, difficulty, tag). It is **read-only** and immutable after load;
it performs no writes and touches no GRDB. The app injects it behind a protocol (the
existing dependency-injection seam pattern, e.g. `MediaResolving` in
`ClientEnvironment.swift`), so previews/tests can supply an in-memory catalogue. Client copy
is **never** taken from the catalogue — display names/instructions continue to join by slug
from the client-content layer (ADR-0010 §1/§3); the DRAFT COPY · PENDING REVIEW rule is
unchanged.

### 2. Legacy-slug resolution policy (one deterministic path)

Every media/label resolution follows one ordered, deterministic path — never a guess:

1. **Canonical-ID lookup** — slug present in the catalogue → use its record (media refs,
   availability). `retired` still resolves its retained poster (ADR-0010 §3/§12).
2. **Known-fixture-slug deterministic map** — an explicit, static map for any historical id
   that is not itself a canonical slug. **Empty today** (all fixture slugs are canonical —
   review §5); the code path exists for future ids. Entries are explicit, never inferred.
3. **Preserve the frozen label** — a slug with no catalogue record still renders its
   client-content `displayName` if present, else `slug.rawValue` (current
   `?? slug.rawValue` behaviour), so historical prescriptions read correctly.
4. **Media-unavailable (name+icon fallback)** — when no media can be validated, show the
   existing 7i name+icon card. Never crash, never substitute another slug's media.

An unknown id is **never silently migrated** to a different canonical id.

### 3. Provider-neutral media-location contracts

Media location is expressed as provider-neutral values, never a concrete URL in the domain:

- **media asset id** = `(slug, kind, contentVersion)` (ADR-0010 §2).
- **media type** = poster | video (`MediaKind`).
- **immutable checksum** = the record's `sha256` + `bytes` (ADR-0010 §2/§8).
- **bundled resource** = a lookup into the app bundle (the existing `BundleMediaResolver`
  behaviour) for the approved representative set.
- **validated cache entry** = a file admitted to the bounded cache only after checksum match
  (decision 5).
- **injected remote URL** = `MEDIA_BASE_URL` (from `.xcconfig`, ADR-0010 §6) joined with the
  record's relative `objectKey`. Absent/empty config ⇒ the remote tier is disabled (honest
  inert state, ADR-0010 §11). No hostname/bucket/credential ever lives in a generated
  artifact or the domain.

### 4. Composed fallback resolver (fixtures = production shape)

A single `CatalogueMediaResolver` replaces the divergence between fixture and production
media by resolving in this fixed order (ADR-0010 §11):

1. **Validated cached asset** matching id + checksum (offline-capable; "Offline ✓" badge).
2. **Approved bundled representative asset** (the tracked 8-poster / 2-clip set).
3. **Injected remote URL** when configured and permitted (inert until `MEDIA_BASE_URL`
   lands).
4. **Poster-only** rendering when the video is unavailable.
5. **Honest unavailable state** — name+icon fallback (existing 7i).

Workout execution never blocks on media at any tier. The resolver conforms to the existing
`MediaResolving` seam so it drops into `ClientEnvironment` and the Coach preview without
touching call sites.

### 5. Bounded media cache

- **Key** = the immutable object key `exercises/<slug>/<kind>-v<version>.<ext>` (⇒ media id
  + checksum-pinned version; stale content impossible by construction — ADR-0010 §2/§8).
- **Admission** = download to a **temp file** → compute SHA-256 → compare to the manifest
  checksum → **atomic promotion** (rename) into the cache on match; discard on mismatch or
  decode failure. Never serve unvalidated bytes (ADR-0010 §8/§9).
- **Bound** = configurable byte budget, **default 512 MB**, deterministic **LRU** eviction;
  **posters evicted only after videos**; a file currently being presented is **never**
  evicted.
- **Scope = device-global**, under `Library/Caches/MazidiPerformance/exercise-media/`.
  Exercise media is immutable, content-addressed, **non-private** shared reference content,
  identical across accounts, so a device-global cache avoids duplicate downloads and needs
  no teardown on account switch. This is consistent with `SECURITY_BOUNDARIES.md`, which
  scopes **databases and credentials** per account but does not require caches of non-private
  shared assets to be account-scoped.
- **Invariant (tested):** cache paths and metadata contain **no raw account id** and **no
  user/workout content** — only object keys and checksums. Failures log path + category
  only (ADR-0010 §9).

### 6. Networking boundary (injected media-fetching protocol)

- A single **injected** media-fetching protocol (Foundation-only contract in MazidiKit;
  URLSession-backed adapter in the app layer) — the domain/services never import a networking
  SDK, mirroring ADR-0001/0008 boundaries.
- **Typed failures** (unreachable, notFound, checksumMismatch, cancelled, decode) — no
  untyped `Error` leakage; the resolver maps failures to the honest fallback tiers.
- **Cancellation** is first-class (Swift structured concurrency) — a scrolled-away exercise
  cancels its in-flight fetch.
- **No retry loops** — a failure surfaces to the caller / falls back; retry is a user- or
  tier-driven action, never an automatic hot loop.
- **Stale-request / version protection** — a completing fetch is admitted only if its object
  key (checksum-pinned version) still matches what the surface currently wants; a superseded
  response is discarded, not shown.
- **Deterministic fake fetcher** for tests — no live network in package or UI tests; the
  fake returns fixed bytes/failures so checksum-admission, fallback ordering, cancellation
  and stale-request handling are unit-testable offline. Any dev-only media affordance is
  `#if DEBUG` / test-target-only and compiled out of Release (ADR-0008/0009 isolation).

## Consequences

- One resolver path (fixtures = production shape) removes the fixture/production media
  divergence without editing any fixture data — all fixture slugs already resolve at tier 1
  (review §5).
- **No GRDB migration** and **no rewrite of historical assignments/sessions** — the catalogue
  is a read-side join; frozen snapshots and raw slugs are preserved exactly (ADR-0009,
  ADR-0010 §12, review §7).
- The remote tier ships as contracts + a fake fetcher with **no live endpoint** —
  full-library media stays honestly unavailable until `MEDIA_BASE_URL` and a content backend
  exist (R-02).
- Phase ≥2 must: add the `MazidiContent` product to the app target and bundle
  `catalogue.json` + `media-manifest.json` (review §1); introduce per-configuration
  `.xcconfig` for `MEDIA_BASE_URL` wired via `project.yml` (review §9); keep all new UI-test
  helpers `@MainActor` and avoid parameterized protocols in compositions (Swift 6.1 CI —
  review §11).
- `MANIFEST.sha256` continues to cover the new tracked docs/JSON like any tracked file
  (regenerated in the milestone's final commit group, not this one).
