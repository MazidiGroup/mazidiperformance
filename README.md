# Mazidi Performance

Current product-design and exercise-content handoff for the Mazidi Performance iOS coaching platform.

## Repository contents

- `design/prototype-dark-mode-current/` — latest verified dark-mode prototype source (72 panels), support files, 412 exercise posters, 12 representative MP4 clips and the 206-record source metadata.
- `content/exercises/client-layer/` — draft neutral client-facing content keyed by the source exercise slugs, supplied as JSON and CSV for review.
- `docs/PROJECT_STATUS.md` — current design status, build readiness and remaining batches.
- `docs/ASSET_PIPELINE.md` — recommended handling for the full animation library and metadata.
- `MANIFEST.sha256` — file-integrity hashes.

## Open the design

Open `design/prototype-dark-mode-current/Mazidi Performance.dc.html` with its sibling files and `uploads/` directory kept in the same relative structure.

## Important content status

The 12 MP4 clips in this repository are representative design/development fixtures, not the full production animation library. The full library should be ingested by the developer/content pipeline and hosted in application storage or a CDN. It should not be committed to this repository as a large binary archive.

The client-content layer is a generated draft. It preserves stable slugs and asset references but requires editorial review before production publication.
