# ADR-0014 — Local device test profile for TestFlight builds (no authentication)

**Status:** Accepted · 2026-07-31
**Amends:** ADR-0008 §6, §7 (role routing from validated claims; provider slots)
**Superseded when:** the authentication provider decision (R-01) lands and a real backend
issues sessions.

## Context

The app has no authentication backend (R-01), and ADR-0008 deliberately did not fabricate
one: in Release the provider slot is `UnavailableAuthProvider`, which throws
`providerUnavailable` for every operation. The consequence is that a Release build boots to
`SignInView`, and tapping anything lands on "Sign-in failed" with no way forward. Every
shell sits behind `session.route`, which is only reachable from validated claims, so a
distributed build is **unusable** — nothing beyond the signed-out screen can be seen,
reviewed, or tested on a real device.

Development identities (`DevelopmentAuthProvider`, ADR-0008 §6) solve this for Debug only.
TestFlight builds are release-style builds, so `#if DEBUG` does not reach them.

The owner needs testers on real devices now, to validate UX. The product itself — coaches
and their clients, sharing data — genuinely requires the backend that does not exist; that
is not what this decision delivers.

## Decision

Ship a **local device test profile** for TestFlight **only**, explicitly **not** the App
Store. It is not authentication and is never described as such anywhere in the app.

### 1. A build-configuration boundary, not a runtime flag

A new Swift compilation condition **`LOCAL_IDENTITY`** is set for **Debug and Staging
only** (`project.yml`, target `MazidiPerformance`, `SWIFT_ACTIVE_COMPILATION_CONDITIONS`).
Staging is the TestFlight configuration and is a *release-style* build, which is precisely
why the gate cannot be `#if DEBUG`.

**Release has no entry and is unchanged.** It keeps `UnavailableAuthProvider`, so an
accidental App Store submission still cannot sign in — the failure mode stays the honest
one. The boundary is verified on the built artefact, not just asserted in source:
`Scripts/check-release-isolation.sh` scans the Release binary's symbol table and strings for
every local-identity and development symbol (and for a positive control, so a broken check
cannot pass silently). It runs in CI after the Release build.

No runtime switch — no launch argument, environment variable, defaults key or entitlement —
can enable the profile in a Release binary, because the code is not in it.

### 2. The identity: one device UUID in the Keychain

`LocalDeviceAuthProvider` mints a `LocalDeviceProfile`: a random UUID generated once and
stored in the Keychain under its own service (`com.mazidigroup.mazidi.local-profile`,
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, deliberately separate from the auth
credential item so it can never be confused with, or overwrite, real credentials). Same
device → same UUID across launches → the same account-scoped database (ADR-0008 §4) is
found again, so a tester's data persists.

The UUID is random and opaque: no email, name, device identifier, or advertising id; it
never leaves the device and never appears in a path (paths hash it, ADR-0008 §4). Local
tokens are opaque `local-test-profile.*` strings with a far-future sentinel expiry — nothing
issues or verifies them, so the coordinator's refresh/expiry machinery stays inert rather
than pretending a lifetime nothing could renew.

### 3. Nothing about the session architecture is bypassed

`LocalDeviceAuthProvider` conforms to the existing `AuthProviding` contract and returns a
normal `ProviderSession` with valid `SessionClaims`. `SessionCoordinator` remains the only
writer of session state: the `AuthPhase` machine, generations, credential storage,
account-scoped database derivation and teardown all run unchanged. `restore` reports
`validatedRemotely: false` and `checkRevocation` returns `.unknown` — the provider never
claims knowledge it cannot have.

In DEBUG the provider also forwards the ADR-0008 §6 fixture identities to
`DevelopmentAuthProvider`, so existing development and UI-test journeys are untouched. That
forwarding does not exist in Staging.

### 4. Two account ids, one per role — not one shared id

A signed-in identity maps to exactly one role (ADR-0008 §7), but a single tester on one
device must be able to see both shells or half the app cannot be tested. So the tester
chooses a role at first launch and can switch afterwards, and each role gets its **own**
account id: `local-test-profile.v1.<uuid>.<coach|client>`.

Rejected alternative: one shared account id for both roles. It was rejected because

- one id means both shells write into one account-scoped database, which is the exact
  condition ADR-0008 §4 exists to prevent — a bug that leaked coach rows into client reads
  would be invisible in test builds and only appear in production;
- two ids exercise the real account-scoped paths, the real teardown, and the real
  audit-actor separation, so testing the test build tests the shipping architecture;
- the hoped-for benefit of one id — a coach seeing their own client's data — does not
  actually exist: assignment delivery between accounts runs through
  `DevelopmentAssignmentRelay`, which is DEBUG-only and deliberately stays that way. One id
  would produce mixed data, not a working coach→client flow.

### 5. Role switching is an account switch

`SessionModel.switchLocalRole(to:)` performs a full `coordinator.signOut()` — generation
bump, environments invalidated, account database closed, credentials deleted — and only then
signs in as the other role's account, which derives its own directory. There is no shortcut
path and no shared state between the two shells.

### 6. Honest UI

Wherever the profile is visible it is labelled a **local test profile**, never an account
and never a sign-in:

- the signed-out surface keeps "Sign-in arrives with the backend contract" and adds a role
  chooser stating "No sign-in and no account. Everything stays on this phone and nothing is
  synced or shared";
- both shells carry a persistent bottom banner repeating that sentence with the active role
  and the switch control.

Copy is single-sourced (`LocalProfileCopy`) so the limitation is worded identically
everywhere. Design tokens are the only colour source; status is carried by text plus an SF
Symbol, never colour alone; the banner is a vertical stack so it restacks rather than clips
at AX5; controls carry identifiers, labels and hints and inherit the 44 pt minimum target
from the shared button styles.

## Consequences

- **Departure from ADR-0008 §7** is confined to *where the claims originate* in test builds.
  Routing still reads only `SessionClaims`; the role choice happens before a session exists
  and is minted into a role-scoped account. No view reads a role preference.
- **No cross-role leakage risk in this configuration.** There is one local user, on one
  device, with no network: no other party's data exists on the device to leak, the two roles
  occupy separate databases and separate audit chains, and the sync transport is inert
  (`SYNC_BASE_URL` is empty — ADR-0012; the fake backend is DEBUG-only).
- **This is not a step toward shipping without auth.** It is unusable as a product: two
  profiles on one phone cannot be a coach and their client. It exists to validate UX on real
  devices and is deleted, not migrated, when a provider is chosen (R-01).
- **App Store submission is out of scope by construction.** If the Release configuration is
  ever submitted it behaves exactly as before this ADR — the signed-out wall.
- Trackers: `docs/KNOWN_ISSUES.md` (L13) records the TestFlight-only constraint and the
  removal condition.
