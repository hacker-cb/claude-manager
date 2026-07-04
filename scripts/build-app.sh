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

# Sparkle's public key must be set before shipping — a Developer ID + notarized build
# carrying the placeholder can never auto-update (Sparkle rejects every signed update),
# and the key is baked in for good. Generate the keypair once (docs/RELEASING.md), paste
# the public key into project.yml (SUPublicEDKey), and store the private key as a CI
# secret. Fail here rather than ship an app that silently can't update.
GOT_EDKEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
case "$GOT_EDKEY" in
"" | REPLACE_WITH_SUPUBLICEDKEY)
  echo "✗ SUPublicEDKey is unset/placeholder — set it in project.yml before a signed build (docs/RELEASING.md § Auto-update)" >&2
  exit 1
  ;;
esac

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

# --- Sparkle (auto-update) verification ------------------------------------------
# Sparkle.framework embeds nested Mach-O helpers (Autoupdate, Updater.app, the XPC
# services) that must EACH be Developer-ID-signed by us with Hardened Runtime, or
# notarization rejects the whole bundle with opaque per-file errors. The embed phase
# (Sign-on-Copy, generated by XcodeGen) does this at archive time; this gate turns a
# silent notarization rejection into a fast, legible CI failure. We only VERIFY here —
# never re-sign with --deep (Apple deprecates it; it causes the errors it appears to
# fix). If a component below fails, ensure the framework is embedded "Sign on Copy".
FW="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$FW" ] || { echo "✗ Sparkle.framework not embedded at $FW — auto-update would be dead" >&2; exit 1; }

# Whole-bundle deep verification is safe as a read-only check (the --deep ban is about
# *signing*, not verifying) and catches any unsigned nested code Gatekeeper would reject.
codesign --verify --strict --deep --verbose=2 "$APP"

# Each nested component must carry OUR team id (not the Sparkle project's) AND the
# runtime flag. Resolve the versioned dir via the Current symlink (Sparkle 2 uses
# Versions/B, but don't hard-code a letter that a future release could bump) and fail
# loudly if it can't be resolved. A component the framework version doesn't ship is
# skipped, not failed.
FW_VERSION_DIR="$(cd "$FW/Versions/Current" && pwd -P)" || {
  echo "✗ cannot resolve $FW/Versions/Current — unexpected Sparkle.framework layout" >&2
  exit 1
}
for rel in "Sparkle" "Autoupdate" "Updater.app" "XPCServices/Installer.xpc" "XPCServices/Downloader.xpc"; do
  COMP="$FW_VERSION_DIR/$rel"
  [ -e "$COMP" ] || continue
  COMP_SIG="$(codesign -d --verbose=4 "$COMP" 2>&1)"
  grep -q "flags=.*runtime" <<<"$COMP_SIG" || {
    echo "✗ Sparkle component missing Hardened Runtime: $rel" >&2
    exit 1
  }
  grep -q "TeamIdentifier=$DEVELOPMENT_TEAM" <<<"$COMP_SIG" || {
    echo "✗ Sparkle component not signed by our team ($DEVELOPMENT_TEAM): $rel — must be re-signed (Sign on Copy)" >&2
    exit 1
  }
done

# The updater must also be universal so Intel users get a working updater, not an
# arch-mismatched one — same rationale as the main-binary check above.
FW_ARCHS="$(lipo -archs "$FW_VERSION_DIR/Sparkle")"
for arch in arm64 x86_64; do
  grep -qw "$arch" <<<"$FW_ARCHS" || {
    echo "✗ Sparkle.framework missing '$arch' slice (got: $FW_ARCHS)" >&2
    exit 1
  }
done
echo "✓ Sparkle verified: embedded, nested helpers signed ($DEVELOPMENT_TEAM) + hardened, universal ($FW_ARCHS)"
