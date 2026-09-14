#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/feeds"

write_feed() {
  local file="$1" build="$2" version="$3" tag="$4"
  sed -e "s/__BUILD__/$build/g" -e "s/__VERSION__/$version/g" -e "s/__TAG__/$tag/g" \
    > "$file" <<'XML'
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure
url="https://github.com/irons163/codex-with-chatgpt-macos/releases/download/__TAG__/app.dmg"
sparkle:version="__BUILD__" sparkle:shortVersionString="__VERSION__" /></item></channel></rss>
XML
}

VALIDATOR=(python3 "$ROOT/scripts/validate-release-build-order.py")
"${VALIDATOR[@]}" --appcast-directory "$TEMP/feeds" --current-build 1 --current-version 0.1.1 --current-tag v0.1.1 >/dev/null
write_feed "$TEMP/feeds/appcast.xml" 1 0.1.1 v0.1.1
"${VALIDATOR[@]}" --appcast-directory "$TEMP/feeds" --current-build 2 --current-version 0.1.2 --current-tag v0.1.2 >/dev/null
"${VALIDATOR[@]}" --appcast-directory "$TEMP/feeds" --current-build 1 --current-version 0.1.1 --current-tag v0.1.1 >/dev/null
if "${VALIDATOR[@]}" --appcast-directory "$TEMP/feeds" --current-build 0 --current-version 0.1.0 --current-tag v0.1.0 >/dev/null 2>&1; then
  echo "Validator accepted a lower build." >&2
  exit 1
fi
if "${VALIDATOR[@]}" --appcast-directory "$TEMP/feeds" --current-build 1 --current-version 0.1.2 --current-tag v0.1.2 >/dev/null 2>&1; then
  echo "Validator accepted a reused build for another release." >&2
  exit 1
fi
printf '%s\n' "Release build-order validation tests passed."
