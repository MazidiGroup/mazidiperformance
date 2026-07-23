# Accessibility acceptance criteria & QA checklist

## Acceptance criteria (panel 14i)
- Text contrast ≥4.5:1 (≥3:1 for ≥24px bold) in BOTH appearances and with Increase Contrast.
- Every status readable without colour: label or icon always present.
- All controls ≥44×44 pt at every type size.
- Dynamic Type to AX5: rows restack vertically, trailing actions become full-width buttons, nothing clips or becomes unreachable (14c).
- VoiceOver: labels, traits, values, hints; visual reading order; grouped rows read as one stop; decorative icons hidden; state changes and errors announced (14d).
- Keyboard never obstructs the focused field or the primary action; focused field scrolls above the keyboard (14g).
- Safe areas respected, incl. home indicator over sticky footers.
- Reduce Motion: no autoplay, no auto-loop, crossfades instead of slides/springs, numeric countdown instead of ring, static success state (14f).
- Bold Text steps weights up one level, layout unchanged; settings combine (Contrast + Bold + large type simultaneously).
- Appearance switch mid-flow keeps scroll, input and playback state.
- Forms: visible labels persist; errors pair colour + icon + text at the field, move focus to first invalid field, post VoiceOver announcement.
- Charts/progress expose text equivalents ("adherence 91 percent").

## Developer QA checklist
1. Snapshot both appearances × default/AX5 type × Bold Text for every screen in the inventory.
2. Accessibility Inspector audit: zero unlabeled elements, zero contrast failures.
3. Rotor navigation (headings, links, form controls) on list screens.
4. Differentiate Without Colour + Button Shapes on together (14e).
5. Offline + error states tested with VoiceOver running (14h).
6. Quiet-hours / sync-issue / "notify now" wording matches turns 9 & 13 exactly.
7. Bright-light check: no text below 62% opacity on light, 55% on dark.
8. Videos: muted autoplay off-limits under Reduce Motion; user pause never overridden; poster + manual play after failure.
