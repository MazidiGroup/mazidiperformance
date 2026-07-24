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

## Client-content review

The files in `content/exercises/client-layer/` are a draft presentation layer. Review names, aliases, descriptions, instructions, mistakes, benefits and cues for neutral client-facing language before release.
