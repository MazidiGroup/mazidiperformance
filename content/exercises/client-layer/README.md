# Mazidi Performance client-content layer — draft

This package was generated from the existing 206-record animation metadata supplied with the posters and video filenames.

## What this is

A separate client-facing content layer keyed by the original stable `slug`. It adds the fields previously requested by the design handoff:

- `displayName`
- `aliases`
- `clientDescription`
- `clientInstructions`
- `clientMistakes`
- `clientBenefits`
- `defaultCue`

It also preserves the source asset references and exercise classification fields so the developer can join it directly to the technical library.

## Important status

This is an **automatically prepared first draft**, not a clinically, legally or editorially reviewed final library. Every record is marked `draft_requires_human_review`. Source marketing language and obvious absolute/safety wording were neutralised where practical, and `101` of 206 records carry review flags showing where the original source contained language that deserves closer checking. `3` display names were explicitly overridden, including:

- `parralel-bar-dips` → **Parallel Bar Dips** (stable source slug retained)
- `dumbbell-laying-reverse-fly` → **Lying Reverse Fly**
- `barbell-stiff-leg-deadlifts` → **Barbell Stiff Leg Deadlift**

## Recommended ownership

- **Designer:** needs only a representative sample of posters/clips and this schema/content sample to design the states.
- **Developer/content pipeline:** receives the full animation library, technical metadata, posters, and this client-facing layer or its approved replacement.
- **Content reviewer/coach:** approves exercise naming, wording, aliases, technique instructions, mistakes and benefits before production publication.

## Files

- `mazidi-client-content-draft.json` — arrays retained for direct application use.
- `mazidi-client-content-draft.csv` — review-friendly tabular form; list values are separated with ` | `.
