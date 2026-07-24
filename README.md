# Mazidi Performance

Subscription-based iOS platform for independent personal trainers and online coaches. Native Swift/SwiftUI.

## Approved design baseline

- **Handoff:** `design/handoff-current/` — 110 design panels (turns 1–14), tag `design-handoff-v1.0.0`, merge commit `c92ecb5`.
- Open `design/handoff-current/Mazidi Performance.dc.html` in a browser; panels are anchor-addressable (e.g. `#10d`).
- Documentation set: `design/handoff-current/handoff/` (screen inventory, design tokens, functional rules, state machines, accessibility QA, asset/CDN integration).
- Integrity hashes: `design/handoff-current/handoff/README.md` §Integrity manifest and `MANIFEST.sha256`.

## Repository contents

- `App/` + `project.yml` — iOS app target (generate the Xcode project with `xcodegen generate` on macOS).
- `Packages/MazidiKit/` — platform-neutral domain/services/sync/persistence package (builds and tests on macOS/Linux/Windows).
- `content/exercises/client-layer/` — draft client-facing exercise content (206 records, **pending fitness-professional review** — 101 flagged).
- `design/handoff-current/` — the approved design handoff (do not modify).
- `docs/` — verification report, architecture, ADRs, risk register, decision log, roadmap, build/test commands.

## Start here

1. `docs/audit/VERIFICATION_REPORT.md` — baseline verification and repo state
2. `docs/architecture/ARCHITECTURE.md` + `docs/architecture/adr/`
3. `docs/ROADMAP.md` and `docs/VERTICAL_SLICE_1.md`
4. `docs/BUILD_AND_TEST.md` — build/test commands and current verification status

## Content status

The 12 MP4 clips are representative dev fixtures; the full 206-clip library ships via the content/CDN pipeline (`handoff/asset-cdn-integration.md`). The client-content layer is a draft: every record is `draft_requires_human_review` and renders with a "DRAFT COPY · PENDING REVIEW" badge until review completes.
