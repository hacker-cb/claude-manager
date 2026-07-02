#!/usr/bin/env bash
# Submit an artifact for notarization (App Store Connect API key) and staple it.
#
# Usage: notarize.sh <path-to-dmg-or-zip>
# Env:
#   AC_API_KEY_ID      App Store Connect API key id             [required]
#   AC_API_ISSUER_ID   App Store Connect issuer id              [required]
#   AC_API_KEY_PATH    path to the .p8 private key file         [required]
set -euo pipefail

ARTIFACT="${1:?usage: notarize.sh <artifact>}"
: "${AC_API_KEY_ID:?set AC_API_KEY_ID}"
: "${AC_API_ISSUER_ID:?set AC_API_ISSUER_ID}"
: "${AC_API_KEY_PATH:?set AC_API_KEY_PATH}"

echo "→ Submitting $ARTIFACT for notarization…"
xcrun notarytool submit "$ARTIFACT" \
  --key "$AC_API_KEY_PATH" \
  --key-id "$AC_API_KEY_ID" \
  --issuer "$AC_API_ISSUER_ID" \
  --wait

echo "→ Stapling…"
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
echo "✓ Notarized and stapled: $ARTIFACT"
