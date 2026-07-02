#!/usr/bin/env bash
# Archive + export a Developer ID-signed Claude Manager.app into dist/export/.
#
# Env:
#   DEVELOPMENT_TEAM   Apple Team ID (10 chars)               [required]
#   SIGNING_IDENTITY   e.g. "Developer ID Application: … (TEAMID)"  [required]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM}"
: "${SIGNING_IDENTITY:?set SIGNING_IDENTITY}"

DIST="$ROOT/dist"
ARCHIVE="$DIST/ClaudeManager.xcarchive"
EXPORT="$DIST/export"
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$DIST"

command -v xcodegen >/dev/null 2>&1 && xcodegen generate

xcodebuild archive \
  -project ClaudeManager.xcodeproj \
  -scheme ClaudeManager \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination 'generic/platform=macOS' \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

cat > "$DIST/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${DEVELOPMENT_TEAM}</string>
  <key>signingStyle</key><string>manual</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$DIST/ExportOptions.plist" \
  -exportPath "$EXPORT"

echo "✓ Exported: $EXPORT/Claude Manager.app"
codesign --verify --strict --verbose=2 "$EXPORT/Claude Manager.app"
