# Asset & CDN integration — full animation library

## What ships where
- **This package (design):** 12 representative MP4 clips + all 206 posters + metadata — enough to validate autoplay, poster-first, preview, full-screen, error and offline states.
- **Content pipeline (production):** the full 206-clip library, uploaded to storage/CDN with a manifest mapping each stable `slug` → `posterFile` / `videoFile`.

## Manifest contract
Join key is the stable `slug` (never renamed — display fixes live in the client-content layer's `displayName`). Each record in `metadata.json` / the client-content JSON carries `posterFile` (720×402 WebP) and `videoFile` (MP4). Serve as:
`https://cdn.example/exercises/{slug}/poster.webp` and `.../{slug}/video.mp4` (or equivalent), plus a versioned `manifest.json` with content hashes for cache-busting.

## Delivery rules (panel 7i)
- Poster first, always; video streams on demand — muted loop, never autoplays with sound; only the opened exercise animates.
- Auto-cached: metadata, written instructions, current-programme posters. Optional Wi-Fi prefetch: next workout's clips. Explicit download: full-programme clips (size shown first, progress %, pause, retry, Wi-Fi-only preference).
- Never bundled or auto-downloaded: the full 206-video library. No large cellular downloads without clear intent.
- Failure states: loading skeleton (never a black box), name+icon fallback on missing media, "Offline ✓" badge on cached posters.
- Custom coach exercises upload to the same CDN namespace with coach-scoped ACLs; failed uploads keep the local original with Retry.

## Reminder
The design canvas's video helper (IntersectionObserver + ref init in the DC logic class) is preview behaviour for this document only — production playback follows the rules above, not that code.
