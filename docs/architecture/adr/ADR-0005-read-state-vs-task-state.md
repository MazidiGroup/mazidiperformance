# ADR-0005 — Notification read state and task state are independent axes

**Status:** Accepted · 2026-07-23

Per turn 9 (panels 9b/9d) and the brief: an inbox item has `readState ∈ {unread, read}` and, independently, `taskState ∈ {none, needsAction, acknowledged, snoozed(until), resolved}`.

- Badge counts = items with `taskState == needsAction` (or snooze elapsed) — never unread count.
- Opening an item sets read, never acknowledges or resolves.
- "Mark all read" never clears the badge.
- Snooze re-surfaces at expiry; acknowledged-but-unresolved remains visible as unresolved.
- Task-state transitions are a monotonic lattice for sync conflict purposes (resolved wins).
- Every actionable item carries a typed deep-link destination (9d taxonomy).
