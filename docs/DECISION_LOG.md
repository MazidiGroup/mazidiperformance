# Decision log — unresolved assumptions

Open items requiring product/legal/content/backend/App-Store confirmation. Nothing here blocks the current phase unless marked.

| ID | Question | Owner needed | Interim behaviour (implemented) |
|---|---|---|---|
| DL-01 | Retention periods & deletion wording (13g/13i/13j say "pending legal review") | Legal/privacy | Retention rules are configuration values, not constants; wording strings isolated for replacement |
| DL-02 | Client-content draft approval (101 flagged records) | Fitness professional | All 206 records render with `contentStatus` badge "DRAFT COPY · PENDING REVIEW"; status field flows end-to-end |
| DL-03 | Localisation: currency/units beyond GBP/UK | Product | GBP + metric/imperial per handoff; `Locale`-driven formatting isolated in one formatter layer |
| DL-04 | Web billing vs App Store billing split (11f XOR rule) — which channels launch first | Product + App Store review | Entitlement state machine supports both channels; channel is read-only server-driven fact |
| DL-05 | CDN host, URL scheme, manifest versioning specifics | Backend/content | `MediaManifest` contract mirrors `asset-cdn-integration.md`; base URL is environment config |
| DL-06 | Push provider topology & quiet-hours server evaluation ("notify now" bypass) | Backend | Client honours turn-9 rules; delivery semantics documented as not-guaranteed in copy |
| DL-07 | Database encryption at rest: SQLCipher licensing/size vs iOS Data Protection only | Eng lead | iOS Data Protection now; gap documented in ADR-0002 |
| DL-08 | Assistant-coach permission category taxonomy final list (13f) | Product | Category enum modelled from panel 13f; extensible, audited |
| DL-09 | CI setup (GitHub Actions macOS runner) — needs repo admin | Repo owner | Local commands documented in BUILD_AND_TEST.md |
| DL-10 | Minimum iOS version (handoff targets iPhone 16 Pro; assume iOS 17+?) | Product | project.yml targets iOS 17.0; trivially changeable pre-first-build |
| DL-11 | Backend contract ownership: MazidiNetworking protocols proposed as the API spec | Backend | Contracts written client-side, marked PROPOSED |

Resolved decisions move to ADRs.
