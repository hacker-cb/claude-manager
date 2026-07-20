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

# Reports `<missing>` for an absent key rather than letting PlistBuddy's non-zero exit
# abort the run under `set -e` — a missing key is a real regression (someone dropped the
# URL type), and it should surface as a legible "expected X, got <missing>" line instead
# of an opaque failure.
plist_value() { # <app> <plist path expression>
  /usr/libexec/PlistBuddy -c "Print $2" "$1/Contents/Info.plist" 2>/dev/null || echo '<missing>'
}

# Whether a bundle declares `scheme` ANYWHERE in CFBundleURLTypes. Deliberately mirrors
# `BundleIdentity.declaresURLScheme` (Sources/ClaudeManagerCore/Support/BundleIdentity.swift)
# exactly — every entry, every scheme within it, case-insensitive, skipping malformed
# entries — because that runtime predicate is what actually decides whether the build
# brokers, and a guard with weaker semantics would pass while the invariant is broken.
#
# Reading only a fixed index (`:CFBundleURLTypes:0:CFBundleURLSchemes:0`) is exactly that
# trap: a `claude` entry added at any other position would make the dev build an eligible
# LaunchServices handler while this script still printed a green tick.
declares_scheme() { # <app> <scheme> → exit 0 if declared
  python3 - "$1/Contents/Info.plist" "$2" <<'PY'
import plistlib, sys

plist_path, wanted = sys.argv[1], sys.argv[2].lower()
try:
    with open(plist_path, "rb") as handle:
        info = plistlib.load(handle)
except Exception:
    sys.exit(2)
types = info.get("CFBundleURLTypes")
if not isinstance(types, list):
    sys.exit(1)
for entry in types:
    if not isinstance(entry, dict):
        continue
    schemes = entry.get("CFBundleURLSchemes")
    if not isinstance(schemes, list):
        continue
    if any(isinstance(s, str) and s.lower() == wanted for s in schemes):
        sys.exit(0)
sys.exit(1)
PY
}

# `declares_scheme` exits 2 when the plist can't be read at all, which must never be
# conflated with a clean "does not declare" (1) — otherwise an unreadable Info.plist would
# print a green tick on the negative check, i.e. the guard attesting isolation it never
# verified. Both wrappers treat 2 as a hard failure.
check_declares() { # <label> <app> <scheme>
  local status=0
  declares_scheme "$2" "$3" || status=$?
  case "$status" in
    0) echo "  ✓ $1 declares '$3'" ;;
    1) echo "  ✗ $1 does NOT declare '$3'"; fail=1 ;;
    *) echo "  ✗ $1: could not read Info.plist — '$3' unverifiable"; fail=1 ;;
  esac
}

check_not_declares() { # <label> <app> <scheme>
  local status=0
  declares_scheme "$2" "$3" || status=$?
  case "$status" in
    0) echo "  ✗ $1 declares '$3' — it can take the handler from the release"; fail=1 ;;
    1) echo "  ✓ $1 does not declare '$3'" ;;
    *) echo "  ✗ $1: could not read Info.plist — '$3' unverifiable"; fail=1 ;;
  esac
}

check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ✓ $1 = $3"
  else
    echo "  ✗ $1: expected '$2', got '$3'"
    fail=1
  fi
}

# Preflight both inputs before asserting anything. A bundle that exists but whose
# Info.plist is missing or unreadable would otherwise surface downstream as a confusing
# "does NOT declare …" line, blaming the identity split for what is really a broken or
# mis-pathed build product.
for app in "$RELEASE_APP" "$DEBUG_APP"; do
  [ -d "$app" ] || { echo "✗ missing build product: $app" >&2; exit 1; }
  [ -r "$app/Contents/Info.plist" ] || {
    echo "✗ missing or unreadable Info.plist: $app/Contents/Info.plist" >&2
    exit 1
  }
done

echo "Release identity ($RELEASE_APP):"
release_id="$(plist_value "$RELEASE_APP" ':CFBundleIdentifier')"
check "CFBundleIdentifier" "$RELEASE_BUNDLE_ID" "$release_id"
check_declares "release build" "$RELEASE_APP" "$RELEASE_SCHEME"

echo "Dev identity ($DEBUG_APP):"
debug_id="$(plist_value "$DEBUG_APP" ':CFBundleIdentifier')"
check "CFBundleIdentifier" "$DEBUG_BUNDLE_ID" "$debug_id"
check_declares "dev build" "$DEBUG_APP" "$DEBUG_SCHEME"

# The assertions above pin each identity; these state the *relationship*, which is the
# property that actually matters and the one that fails if the constants above are ever
# edited to converge. The scheme half scans the whole CFBundleURLTypes set (see
# `declares_scheme`) so a `claude` entry at any position is caught.
echo "Separation:"
if [ "$release_id" = "$debug_id" ]; then
  echo "  ✗ dev and release share bundle id '$release_id' — macOS cannot tell them apart"
  fail=1
else
  echo "  ✓ bundle ids differ"
fi
check_not_declares "the dev build" "$DEBUG_APP" "$RELEASE_SCHEME"

[ "$fail" -eq 0 ] || { echo "✗ build identities are not isolated" >&2; exit 1; }
echo "✓ dev and release identities are isolated"
