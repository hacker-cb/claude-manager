#!/usr/bin/env bash
# Package dist/export/Claude Manager.app into a signed DMG at dist/ClaudeManager-<version>.dmg.
#
# Env:
#   VERSION           marketing version for the filename        [default: 0.0.0]
#   SIGNING_IDENTITY  Developer ID Application identity          [optional; signs the DMG]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/dist/export/Claude Manager.app"
[ -d "$APP" ] || { echo "App not found at $APP — run build-app.sh first" >&2; exit 1; }

VERSION="${VERSION:-0.0.0}"
DMG="$ROOT/dist/ClaudeManager-${VERSION}.dmg"
rm -f "$DMG"

if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "Claude Manager" \
    --window-size 540 360 \
    --icon-size 110 \
    --icon "Claude Manager.app" 140 180 \
    --app-drop-link 400 180 \
    "$DMG" "$APP" || rm -f "$DMG"
fi

if [ ! -f "$DMG" ]; then
  # Fallback: plain hdiutil DMG with an /Applications drop link.
  STAGING="$ROOT/dist/dmg-staging"
  rm -rf "$STAGING"; mkdir -p "$STAGING"
  cp -R "$APP" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "Claude Manager" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
  rm -rf "$STAGING"
fi

if [ -n "${SIGNING_IDENTITY:-}" ]; then
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
fi

echo "✓ DMG: $DMG"
echo "dmg=$DMG" >> "${GITHUB_OUTPUT:-/dev/null}"
