#!/usr/bin/env bash
# Prepend a release entry to the Sparkle appcast, preserving history.
#
# The appcast is CUMULATIVE — it must keep every past <item> so users on old builds
# still see an upgrade path. Each release job only knows its own build, so we read the
# existing feed (checked out from gh-pages), prepend the new <item> between the
# ITEMS markers, and re-emit. Sparkle compares on <sparkle:version> (= CFBundleVersion),
# so we also assert the new build number is strictly greater than every published one —
# a regression (e.g. re-dispatching an old tag) would otherwise silently offer no update.
#
# Env:
#   ENCLOSURE_URL      public https URL of the update archive (the .zip on the Release) [required]
#   VERSION            marketing version → sparkle:shortVersionString                   [required]
#   BUILD_NUMBER       CFBundleVersion → sparkle:version (must increase every release)  [required]
#   ED_SIGNATURE       base64 EdDSA signature from sign_update                          [required]
#   LENGTH             enclosure size in bytes from sign_update                         [required]
#   MIN_SYS_VERSION    sparkle:minimumSystemVersion                        [default: 14.0]
#   RELEASE_NOTES_URL  link shown as the release-notes / more-info URL     [optional]
#   APPCAST_PATH       path to the appcast file to update in place         [default: appcast.xml]
set -euo pipefail

: "${ENCLOSURE_URL:?set ENCLOSURE_URL}"
: "${VERSION:?set VERSION}"
: "${BUILD_NUMBER:?set BUILD_NUMBER}"
: "${ED_SIGNATURE:?set ED_SIGNATURE}"
: "${LENGTH:?set LENGTH}"
MIN_SYS_VERSION="${MIN_SYS_VERSION:-14.0}"
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:-}"
APPCAST_PATH="${APPCAST_PATH:-appcast.xml}"

FEED_URL="https://hacker-cb.github.io/claude-manager/appcast.xml"

# Preserve existing items and enforce monotonic build numbers.
EXISTING_ITEMS=""
if [ -f "$APPCAST_PATH" ]; then
  EXISTING_ITEMS="$(awk '/<!-- ITEMS:START -->/{f=1;next} /<!-- ITEMS:END -->/{f=0} f' "$APPCAST_PATH")"
  MAX_EXISTING="$(grep -oE '<sparkle:version>[0-9]+</sparkle:version>' "$APPCAST_PATH" \
    | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
  if [ -n "${MAX_EXISTING:-}" ] && [ "$BUILD_NUMBER" -le "$MAX_EXISTING" ]; then
    echo "✗ build $BUILD_NUMBER is not greater than the latest published build $MAX_EXISTING —" >&2
    echo "  Sparkle compares on this and would offer no update. Refusing to publish a regression." >&2
    exit 1
  fi
fi

# RFC 822 pubDate (BSD date on the macOS runner).
PUB_DATE="$(date "+%a, %d %b %Y %H:%M:%S %z")"

NOTES_LINE=""
if [ -n "$RELEASE_NOTES_URL" ]; then
  NOTES_LINE="      <sparkle:releaseNotesLink>${RELEASE_NOTES_URL}</sparkle:releaseNotesLink>
"
fi

NEW_ITEM="    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_SYS_VERSION}</sparkle:minimumSystemVersion>
${NOTES_LINE}      <enclosure url=\"${ENCLOSURE_URL}\" sparkle:edSignature=\"${ED_SIGNATURE}\" length=\"${LENGTH}\" type=\"application/octet-stream\"/>
    </item>"

# Newest item first, then the accumulated history.
{
  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Claude Manager</title>
    <link>${FEED_URL}</link>
    <description>Auto-update feed for Claude Manager.</description>
    <language>en</language>
    <!-- ITEMS:START -->
XML
  printf '%s\n' "$NEW_ITEM"
  [ -n "$EXISTING_ITEMS" ] && printf '%s\n' "$EXISTING_ITEMS"
  cat <<'XML'
    <!-- ITEMS:END -->
  </channel>
</rss>
XML
} >"${APPCAST_PATH}.tmp"
mv "${APPCAST_PATH}.tmp" "$APPCAST_PATH"

echo "✓ Appcast updated: $APPCAST_PATH (v$VERSION, build $BUILD_NUMBER)"
