#!/usr/bin/env bash
# Assert that the local dev build and the shipping build keep SEPARATE macOS identities.
#
# The whole dev/release isolation (docs/DEVELOPMENT.md § Dev builds carry a separate
# identity) rests on one invariant: a Debug build must never carry the released app's
# bundle id, nor declare its `claude://` scheme. macOS keys LaunchServices, the Login
# Items database, TCC and the UserDefaults domain on the bundle id, so a regression here
# silently re-creates the hijack the split exists to prevent — the release's login item
# resolving onto a working copy in `build/`, or a dev build taking the `claude://`
# handler and stranding it on a deleted path after `make clean`.
#
# Nothing else in CI would catch that: the identities live in per-config build settings
# (project.yml `settings.configs`), not in code, so the test suite can't see them. This
# script reads the values off the two *built* Info.plists — after Xcode's `$(VAR)`
# substitution — so it verifies what actually ships, not what the YAML intends.
#
# Usage: build both configurations into a shared derived-data path, then run this:
#   xcodebuild build … -configuration Release -derivedDataPath build
#   xcodebuild build … -configuration Debug   -derivedDataPath build
#   bash scripts/assert-build-identities.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RELEASE_APP="${RELEASE_APP:-build/Build/Products/Release/Claude Manager.app}"
DEBUG_APP="${DEBUG_APP:-build/Build/Products/Debug/Claude Manager.app}"

# The shipping identity. These are the values a released, notarized build carries; the
# dev identity must differ in both the bundle id and the URL scheme.
RELEASE_BUNDLE_ID="io.github.hacker-cb.claude-manager"
RELEASE_SCHEME="claude"
DEBUG_BUNDLE_ID="io.github.hacker-cb.claude-manager.dev"
DEBUG_SCHEME="claude-cmdev"

fail=0

plist_value() { # <app> <plist path expression>
  /usr/libexec/PlistBuddy -c "Print $2" "$1/Contents/Info.plist" 2>/dev/null
}

check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ✓ $1 = $3"
  else
    echo "  ✗ $1: expected '$2', got '$3'"
    fail=1
  fi
}

for app in "$RELEASE_APP" "$DEBUG_APP"; do
  [ -d "$app" ] || { echo "✗ missing build product: $app" >&2; exit 1; }
done

echo "Release identity ($RELEASE_APP):"
release_id="$(plist_value "$RELEASE_APP" ':CFBundleIdentifier')"
release_scheme="$(plist_value "$RELEASE_APP" ':CFBundleURLTypes:0:CFBundleURLSchemes:0')"
check "CFBundleIdentifier" "$RELEASE_BUNDLE_ID" "$release_id"
check "claude:// scheme" "$RELEASE_SCHEME" "$release_scheme"

echo "Dev identity ($DEBUG_APP):"
debug_id="$(plist_value "$DEBUG_APP" ':CFBundleIdentifier')"
debug_scheme="$(plist_value "$DEBUG_APP" ':CFBundleURLTypes:0:CFBundleURLSchemes:0')"
check "CFBundleIdentifier" "$DEBUG_BUNDLE_ID" "$debug_id"
check "private scheme" "$DEBUG_SCHEME" "$debug_scheme"

# The two assertions above already pin each identity, but state the *relationship* too:
# it is the property that actually matters, and it fails loudly if both constants are
# ever edited to the same value.
echo "Separation:"
if [ "$release_id" = "$debug_id" ]; then
  echo "  ✗ dev and release share bundle id '$release_id' — macOS cannot tell them apart"
  fail=1
else
  echo "  ✓ bundle ids differ"
fi
if [ "$debug_scheme" = "$RELEASE_SCHEME" ]; then
  echo "  ✗ the dev build declares '$RELEASE_SCHEME' — it can take the handler from the release"
  fail=1
else
  echo "  ✓ the dev build does not declare '$RELEASE_SCHEME'"
fi

[ "$fail" -eq 0 ] || { echo "✗ build identities are not isolated" >&2; exit 1; }
echo "✓ dev and release identities are isolated"
