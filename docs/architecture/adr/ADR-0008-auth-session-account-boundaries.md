# ADR-0008 — Authentication sessions, role routing, and account-scoped data boundaries

**Status:** Accepted · 2026-07-24
**Amended by:** [ADR-0014](ADR-0014-local-device-identity.md) — a device-local test profile
occupies the provider slot in **Debug and Staging only** (`LOCAL_IDENTITY`), so TestFlight
builds can be opened while no backend exists. It amends §6 (a second non-production
provider, reaching release-style Staging builds) and §7 (in those builds the role claim
originates from a tester's choice, minted into a role-scoped account, rather than from a
backend). **Release is unchanged by that ADR** — see §6 below.

## Context
Until now the app had pseudo-authentication: `AppModel.activeRole` was a UI preference set
by DEBUG-only buttons, and the durable database was a single pre-identity file
(`Application Support/MazidiPerformance/mazidi-client.sqlite`). Nothing bound durable
client data to an identity, and role came from a tap, not a claim. No production
authentication backend exists (R-01) and none is fabricated here.

## Decisions

### 1. New package target `MazidiAuth`
Session state machine, provider-neutral contracts, credential-store contracts (+ in-memory
reference implementation and pure Keychain status mapping), the `SessionCoordinator`
actor, and account-database path derivation. Depends on `MazidiFoundations` and — an
explicit exception to ADR-0001's Foundation-only rule, in the spirit of ADR-0007's leaf
exceptions — **CryptoKit**, solely for SHA-256 in path derivation (hand-rolled crypto
rejected). Provider SDKs never appear in `MazidiDomain`, views, persistence records,
workout services, or sync transports; **no concrete provider (Firebase/Supabase/Auth0/
Cognito/…) is chosen** — that requires its own ADR when the backend decision (R-01) lands.

### 2. Session state machine (explicit, reducer-based)
`AuthPhase` models the states — signedOut(pendingRemoteRevocation:), authenticating,
authenticated, refreshing, offlineAuthenticated, sessionExpired, reauthenticationRequired,
signingOut, locked, authenticationFailed, revoked — and a pure reducer
`AuthPhase.reduce(_:event:)` defines every legal transition; illegal events leave the
state unchanged and are reported. Deterministic, exhaustively unit-tested; the
`SessionCoordinator` actor is the only writer.

### 3. Secrets vs metadata
Tokens (access/refresh + expiry) live **only** in the Keychain behind
`CredentialStore` — never UserDefaults, files, logs, or state enums. Accessibility class:
**`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`** — survives a locked device after
first unlock (background sync-queue drains can authenticate) but never migrates to
another device via backup, matching ARCHITECTURE.md §4. Non-secret session metadata (last
account ID, cached role claims for offline restore) lives in a separate metadata store
(UserDefaults) and is explicitly not a credential. Sign-out deletes credentials; metadata
of the signed-out account is cleared with them.

### 4. Account-scoped databases
Per-account directory: `Application Support/MazidiPerformance/accounts/<derived>/` where
`<derived>` = hex(SHA-256("com.mazidigroup.mazidi.account-db.v1|" + stableAccountID))
truncated to 32 hex chars. Domain-separated (the version-tagged prefix means the same
account ID hashed for any other purpose yields a different value); no raw account ID,
email, name, or token ever appears in a path. Same account → same directory,
deterministically; different accounts can never collide in practice. The GRDB store gains
`close()`; the active store is closed **before** any account transition and every
repository call after close throws — signed-out data is unreachable through the app.
Corruption recovery (ADR-0007) operates inside one account directory only.

### 5. Legacy development database policy
The pre-identity `mazidi-client.sqlite` directly under `MazidiPerformance/` is **left in
place and never silently adopted** by any authenticated account (account directories are
strictly under `accounts/`). It contains development-only data; if a future need arises to
attach it to an identity, that will be an explicit, user-visible migration. Sign-out never
deletes account files — deletion is a separate account-lifecycle operation (turn 13g),
out of scope here.

