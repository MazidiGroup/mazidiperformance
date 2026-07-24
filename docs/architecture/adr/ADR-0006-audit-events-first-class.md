# ADR-0006 — Audit events: typed, append-only, transactional, separate from analytics

**Status:** Accepted · 2026-07-23

Consequential actions (permission/assistant-access changes, payment amendments, programme publication & safety edits, progression approval, relationship termination, exports, deletion requests, remote sign-out, sensitive-record access, alert acknowledgement/resolution) emit a typed `AuditEvent` written in the **same local transaction** as the action and synced through the durable operation queue.

- Append-only; locally hash-chained (each event stores the previous event's hash) for tamper evidence at the application level.
- Sync durability equals data durability — audit is not client-side analytics.
- Analytics is a separate pipeline; no sensitive client content in analytics payloads.
