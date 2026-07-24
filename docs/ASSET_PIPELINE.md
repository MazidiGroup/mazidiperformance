# Exercise asset pipeline

## Canonical catalogue (ADR-0010)

`content/exercises/catalogue/` holds the committed, generated catalogue:
`catalogue.json` (canonical records + media identities), `media-manifest.json`
(delivery manifest derived from it), and `mapping-overrides.json` (tracked human
resolutions for ambiguous files; empty when none were needed). Regenerate with:

```bash
swift run --package-path Packages/MazidiKit mazidi-content-audit \
  --source "/Users/mazadi/Documents/MazidiPerformance/Animation_Pack_20-07-26" \
  --work .content-pipeline-work \
  --emit-into content/exercises/catalogue \
  --previous content/exercises/catalogue/catalogue.json \
  --overrides content/exercises/catalogue/mapping-overrides.json
```

The tool reads the source zips strictly read-only (streams, no extraction),
writes the review report to the git-ignored `.content-pipeline-work/`, and is
byte-deterministic: rerunning against unchanged sources reproduces the committed
files exactly and keeps the catalogue version unchanged. Review the printed
summary — anything ambiguous or unmatched needs a human decision recorded in
`mapping-overrides.json`, never a guess.

## What belongs in this repository

- The 206-record source metadata used to define stable exercise identity and asset filenames.
- Posters and a small set of representative videos required to exercise prototype states.
- The client-facing content layer in reviewable JSON and CSV formats.

## What should not be committed here

The complete production animation library should not be stored as a large Git history. Upload it through the application content pipeline to object storage/CDN and retain a versioned manifest in source control.

## Recommended production manifest

Each record should minimally include:

- `slug`
- `displayName`
- `posterAssetKey`
- `videoAssetKey`
- `videoVersion`
- `durationMs`
- `width`
- `height`
- `checksum`
- `availabilityStatus`
- `contentReviewStatus`

Use the stable source slug as the join key. Display-name corrections must not change that slug.

## App integration (ADR-0011)

How the generated catalogue reaches the running app:

- **Bundled resources** (`project.yml` → app target `sources`, `buildPhase: resources`,
  referenced in place — never copied into `App/`):
  `content/exercises/catalogue/catalogue.json`,
  `content/exercises/catalogue/media-manifest.json`, and the full client-content draft
  `content/exercises/client-layer/mazidi-client-content-draft.json` (display names +
  approved aliases for catalogue search, plus DRAFT coaching copy for the coach preview).
  Loading is safe: a missing or unsupported-schema resource degrades to an empty
  catalogue/manifest (media falls back to the bundled representative set; search returns
  nothing) — never a launch crash.
- **Media origin** comes from `MEDIA_BASE_URL` in the active configuration's
  `Config/*.xcconfig`, surfaced at runtime via the Info.plist key `MediaBaseURL`. It is
  **empty by default** — no CDN exists yet (R-02), so the remote media tier is honestly
  inert. Never hard-code a CDN host, and never commit a real host/credential in an
  `.xcconfig` (note the xcconfig `//`-is-a-comment caveat when a real value is added).
- **Resolution order** for a slug's media (client + coach preview), one composed path:
  validated cache → approved bundled representative → injected remote (async download,
  inert today) → poster-only → name+icon. A cache entry is served only when its bytes
  re-validate against the manifest checksum (size + SHA-256), so a corrupt or same-size
  tampered file is never presented.
- **Cache** is device-global under `Library/Caches/MazidiPerformance/exercise-media/`,
  512 MB LRU (videos evicted before posters, never a presented file), keyed by the
  immutable object key; paths and metadata carry no account id or user content. It is a
  runtime directory — never committed, and empty until a media backend exists.

To regenerate the committed catalogue/manifest, use the audit-tool recipe above; when
tracked files change, regenerate `MANIFEST.sha256` (see CLAUDE.md).

## Client-content review

The files in `content/exercises/client-layer/` are a draft presentation layer. Review names, aliases, descriptions, instructions, mistakes, benefits and cues for neutral client-facing language before release.
