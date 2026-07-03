#!/usr/bin/env bash
# Archive + export a Developer ID-signed Claude Manager.app into dist/export/.
#
# Env:
#   DEVELOPMENT_TEAM   Apple Team ID (10 chars)               [required]
#   SIGNING_IDENTITY   e.g. "Developer ID Application: … (TEAMID)"  [required]
#   VERSION            marketing version (CFBundleShortVersionString) [default: 0.0.0]
#   BUILD_NUMBER       build number (CFBundleVersion)                 [default: 1]
#
# Version SSoT is the git tag: CI passes VERSION (from the v* tag) and BUILD_NUMBER
# (from the run number). Locally they default to 0.0.0/1 — this script always signs
# (Developer ID), so those are just the version stamped on a local/dev archive.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM}"
: "${SIGNING_IDENTITY:?set SIGNING_IDENTITY}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

DIST="$ROOT/dist"
ARCHIVE="$DIST/ClaudeManager.xcarchive"
EXPORT="$DIST/export"
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$DIST"

command -v xcodegen >/dev/null 2>&1 && xcodegen generate

# ARCHS/ONLY_ACTIVE_ARCH: force a universal (arm64 + x86_64) build explicitly rather
# than trusting ARCHS_STANDARD — this app exists to fix an arch/Rosetta bug, so an
# accidental arm64-only build shipped to Intel users would be a self-inflicted wound.
# MARKETING_VERSION/CURRENT_PROJECT_VERSION override the project.yml placeholders so
# the signed, notarized bundle carries the release version — not the dev default.
# --options runtime asserts Hardened Runtime at signing time (notarization requires it).
xcodebuild archive \
  -project ClaudeManager.xcodeproj \
  -scheme ClaudeManager \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime"

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

APP="$EXPORT/Claude Manager.app"
echo "✓ Exported: $APP"

# Structural signature check (the deep Gatekeeper assessment happens in notarize.sh
# via `spctl --assess` once the app is stapled).
codesign --verify --strict --verbose=2 "$APP"

# The exported bundle must carry the version we injected — guards against xcodebuild
# ignoring the override or exportArchive re-stamping the plist, which would silently
# ship a mislabelled (tag says X, bundle says Y) notarized artifact.
GOT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$GOT_VERSION" = "$VERSION" ] || {
  echo "✗ version mismatch: bundle reports '$GOT_VERSION', expected '$VERSION'" >&2
  exit 1
}

# Hardened Runtime must actually be on the signature (notarization hard-requires it).
# Capture then match via a here-string, not a pipe — avoids the pipefail+SIGPIPE trap
# where `grep -q` closing the pipe early could surface as a spurious pipeline failure.
SIG_INFO="$(codesign -d --verbose=4 "$APP" 2>&1)"
grep -q 'flags=.*runtime' <<<"$SIG_INFO" || {
  echo "✗ Hardened Runtime flag missing on exported app" >&2
  exit 1
}

# Universal binary: both slices must be present (this app exists to fix an arch bug).
BIN="$APP/Contents/MacOS/Claude Manager"
ARCHS_OUT="$(lipo -archs "$BIN")"
for arch in arm64 x86_64; do
  grep -qw "$arch" <<<"$ARCHS_OUT" || {
    echo "✗ missing '$arch' slice in $BIN (got: $ARCHS_OUT)" >&2
    exit 1
  }
done
echo "✓ Verified: v$VERSION (build $BUILD_NUMBER), hardened runtime, universal ($ARCHS_OUT)"
