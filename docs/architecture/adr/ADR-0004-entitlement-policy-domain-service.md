# ADR-0004 — Entitlements enforced by a single domain policy service

**Status:** Accepted · 2026-07-23

Subscription/entitlement gating (turn 11, panel 11f) is answered by one `EntitlementPolicy` service in `MazidiServices`: `can(actor, perform: Action, on: Context) -> Decision`. Views and view-models never hand-roll plan checks.

Invariants encoded and unit-tested:
- Restricted/grace/cancelled states block **growth actions only** (new activations, invitations, assistant seats, plan-gated growth features).
- **Existing-client care is always permitted**: programme safety edits, exercise replace/remove, messaging, check-in review, discomfort responses, progression review, data export, historical-record access.
- Downgrade over client limit never disables existing clients.
- Decisions carry a user-facing reason for honest UI copy.
