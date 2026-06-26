#!/usr/bin/env bash
# Create a STABLE self-signed code-signing identity so MeetGist keeps a constant code
# identity across rebuilds. macOS TCC keys the Microphone / Screen-Recording grants on
# that identity; an ad-hoc build (the Xcode default with no team) gets a *new* identity
# every build, which is why grants never persist, the app never lists under
# Privacy > Microphone, and each relaunch looks like "a different version".
#
# Fully non-interactive: the cert lives in a dedicated keychain whose password this
# script sets, so `set-key-partition-list` needs no login-keychain password and codesign
# never shows an "allow access" dialog. Idempotent — re-running is a no-op once it exists.
#
# To undo: security delete-keychain "$HOME/Library/Keychains/meetgist-signing.keychain-db"
# and remove it from the search list (security list-keychains -d user shows the list).
set -euo pipefail

IDENTITY="MeetGist Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/meetgist-signing.keychain-db"
KC_PASS="meetgist-local"   # local dev keychain; nothing secret is protected by it

# Note: a self-signed cert is untrusted, so `find-identity -v` (valid-only) never lists
# it. Use the unfiltered list for the idempotency check, and make sure the keychain is
# unlocked + searchable so codesign/xcodebuild can use it on this and later runs.
ensure_unlocked_and_searchable() {
  [ -f "$KEYCHAIN" ] || return 0
  security unlock-keychain -p "$KC_PASS" "$KEYCHAIN" 2>/dev/null || true
  local existing
  existing="$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')"
  case " $existing " in
    *" $KEYCHAIN "*) : ;;
    *) security list-keychains -d user -s $existing "$KEYCHAIN" ;;
  esac
}

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  ensure_unlocked_and_searchable
  echo "✓ signing identity already present: $IDENTITY"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Self-signed cert with a codeSigning extended-key-usage.
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -subj "/CN=$IDENTITY/O=MeetGist" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# `-legacy` so OpenSSL 3 writes a PKCS#12 the macOS `security` importer can read
# (modern AES-MAC p12 fails with "MAC verification failed"). Use a real password.
openssl pkcs12 -export -legacy -out "$TMP/id.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout pass:"$KC_PASS" -name "$IDENTITY"

# 2. Dedicated keychain (we own its password → no interactive prompts).
if [ ! -f "$KEYCHAIN" ]; then
  security create-keychain -p "$KC_PASS" "$KEYCHAIN"
fi
security set-keychain-settings "$KEYCHAIN"          # no auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"

# 3. Add to the user search list (preserving what's already there) so codesign/Xcode
#    can find the identity. Idempotent.
EXISTING="$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')"
case " $EXISTING " in
  *" $KEYCHAIN "*) : ;;                              # already in the list
  *) security list-keychains -d user -s $EXISTING "$KEYCHAIN" ;;
esac

# 4. Import the identity and grant codesign access without prompts.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$KC_PASS" -A -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null

echo "✓ created signing identity: $IDENTITY"
security find-identity -v -p codesigning | grep "$IDENTITY" || true
