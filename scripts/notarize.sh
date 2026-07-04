#!/usr/bin/env bash
# Submit an artifact for notarization (App Store Connect API key), staple it, and
# assert Gatekeeper accepts it. Handles a bare .app (zipped for submission) or a .dmg.
#
# Usage: notarize.sh <path-to-app-or-dmg>
# Env:
#   AC_API_KEY_ID      App Store Connect API key id             [required]
#   AC_API_ISSUER_ID   App Store Connect issuer id              [required]
#   AC_API_KEY_PATH    path to the .p8 private key file         [required]
set -euo pipefail

ARTIFACT="${1:?usage: notarize.sh <artifact>}"
: "${AC_API_KEY_ID:?set AC_API_KEY_ID}"
: "${AC_API_ISSUER_ID:?set AC_API_ISSUER_ID}"
: "${AC_API_KEY_PATH:?set AC_API_KEY_PATH}"

KEY_ARGS=(--key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID")

# notarytool submits a zip/dmg/pkg — a bare .app must be zipped first. Stapling,
# however, always targets the .app/.dmg itself, never the submission zip.
SUBMIT="$ARTIFACT"
CLEANUP=""
case "$ARTIFACT" in
*.app)
  SUBMIT="${ARTIFACT%.app}.notary.zip"
  rm -f "$SUBMIT"
  ditto -c -k --keepParent "$ARTIFACT" "$SUBMIT"
  CLEANUP="$SUBMIT"
  ;;
esac

echo "→ Submitting $SUBMIT for notarization…"
# Capture the JSON result even on a non-zero exit (Invalid submission) so we can dump
# the per-file rejection reasons instead of failing blind with a bare summary table.
RESULT="$(xcrun notarytool submit "$SUBMIT" "${KEY_ARGS[@]}" --wait --output-format json || true)"
echo "$RESULT"
ID="$(printf '%s' "$RESULT" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("id", ""))' 2>/dev/null || true)"
STATUS="$(printf '%s' "$RESULT" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("status", ""))' 2>/dev/null || true)"

if [ "$STATUS" != "Accepted" ]; then
  echo "✗ Notarization status: '${STATUS:-unknown}' — full log:" >&2
  if [ -n "$ID" ]; then xcrun notarytool log "$ID" "${KEY_ARGS[@]}" /dev/stderr || true; fi
  if [ -n "$CLEANUP" ]; then rm -f "$CLEANUP"; fi
  exit 1
fi
if [ -n "$CLEANUP" ]; then rm -f "$CLEANUP"; fi

echo "→ Stapling…"
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"

# stapler validate only proves "ticket attached" — assert Gatekeeper would actually
# accept it, so a signing/entitlements/runtime regression fails CI, not the user.
case "$ARTIFACT" in
*.app) spctl --assess --type execute --verbose=4 "$ARTIFACT" ;;
*.dmg) spctl --assess --type open --context context:primary-signature --verbose=4 "$ARTIFACT" ;;
esac
echo "✓ Notarized, stapled, Gatekeeper-accepted: $ARTIFACT"
