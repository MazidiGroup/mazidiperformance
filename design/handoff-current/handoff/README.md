# Mazidi Performance — developer handoff package

**Version:** turns 1–14 final (post consistency/accessibility patch) · **Date:** 23 July 2026 · **Design canvas:** `Mazidi Performance.dc.html` (open in a browser; panels are anchor-addressable, e.g. `#10d`).

## Contents

- `Mazidi Performance.dc.html` — the full design document: 110 panels across 14 turns (see `handoff/screen-inventory.md`)
- `ios-frame.jsx`, `support.js` — canvas runtime + device frame (design-canvas infrastructure, not product code)
- `uploads/client-content/mazidi-client-content-draft.json` — client-facing content layer, 206 exercises. **Draft — requires fitness-professional review** (101 records flagged, `contentStatus: draft_requires_human_review`)
- `uploads/full-library-metadata/` — source technical metadata (206 records, JSON + CSV)
- `uploads/full-library-posters/` — 720×402 WebP posters
- `uploads/full-library-videos/` — 12 representative MP4 clips (full 206-clip library ships via the content pipeline, see `handoff/asset-cdn-integration.md`)
- `handoff/` — this documentation set

## Documentation set

- `screen-inventory.md` — all 110 panels by turn
- `design-tokens.md` — dark + light token spec, semantic status colours
- `functional-rules.md` — functional & safety rules the UI encodes
- `state-machines.md` — payment, subscription entitlement, calendar proposal, account deletion
- `accessibility-qa.md` — acceptance criteria + developer QA checklist
- `asset-cdn-integration.md` — full animation-library integration

## ⚠ Video helper

The in-canvas video playback logic (React ref `videoRef` in the DC logic class) is **design-canvas preview behaviour only — NOT production implementation guidance**. Production media behaviour is specified in panels 7i (playback/offline rules) and 14f (Reduce Motion).

## Known assumptions

- Device target iPhone 16 Pro (402×874 pt), SF Pro, iOS-native patterns
- Single coach (Jordan Taylor, Taylor Performance Coaching) with 5 active clients + 1 paused; fictional dates align to the real 2026 calendar (today = Wed 22 Jul 2026)
- Coach collects client payments outside the app — the app is a ledger, never a checkout (turn 10)
- Coach's own platform subscription is fully separate from client payments (turn 11)
- Currency GBP, UK time zone; localisation (units/currency) not yet designed

## Remaining review items (open)

1. **Fitness-professional review** of the client-content draft — 101/206 records flagged for wording (marketing/absolute-safety language)
2. **Legal/privacy review** of retention periods and deletion wording (13g/13i/13j explicitly note this)
3. Full 206-clip animation library delivery to the content pipeline (only 12 representative clips are bundled)

## Ready to build vs implementation QA

**Ready to build now:** screen layouts and flows for turns 1–14 · design tokens (both appearances) · payment/subscription/calendar/privacy state machines · notification & badge rules (turn 9) · content-layer schema and join keys (stable slugs)

**Implementation-QA items (verify in the built product, not the canvas):** real Dynamic Type reflow at AX sizes (14c defines the rules) · VoiceOver labels/traits/order (14d) · system-setting variants (14e) · Reduce Motion behaviour (14f) · keyboard avoidance (14g) · offline/error handling (14h) · the full accessibility checklist in `accessibility-qa.md`

## Integrity manifest (SHA-256)

| File | Size (bytes) | SHA-256 |
|---|---|---|
| `Mazidi Performance.dc.html` | 684432 | `51538acbf9e33e7b93bc2e94969628dc5499223ddff04581ef4ad1c26347bfe7` |
| `ios-frame.jsx` | 16507 | `24642b887be3d26ab5d1ff445ad98c363cffd33746c539a117da570ac7b6eb54` |
| `support.js` | 66404 | `c60c49083997f51a592df118c0068475337afd20b8cfd8e1cd9d5eb0c7e254f6` |
| `uploads/client-content/mazidi-client-content-draft.json` | 444552 | `84f486f2b21acb8c076c53529ee24659fffa467631e13167823407a84523b18d` |
| `uploads/full-library-metadata/metadata.json` | 622985 | `d126776c370708e94a1cfd7a6fe526f5a6f5a55183c9ccc8fe46c8bc26479846` |
| `uploads/full-library-metadata/metadata.csv` | 497278 | `794bfff9d76b00fccf2cdc9d20ce2445dcb7273b146e277164158fb3086ccb21` |

Posters and clips are content-addressed by slug; verify counts: 12 MP4 clips bundled (band-wood-chopper.mp4, barbell-behind-the-back-30-degree-shrug.mp4, barbell-bent-over-row.mp4, barbell-high-incline-bench-press.mp4, barbell-muscle-snatch.mp4, barbell-rack-pull.mp4, barbell-snatch.mp4, barbell-squat.mp4, cable-bench-chest-fly.mp4, cable-seated-rope-face-pull.mp4, dumbbell-row-bilateral.mp4, kettlebell-sumo-deadlift.mp4).
