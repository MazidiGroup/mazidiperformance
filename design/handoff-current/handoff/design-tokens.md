# Design tokens

Switching appearance swaps tokens only — layout, data and state are identical. Mid-flow switches keep scroll position, form input and playback state.

| Token | Dark | Light | Use |
|---|---|---|---|
| bg | #0D0E11 | #F2F2F6 | Screen background |
| surface | #17181D (alt #1B1D23, #15161B sheets) | #FFFFFF | Cards, sheets |
| text | #F4F5F7 | #17181D | Primary text |
| text-secondary | rgba(235,236,245,0.60–0.72) | rgba(23,24,29,0.62) | Supporting text (≥4.5:1) |
| text-tertiary | rgba(235,236,245,0.50–0.55) | rgba(23,24,29,0.45–0.55) | Captions, timestamps (≥18px or non-essential only) |
| primary | #2F66D8 (buttons) / #3A7BFD (small accents) | #2F66D8 | Primary buttons, white label text |
| link/tappable | #8FB2FE | #2456C4 | Tappable text, deep links |
| success | #7BDCA8 text on rgba(56,201,124,0.14) | #136B41 text on 10% green tint | Paid, done, confirmed — always paired with a label |
| warning | #EFC684 text on rgba(232,163,61,0.14) | #8A5A00 text on 12% amber tint | Due, waiting, drafts |
| danger | #F08A8E text on rgba(229,72,77,0.14) | #C0353A text on 10% red tint | Overdue, safety, destructive |
| hairline | rgba(255,255,255,0.07–0.08) | rgba(17,18,23,0.08–0.10) | Borders/separators; 1px @ 35% on Increase Contrast |

Type: SF Pro; screens min 12px captions, body 13.5–15.5px, titles 17–30px. Radii: cards 14–16, sheets 24 top, chips 10–12, buttons 11–16. Status colours must never be the only signal — every status pairs colour with a text label (and icon under Differentiate Without Colour).
