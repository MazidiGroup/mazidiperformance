# Security boundaries — authentication, sessions, account data

Companion to ADR-0008. What is implemented, what is deferred, and what must never happen.
Honesty rule: nothing below claims backend, encryption, or revocation behaviour that does
not exist (R-01/R-02, DL-07).

## Credential storage
- Access/refresh tokens: **Keychain only**, service `com.mazidigroup.mazidi.auth`,
  accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (available after first
  unlock for background queue drains; never migrates devices via backup). Typed errors
  (`CredentialStoreError`); no force unwraps; update = atomic delete-insert
  (`SecItemUpdate` fallback to add); explicit deletion on sign-out; **no silent fallback
  to any other storage** — a Keychain failure surfaces as an error state.
- Never in UserDefaults, files, logs, analytics, screenshots, or test reports. The
  `AuthCredentials` type is not `CustomStringConvertible`-leaky: its description redacts
  token bodies.
- Non-secret metadata (last account ID, cached role claims for offline restore) lives in
  UserDefaults under `mazidi.session.metadata` — deliberately separate from credentials
  and cleared on sign-out.

## Account-scoped databases
- Path: `Application Support/MazidiPerformance/accounts/<hash32>/mazidi-client.sqlite`,
  `hash32 = hex(SHA-256("com.mazidigroup.mazidi.account-db.v1|" + accountID))[0..<32]`.
  Raw identifiers never appear in paths; domain separation ensures the hash is unique to
  this purpose. Deterministic: same account → same directory across launches.
- Transitions: the active store is **closed before** any sign-out/switch; post-close
  repository calls throw; the app tears down account services on session-generation
  change, so stale tasks cannot write into another account's database.
- Corruption recovery (ADR-0007 quarantine) stays inside the affected account's
  directory; other accounts are untouched.
- Legacy pre-identity database (`MazidiPerformance/mazidi-client.sqlite`): preserved,
  never silently adopted by an authenticated account, never migrated implicitly.
- Sign-out **preserves** account files. Deletion is a separate lifecycle operation
  (turn 13g), not implemented in this milestone.

## Offline session policy
- Reopening offline with previously stored credentials → `offlineAuthenticated`: local
  account data available; mutations queue durably (ADR-0003); sync status says "saved on
  this phone"/"waiting to sync", never "synced" or "verified".
- Expiry is evaluated against the injected clock. An expired access token offline does
  not lock the user out of local data; it gates server-validated actions (none exist yet).
  When connectivity returns, refresh runs; a rejected refresh → reauthentication
  required; a revocation discovered on reconnect → signed out with the revoked state
  surfaced.
- Offline sign-out: local credentials/state are cleared immediately, provider revocation
  is queued as pending; the UI states plainly that remote sign-out completes when back
  online — a failed server revocation is never presented as confirmed.
- Safety-first availability: existing-client care (the client's own local workout data;
  the coach-side equivalent when it exists) stays readable offline. Growth/high-risk
  actions requiring fresh server validation: none shipped yet; the classification hook
  lives with the entitlement policy (ADR-0004) when the backend lands.

## Role and routing
- Role comes only from validated session claims. Client → Client shell; Coach → Coach
  shell; missing/conflicting claims → safe error state offering sign-out. No preference,
  UserDefaults key, launch argument, or environment variable can change role in Release
  (dev provider is compiled out; binary-checked and tested per release configuration).

## Coach programming & assignments (ADR-0009)
- Programming writes are reachable only from the Coach shell (validated coach claims);
  clients hold only their own assignment rows inside their account database, filtered
  again by assignee on read (defence in depth). Cross-account isolation is structural:
  the other party's data lives in a database this session cannot open.
- **Remaining server requirement (R-01/R-02):** relationship-level authorization (which
  coach may assign to which client) and real delivery/receipt confirmation cannot be
  enforced on-device and are deferred to the backend. Coach-side status therefore never
  claims delivery ("Queued — delivery confirms with backend").
- The DEBUG-only `DevelopmentAssignmentRelay` copies assignment rows between dev fixture
  accounts on one device as the delivery stand-in; it never runs in Release, never
  relays to non-fixture identities, and never fabricates delivery confirmation.

## Deferred (recorded, not fabricated)
- Production auth provider + token endpoints (R-01; provider choice needs its own ADR).
- Server-side revocation guarantees & "signed out everywhere" (13c honest-limitation copy
  ships with that feature).
- Biometric/local-lock enforcement (13c): the `locked` state exists; policy TBD.
- SQLCipher at-rest encryption decision (DL-07) — currently iOS Data Protection only.
- Account deletion / retention flows (13g/13j; legal review pending).
