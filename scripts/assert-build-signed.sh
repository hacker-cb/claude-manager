#!/usr/bin/env bash
# Assert that both built .apps carry a valid BUNDLE seal — the signature macOS checks
# before it will execute the app at all.
#
# Current macOS refuses to *run* an unsigned bundle. AppleSystemPolicy lets it check in
# with LaunchServices and appear in the Dock, then kills it (`Security policy would not
# allow process` in `log show`), which reads as the app stalling for ~20s and only coming
# up on a retry. Same macOS fact the launcher bundles hit (docs/ARCHITECTURE.md § macOS
# facts baked into the code), one level up: applied to Claude Manager's own build product.
# The regression that caused it was a single flag — `CODE_SIGNING_ALLOWED=NO` on an
# xcodebuild command line, silently overriding the `CODE_SIGN_IDENTITY: "-"` project.yml
# declares.
#
# Nothing else would catch it coming back. The seal is a property of the built product,
# not of any Swift source, so `swift test` cannot see it: an unsigned build compiles,
# links and passes the whole suite, and is broken only at launch, on a real machine.
#
# WHY `codesign --verify --strict` AND NOT `codesign -dv`: `-dv` reports the *Mach-O
# executable*, which the arm64 linker ad-hoc signs by itself. An unsealed bundle therefore
# prints a confident `Signature=adhoc` — the same line a correctly sealed bundle prints —
# and exits 0. Only the bundle seal is what macOS assesses, and only `--verify --strict`
# reports it. `-dv` is used below purely to *name* what was found; it never decides pass
# or fail.
#
# Deliberately identity-agnostic: it asserts a seal EXISTS and VALIDATES, not who signed
# it. For the same reason it is not `spctl --assess`, which assesses *notarization* — an
# ad-hoc signature never has any, so spctl reports `rejected` for a perfectly runnable
# build. The Developer ID export is gated separately, and more deeply, inside
# scripts/build-app.sh.
#
# Usage: build both configurations into the shared derived-data path, then run this:
#   make build-app CONFIG=Release
#   make build-app CONFIG=Debug
#   bash scripts/assert-build-signed.sh
# CI's use is the reason both are built. Running the Release line locally now produces a
# *runnable* bundle under the shipped identity in build/, so follow with `make clean` when
# done — see docs/DEVELOPMENT.md § Dev builds carry a separate identity for why a stray
# Release-identity build can hijack the installed app's login item and claude:// handler.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RELEASE_APP="${RELEASE_APP:-build/Build/Products/Release/Claude Manager.app}"
DEBUG_APP="${DEBUG_APP:-build/Build/Products/Debug/Claude Manager.app}"

fail=0

# The literal artifact of the regression: no signing step ran, so no seal was written.
# Kept separate from the `codesign --verify` check below so the two failure modes stay
# legible — "never sealed" (here) points at the build's signing flags, "sealed but broken"
# (there) points at something writing into the bundle after signing. The app draws the same
# two-error distinction one level down, for launchers, though it keys each on a different
# signal: Doctor reports "unsigned" off the wrapper version (`launcher.isUnrunnable`, below
# `CoreConstants.minimumRunnableWrapperVersion`) and "signature is broken" off
# `CodeSigner.isValidlySigned` (see Doctor.swift).
check_has_seal() { # <label> <app>
  if [ -f "$2/Contents/_CodeSignature/CodeResources" ]; then
    echo "  ✓ $1 has a bundle seal (Contents/_CodeSignature/CodeResources)"
  else
    echo "  ✗ $1 has NO bundle seal — Contents/_CodeSignature is missing"
    echo "    macOS will not execute it; check the build's signing flags"
    fail=1
  fi
}

# The check macOS itself performs. `--strict` refuses the loopholes lenient validation
# lets through; `--deep` extends it to nested code — here the embedded Sparkle.framework
# and its helpers, sealed by the Sign-on-Copy embed phase. Without `--deep` a bundle whose
# framework lost its own signature still verifies clean, because the framework's *bytes*
# are sealed as a resource while its signature is never looked at. Verifying deep is safe:
# Apple's `--deep` caveat is about *signing*, not verifying — scripts/build-app.sh relies
# on the same distinction.
check_verifies() { # <label> <app>
  local output status=0
  output="$(codesign --verify --strict --deep --verbose=2 "$2" 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    echo "  ✓ $1 verifies (codesign --verify --strict --deep)"
  else
    echo "  ✗ $1 fails codesign --verify --strict --deep:"
    while IFS= read -r line; do echo "      $line"; done <<<"$output"
    fail=1
  fi
}

# Report-only, and reached ONLY for a bundle that already passed both checks above (see
# assert_sealed). That precondition is load-bearing: a "sealed but broken" bundle — the
# post-signing-write regression — still reports `Signature=adhoc` under `codesign -dv`, so
# printing "signed ad-hoc — expected for a dev or CI build" beneath its ✗ would annotate the
# exact failure this guard exists to catch as normal. Because the bundle passed, only the
# ad-hoc and Developer ID branches are live; the first two are defensive and unreachable
# here. Its job is to make the CI log say WHICH valid signature was found.
report_signature_kind() { # <label> <app>
  local info status=0
  info="$(codesign -dv "$2" 2>&1)" || status=$?  # -dv: the diagnostic the header names
  if [ "$status" -ne 0 ]; then
    echo "    (codesign reports no signature at all)"
  elif grep -q 'linker-signed' <<<"$info"; then
    echo "    (that is the LINKER's ad-hoc signature on the executable, not a bundle seal)"
  elif grep -q '^Authority=' <<<"$info"; then
    echo "    signed by $(grep -m1 '^Authority=' <<<"$info" | cut -d= -f2-)"
  elif grep -q '^Signature=adhoc' <<<"$info"; then
    echo "    signed ad-hoc (no identity — expected for a dev or CI build)"
  fi
}

assert_sealed() { # <label> <app>
  echo "$1 ($2):"
  local before="$fail"
  check_has_seal "$1" "$2"
  check_verifies "$1" "$2"
  # Name the signature kind only when both checks passed. On a failure check_verifies has
  # already printed codesign's real output, and the reassuring "signed ad-hoc" line would
  # mislabel the regression (see report_signature_kind).
  [ "$fail" = "$before" ] && report_signature_kind "$1" "$2"
}

# Preflight both inputs first. `codesign` exits 1 for "no such file" exactly as it does
# for "invalid signature", so without this a mis-pathed build product would be reported as
# an unsigned app — a guard blaming the signing step for a typo.
for app in "$RELEASE_APP" "$DEBUG_APP"; do
  [ -d "$app" ] || { echo "✗ missing build product: $app" >&2; exit 1; }
done

assert_sealed "Release build" "$RELEASE_APP"
assert_sealed "Debug build" "$DEBUG_APP"

[ "$fail" -eq 0 ] || { echo "✗ a built app is not validly signed — macOS would refuse to run it" >&2; exit 1; }
echo "✓ both built apps carry a valid bundle seal"
