#!/usr/bin/env bash
# Release isolation check — proves the configuration boundary is real, not just intended.
#
# The local device test profile (ADR-0014) and the development fixture identities
# (ADR-0008 §6) must NOT exist in a Release binary: Release keeps `UnavailableAuthProvider`
# so an accidental App Store submission still cannot get past the signed-out surface.
# Compilation conditions are easy to get wrong silently (a stray `#if DEBUG`, an added
# xcconfig line), so this checks the built artefact instead of the source.
#
# Usage:
#   Scripts/check-release-isolation.sh <path to Release .app or its executable>
#
# Exits non-zero and prints every offending symbol when the boundary is breached.

set -euo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "usage: $0 <Release .app bundle or executable>" >&2
  exit 2
fi

if [ -d "$TARGET" ]; then
  BINARY="$TARGET/$(basename "$TARGET" .app)"
else
  BINARY="$TARGET"
fi

if [ ! -f "$BINARY" ]; then
  echo "FAIL: no executable found at $BINARY" >&2
  exit 2
fi

# Mangled Swift symbol names, reflection metadata and string literals all live in the
# binary; scan both the symbol table and the raw strings so a symbol cannot hide in either.
SCAN="$(mktemp)"
trap 'rm -f "$SCAN"' EXIT
{ nm -a "$BINARY" 2>/dev/null || true; strings -a "$BINARY" 2>/dev/null || true; } > "$SCAN"

# Sanity: the scan must have found *something*, otherwise an empty file would pass silently.
if [ ! -s "$SCAN" ]; then
  echo "FAIL: could not read symbols or strings from $BINARY" >&2
  exit 2
fi

# Positive control — a Release-only string that must be present. If this disappears the
# check itself is broken (wrong binary, stripped artefact) and must not report success.
POSITIVE="Sign-in isn't available yet"

# Everything that may only exist in LOCAL_IDENTITY (Debug + Staging) or DEBUG builds.
FORBIDDEN=(
  "LocalDeviceAuthProvider"
  "LocalDeviceProfile"
  "LocalDeviceAccount"
  "LocalProfileChooser"
  "LocalProfileBanner"
  "LocalProfileShell"
  "LocalProfileCopy"
  "local_profile_"
  "local-test-profile"
  "com.mazidigroup.mazidi.local-profile"
  "Local test profile"
  "DevelopmentAuthProvider"
  "DevelopmentFileCredentialStore"
  "dev_continue_"
  "MAZIDI_STORE_MODE"
  "MAZIDI_AUTH_RESET"
)

status=0

if ! grep -qF "$POSITIVE" "$SCAN"; then
  echo "FAIL: positive control missing — expected the Release sign-in message in $BINARY" >&2
  status=1
fi

for symbol in "${FORBIDDEN[@]}"; do
  if grep -qF "$symbol" "$SCAN"; then
    echo "FAIL: '$symbol' is present in the Release binary $BINARY" >&2
    grep -F "$symbol" "$SCAN" | head -3 >&2
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "OK: Release binary contains no local-identity or development symbols ($BINARY)"
fi

exit "$status"
