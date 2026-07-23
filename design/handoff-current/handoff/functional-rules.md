# Functional & safety rules

## Notifications & inbox (turn 9, 13d)
- Badge counts unresolved needs-action items only; opening or "Mark all read" never clears it — only Acknowledge/Resolve does.
- Every event type has a fixed destination; every row names its deep link. "Sync issue" and "Awaiting you" are text labels — colour is never the only signal.
- Quiet hours: inbox updates immediately; normal pushes wait; discomfort alerts marked "notify now" may bypass when permission/connectivity allow; if delivery is prevented, the alert shows on next app open. Never imply guaranteed emergency monitoring.

## Client payments (turn 10)
- The app never moves money: no checkout, no card storage, no auto-collection. "Mark as paid" is the only acknowledgement of money.
- Records: amount, effective date, method, recorded-by, timestamp, optional note. Edits create amendments (original kept, visible to both sides); no deletion, void-with-reason only. CSV export.
- Overpayment prompts a choice: credit next renewal / leave unallocated / refunded outside Mazidi — audited, visible both sides.
- Overdue never auto-locks a client; all restrictions are coach-initiated with honest client-facing wording.
- Package templates are versioned: clients keep the snapshot they accepted; edits affect future assignments unless applied with an explicit effective date + confirmation.

## Coach subscription (turn 11)
- Wholly separate from client payments — no shared screens, totals or notifications; clients never see coach billing state.
- No plan change, cancellation, restriction or deletion ever removes client records. Downgrade over limit: existing clients continue normally; only new activations/invites blocked.
- Restricted status still permits full care of existing clients (programme edits incl. safety changes, discomfort responses, messaging, check-ins, export).

## Calendar (turn 12)
- Timed commitments only; workouts never pin to times; tasks (check-ins, renewals) are inbox chips, not events.
- Conflicts warn (with buffer-aware next-free-slot) but never hard-block. Proposals keep the original slot booked; accepted slots are revalidated before confirming.
- Device sync: publish-out hides client surnames by default; busy-in never reads titles; stable external IDs prevent duplicates; disconnect removes published events, never app data.

## Privacy (turn 13)
- Per-coach, per-category client consent; new coaches start at zero. Turning sharing off stops future sharing, never deletes past content.
- Assistants are least-privilege, client-specific, audited; never billing/prices; clients can directly limit or revoke sensitive access, with both sides notified.
- Relationship end: coach loses training-data access immediately; keeps payment/package records (accounting), own notes, frozen messages. Client keeps everything of theirs.
- Deletion ≠ cancellation. Deletion: consequences screen → password+2FA → 14-day cooling-off → progress → completion; never half-deleted; waits for running exports.
- Export links: authenticated + recent reauth, 7-day expiry, revocable, dead after deletion cooling-off, never public URLs in email.

## Exercise content (turn 7)
- Visible copy comes from the client-content layer (displayName, clientDescription/Instructions/Mistakes/Benefits, defaultCue) keyed by stable slug — vendor text is never shown raw; useCases stays internal.
- Status: auto-prepared DRAFT pending fitness-professional review (101/206 flagged). UI badges say "DRAFT COPY · PENDING REVIEW".
- Media: muted loop, poster-first, only the opened exercise animates; text instructions always available; the 206-video library is never bundled or auto-downloaded over cellular.
