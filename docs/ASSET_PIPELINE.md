# Exercise asset pipeline

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
