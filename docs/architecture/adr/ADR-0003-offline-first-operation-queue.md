# ADR-0003 — Offline-first mutation pipeline: durable operation queue, idempotency keys, classified conflicts

**Status:** Accepted · 2026-07-23

## Context
The handoff (panels 4i, 5f, 7i, 14h) requires honest offline behaviour: local-first workout writes, duplicate prevention, ordered replay, the one-device rule with read-only recovery of superseded offline sessions, and no silent data loss. The brief forbids blanket last-write-wins.

## Decision
1. Every mutation is expressed as a typed `SyncOperation` (JSON payload + metadata) written to a durable local `operation_queue` table **in the same transaction** as the optimistic local state change.
2. Each operation carries a client-generated UUID **idempotency key**; the server contract requires at-most-once application per key and returns the canonical result on key replay. Retries are therefore always safe.
3. Replay is **ordered per aggregate** (sequence number per aggregate id); independent aggregates replay concurrently.
4. Conflicts are **classified per domain** (see ARCHITECTURE.md §5): append-only facts union by key; single-writer aggregates follow the session-epoch one-device rule with superseded-session read-only recovery; coach-authored config uses revisions + explicit merge; task-state uses a monotonic lattice.
5. Failure taxonomy: retryable (network/5xx/timeout) → backoff + retry, same key; terminal-rejected (validation/authz) → parked with user-visible status, never dropped silently; auth-expired → queue paused until re-auth, then resumes.
6. Sync status is user-visible truth: "saved on this phone", "waiting to sync (n items)", "sync issue — needs attention". Never claim synced when only locally persisted.

## Consequences
- The queue is the only path to the network for mutations — no view fires ad-hoc writes.
- Crash/kill at any point leaves either (a) nothing, or (b) local state + queued op — both recoverable. This invariant is unit-tested.
- Server API must implement idempotency-key storage; recorded as backend dependency R-02.
