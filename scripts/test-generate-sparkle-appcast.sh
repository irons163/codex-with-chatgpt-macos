#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
SIGNATURE="$(python3 -c 'import base64; print(base64.b64encode(b"x" * 64).decode())')"

generate() {
  local repository="${REPOSITORY_OVERRIDE:-irons163/codex-with-chatgpt-macos}"
  local arm_signature="${ARM64_SIGNATURE_OVERRIDE-$SIGNATURE}"
  OUTPUT_DIR="$TEMP/output" \
  REPOSITORY_SLUG="$repository" \
  RELEASE_TAG="v1.2.3-beta.1" \
  RELEASE_NAME='Codex & ChatGPT <Beta>' \
  RELEASE_NOTES='Fixes <unsafe> & improves updates.' \
  BUILD_VERSION=42 \
  PUBLISHED_AT='2026-09-15T00:00:00Z' \
  MINIMUM_SYSTEM_VERSION=13.0 \
  CHANNEL_LABEL=beta \
  ARM64_URL='https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v1.2.3-beta.1/CodexWithChatGPT-arm64.dmg' \
  ARM64_SIZE=123 \
  ARM64_ED_SIGNATURE="$arm_signature" \
  X86_64_URL='https://github.com/irons163/codex-with-chatgpt-macos/releases/download/v1.2.3-beta.1/CodexWithChatGPT-intel.dmg' \
  X86_64_SIZE=456 \
  X86_64_ED_SIGNATURE="$SIGNATURE" \
    "$ROOT/scripts/generate-sparkle-appcast.sh"
}

generate >/dev/null
python3 - "$TEMP/output" "$SIGNATURE" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
for architecture, size in (("arm64", "123"), ("x86_64", "456")):
    path = Path(sys.argv[1]) / f"appcast-{architecture}.xml"
    root = ET.parse(path).getroot()
    enclosure = root.find(".//enclosure")
    assert enclosure is not None
    assert enclosure.get(f"{{{sparkle}}}version") == "42"
    assert enclosure.get(f"{{{sparkle}}}shortVersionString") == "1.2.3-beta.1"
    assert enclosure.get(f"{{{sparkle}}}edSignature") == sys.argv[2]
    assert enclosure.get("length") == size
    assert root.findtext(".//item/description") == "Fixes <unsafe> & improves updates."
PY

if REPOSITORY_OVERRIDE='example/wrong' generate >/dev/null 2>&1; then
  echo "Generator accepted a different repository." >&2
  exit 1
fi
if ARM64_SIGNATURE_OVERRIDE='' generate >/dev/null 2>&1; then
  echo "Generator accepted a missing signature." >&2
  exit 1
fi
printf '%s\n' "Sparkle appcast generator tests passed."
