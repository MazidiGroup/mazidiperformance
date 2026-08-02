# Solicitor brief — Article 9 lawful basis and retention

**Status: DRAFT — for owner review before sending.**
**Phase 0 gate:** 4 (ADR-0013)
**Prepared:** 2 August 2026

Written to be sent more or less as-is. It states what has already been decided and built, so the
solicitor is asked to confirm or correct a position rather than to design one from nothing — the
cheaper and faster instruction.

Question 2 is the one that is blocking engineering work today.

---

## Background — one page

**The service.** Mazidi Performance is an iOS app for independent personal trainers ("coaches")
and their clients. A coach builds a training programme; the client records their training against
it; the client reports discomfort, injuries and limitations so the coach can adjust. Subscription
is paid by the coach. The app never takes payment from clients and never moves money — a coach
marks an invoice acknowledged, nothing more.

**Controller.** Mazidi Homes Limited (company number 15350516), Flat 55 Banstead Court, 60
Westway, London W12 0QJ. *Owner to confirm this is the correct legal person before sending — it is
an open item in our own checklist.*

**Current technical state — important context.** The app has **no backend**. Everything a client
enters is stored only on their own phone. Nothing is transmitted anywhere, and there are no
third-party processors in the live product today. A build has been distributed to internal
TestFlight (one tester — the owner). We are asking these questions **before** building the
server, not after.

**What we propose to build.** A backend (Supabase Pro, London region) so a coach can deliver
programmes and receive training records. No account has been created and no contract signed.

**The decision already taken.** We have decided to treat the training, discomfort and check-in
data as **special category data under Article 9**, and to design on that basis — granular
unbundled consent per purpose, an append-only consent-record table capable of demonstrating
consent under Art. 7(1), and an in-app withdrawal path meeting Art. 7(3). We have assumed the
condition is **explicit consent, Art. 9(2)(a)**. We recorded that as an assumption to be
confirmed, not a settled conclusion, which is why you are being asked.

We have taken the cautious route deliberately. If it is over-cautious we would rather be told.

---

## Question 1 — Is Article 9(2)(a) the right condition?

**What we are asking.** Is explicit consent under Art. 9(2)(a) the correct Art. 9 condition for a
personal trainer processing client training records, reported discomfort and injury limitations?
And is Art. 6(1)(b) (performance of a contract) the right Art. 6 basis to sit alongside it?

**Why we are unsure.** Two things give us pause.

First, whether this data is Art. 9 "data concerning health" at all. Sets, reps and load are not
obviously health data; a report of knee pain plainly is. We concluded the combination, held over
time by someone advising on physical activity, is best treated as health data throughout rather
than splitting the record. We would rather be told we have over-classified than under-classified.

Second, whether **Art. 9(2)(h)** (health or social care, and the management of health care
systems and services) is available to a personal trainer. We assumed it is not — a trainer is not
a health professional and there is no professional-secrecy obligation of the kind
Art. 9(3)/Sch. 1 contemplates. If that assumption is wrong it matters a great deal, because
9(2)(h) is not withdrawable at will and question 2 largely dissolves.

**Specific points to confirm:**

- Is Art. 9(2)(a) correct, or is another condition better suited?
- Is Art. 6(1)(b) the right companion basis?
- Does the consent remain freely given when providing the data is, practically, necessary to
  receive the service the client is paying for? We think yes, because the *coaching* is the
  contract and the client controls what they disclose — but this is precisely the "conditionality"
  point in Art. 7(4) and we would like it confirmed.
- Do we need a Data Protection Officer? We have not appointed one. Art. 37(1)(c) engages on
  large-scale Art. 9 processing; our scale is currently tiny but the processing is regular and
  systematic.

---

## Question 2 — Retention after consent is withdrawn *(blocking)*

**This is the one with a direct engineering consequence, and we have deliberately stopped work
rather than guess.**

**The conflict.** Two of our own product rules assume data survives withdrawal:

1. Cancelling a subscription never deletes client records — deletion and cancellation are
   different acts
2. Turning off sharing stops *future* sharing but never deletes past content

But Art. 9(2)(a) consent is withdrawable at will. If consent is the **sole** lawful basis for
holding health data, withdrawing it appears to remove the grounds for continuing to hold the
training history — history a coach may have professional or liability reasons to retain.

Both cannot be unconditionally true.

**What we need to know.**

- After a client withdraws consent for ongoing processing, is there a lawful basis to **retain**
  historical training and discomfort records? Art. 9(2)(f) (legal claims) is the candidate we can
  see; is it available prospectively, or only once a claim is in contemplation?
- If retention is lawful: **which records, and for how long?** We currently have no retention
  schedule and cannot write one until this is answered.
- Should withdrawal cause deletion, anonymisation, or **restriction** of historical records
  (Art. 18)? Restriction is our instinct — the record survives but is no longer used — but we do
  not want to reason ourselves into it.
- Does the answer differ for records the *coach* authored (the programme they wrote) versus
  records the *client* authored (their logged sets, their reported pain)? We suspect it does, and
  that the coach may have their own interest in their professional records.

**What is blocked.** We can safely build withdrawal so that it stops future processing, and we
have. What we cannot decide is what happens to **existing** data. Our copy must not imply
deletion while we retain — that would be a false statement to the client — so the wording is
blocked on the same answer.

---

## Question 3 — Does our consent design meet the standard?

We would value a yes/no on the mechanism as built, since it is already in a test build.

- **Granularity.** Separate consent per purpose — coaching delivery, analytics, and any future
  model inference are distinct. No single "I agree".
- **Evidence.** An append-only consent-record table: timestamp, the *version of the notice shown*,
  the specific purposes, and withdrawal state with its timestamp. Never overwritten in place, so a
  withdrawal does not erase evidence that consent previously existed.
- **Withdrawal.** In-app, per-purpose, no worse than granting — not an email to support.
- **Versioned notice.** The consent text is versioned and retained, so we can show what a given
  consent was consent *to*.

Is anything missing that would make the consent unable to bear the weight of Art. 7(1)?

---

## Question 4 — Two smaller points

**(a) Sufficiency of device encryption.** Client health data sits in a SQLite database on the
client's own iPhone, protected by iOS Data Protection and the device passcode; credentials are in
the Keychain. Is platform encryption alone sufficient under Art. 32 for special category data, or
should we add application-level encryption?

**(b) International access.** We plan to use a processor whose data centre is in London but whose
support staff may access systems from the United States. We intend to require the UK Addendum in
the body of the executed DPA. Is that the right mechanism, and is anything else needed given the
data is Art. 9?

---

## What we are not asking

We are not asking you to review the published privacy notice wording — that is a separate
instruction, and a separate list of questions exists for it. This brief is confined to the lawful
basis and retention, which is what blocks engineering.

---

## Our current position, for the avoidance of doubt

We have published a privacy notice describing the app as it is: no transmission, no third-party
processors, no export or deletion tooling. The owner approved publication without completed legal
review, and that decision is recorded in writing. We are conscious that the notice must change in
the same release as any of those statements ceasing to be true, and we have one instance to
correct now.

We would rather hear that we have been too conservative than discover we have been too relaxed.