### 6. Development provider
`DevelopmentAuthProvider` lives in the **app target inside `#if DEBUG`** — it does not
exist in Release builds (proved by binary checks + a Release-configuration UI test).
Deterministic fixture identities (`dev-client-001`, `dev-client-002`, `dev-coach-001`),
clearly labelled, no production credentials, tokens prefixed `dev.` and valid only for
this provider. In Release the provider slot is `UnavailableAuthProvider`, which fails
typed and honest ("sign-in arrives with the backend contract", R-01) — no role can be
obtained in Release by any preference, launch argument, or environment variable.

*Amendment (ADR-0014):* Debug **and Staging** additionally compile
`LocalDeviceAuthProvider` behind the `LOCAL_IDENTITY` compilation condition, because
Staging is a release-style build that `#if DEBUG` cannot reach and TestFlight builds would
otherwise be unusable. It is a local test profile, not authentication, and is labelled as
such in the UI. **Release still has only `UnavailableAuthProvider`**, and
`Scripts/check-release-isolation.sh` fails the build if any local-identity or development
symbol is found in a Release binary.

### 7. Role routing from claims only
The shells route from validated `SessionClaims.roles`: exactly `[.client]` → Client
shell, exactly `[.coach]` → Coach shell; **missing or conflicting role sets land in a
safe error state** (visible, non-crashing, offering sign-out). A signed-in identity maps
to one active role context (ARCHITECTURE.md §4); assistant-coach and relationship-scoped
authorization remain deferred.

*Amendment (ADR-0014):* in `LOCAL_IDENTITY` builds the claims a shell routes from may have
been issued by the local test profile, whose role the tester picked before any session
existed. Routing itself is unchanged — it still reads only `SessionClaims`, still allows
exactly one role, and each role is a **separate account id** with its own account-scoped
database, so switching role is an account switch, not a preference toggle.

### 8. Stale-task protection: session generations
The coordinator increments a monotonically increasing **generation** on every sign-in,
sign-out, and account switch. Every async completion (sign-in result, refresh result,
revocation discovery) is applied only if its captured generation is still current;
otherwise it is discarded. The app layer tears down the account's `ClientEnvironment`
(closing the database) on generation change, so a stale task can neither update the
session nor write into another account's database (its store handle throws after close).

### 9. Refresh + expiry policy
`ensureValidSession()` refreshes when the access token is near expiry (injected clock;
deterministic tests); concurrent callers share one in-flight refresh task (deduplicated);
refresh results carrying a stale generation are dropped, preventing reactivation after
sign-out. Refresh failure classifies: network-unreachable → `offlineAuthenticated`
(honest local-only state), rejected-by-provider → `reauthenticationRequired`. No retry
loops: refresh runs on demand, never on a timer.

### 10. Offline policy (summary; full text in SECURITY_BOUNDARIES.md)
A previously authenticated user reopens the app offline into `offlineAuthenticated`:
local account data stays available, mutations keep queueing durably (ADR-0003), and the
UI says "saved on this phone", never implying server validation. Access-token expiry
offline does not lock the user out of their own local data; server-validated actions
(none exist yet — R-01/R-02) require a fresh token when connectivity returns. Revocation
discovered on reconnect signs the account out; **an offline sign-out is reported honestly
as local-only** (`signedOut(pendingRemoteRevocation: true)`) — never presented as
confirmed remote revocation.

## Consequences
- The app root becomes a function of `AuthPhase` — every state has a screen, including
  storage-recovery/database-failure (a signed-in user whose account database cannot open
  is NOT presented as normally signed in with data access).
- `locked` exists in the machine and UI as a minimal local-lock surface; biometric
  wiring (13c) is deferred and tracked in KNOWN_ISSUES.
- Remote revocation is contract-only until a backend exists: discovery is modelled
  (provider callback + reconnect check), guarantees are not claimed (13c honesty).
- The existing UI-test entry (`dev_continue_client`) becomes a real coordinator sign-in
  against the development provider, preserving test identifiers.
