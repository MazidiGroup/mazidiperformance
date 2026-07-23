# State machines

## Client payment (panels 10f, 10g)
Scheduled → Paid early (before due; closes the renewal, next one scheduled per cadence) — or → Due (renewal date) → Paid (coach records) / Overdue (after grace, default 3 days) → Paid · Paused · Ended.
- Time-based: Due, Overdue. Coach actions: Paid, Paused, Ended. Nothing auto-charges.
- Reporting uses actual received date, with the allocated renewal shown alongside.
- Partial payment keeps renewal Due with remaining amount; duplicate allocation warns pre-save; "Paid on" cannot be future-dated; saved records amend, never delete.

## Coach entitlement (panel 11f)
Trial (14d) → Active → Past due (retries) → Grace (14d, full access) → Restricted (growth actions blocked) → Cancelled ⇄ Reactivated.
- Trial end without a plan → Restricted, never data loss. Successful payment from any state → Active.
- Upgrades immediate + prorated; downgrades/annual switches at next renewal; explicit confirmation with exact amount/date before any paid change.
- Billing channels: web (card, VAT invoices, in-app changes) XOR App Store (Apple owns charging; app shows read-only state).

## Calendar proposal (panels 12d/12e/12f)
Booked → Proposal sent (original stays booked) → client picks → revalidate slot → Confirmed (rebooked) / Slot taken (original stays; client re-picks or messages) / Expired (reverts, both notified).
Recurring events: local start + IANA zone + duration + RRULE + occurrence timestamps + per-occurrence exceptions; edits offer this / this-and-following / series; DST-stable.

## Account deletion (panels 13g/13j)
Request → consequences (affected clients, unsynced-data warning, export offer) → password + 2FA → 14-day cooling-off (cancellable anywhere) → deleting (progress) → complete (email) | failure (halt safely, retry).
Data categories: deleted personal/profile · deleted programme/operational · client-owned retained with client · accounting records retained for defined period · anonymised analytics · dispute/legal-hold preserved. Retention periods pending legal review.
