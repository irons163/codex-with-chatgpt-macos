#!/usr/bin/env bash
set -euo pipefail

EXPECTED_REPOSITORY_SLUG="irons163/codex-with-chatgpt-macos"
OUTPUT_DIR="${OUTPUT_DIR:-dist/appcasts}"
OUTPUT_BASENAME="${OUTPUT_BASENAME:-appcast}"
APP_NAME="${APP_NAME:-Codex with ChatGPT}"
REPOSITORY_SLUG="${REPOSITORY_SLUG:-$EXPECTED_REPOSITORY_SLUG}"
RELEASE_TAG="${RELEASE_TAG:-}"
RELEASE_NAME="${RELEASE_NAME:-}"
RELEASE_NOTES="${RELEASE_NOTES:-}"
BUILD_VERSION="${BUILD_VERSION:-}"
PUBLISHED_AT="${PUBLISHED_AT:-}"
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-13.0}"
CHANNEL_LABEL="${CHANNEL_LABEL:-stable}"
ARM64_URL="${ARM64_URL:-}"
ARM64_SIZE="${ARM64_SIZE:-}"
ARM64_ED_SIGNATURE="${ARM64_ED_SIGNATURE:-}"
X86_64_URL="${X86_64_URL:-}"
X86_64_SIZE="${X86_64_SIZE:-}"
X86_64_ED_SIGNATURE="${X86_64_ED_SIGNATURE:-}"

fail() { echo "generate-sparkle-appcast: $*" >&2; exit 1; }
require() { [[ -n "${2//[[:space:]]/}" ]] || fail "$1 is required."; }

require RELEASE_TAG "$RELEASE_TAG"
require BUILD_VERSION "$BUILD_VERSION"
require ARM64_URL "$ARM64_URL"
require ARM64_SIZE "$ARM64_SIZE"
require ARM64_ED_SIGNATURE "$ARM64_ED_SIGNATURE"
require X86_64_URL "$X86_64_URL"
require X86_64_SIZE "$X86_64_SIZE"
require X86_64_ED_SIGNATURE "$X86_64_ED_SIGNATURE"
[[ "$REPOSITORY_SLUG" == "$EXPECTED_REPOSITORY_SLUG" ]] \
  || fail "REPOSITORY_SLUG must be $EXPECTED_REPOSITORY_SLUG."
[[ "$BUILD_VERSION" =~ ^[0-9]+$ ]] || fail "BUILD_VERSION must be an unsigned integer."
[[ "$ARM64_SIZE" =~ ^[0-9]+$ && "$X86_64_SIZE" =~ ^[0-9]+$ ]] \
  || fail "DMG sizes must be unsigned integers."
for url in "$ARM64_URL" "$X86_64_URL"; do
  [[ "$url" == https://github.com/irons163/codex-with-chatgpt-macos/releases/download/* ]] \
    || fail "Installer URL must be an HTTPS release asset from $EXPECTED_REPOSITORY_SLUG."
done
for signature in "$ARM64_ED_SIGNATURE" "$X86_64_ED_SIGNATURE"; do
  printf '%s' "$signature" | tr -d '[:space:]' | grep -Eq '^[A-Za-z0-9+/]{86}==$' \
    || fail "Every enclosure requires a valid Ed25519 signature."
done

SHORT_VERSION="${RELEASE_TAG#refs/tags/}"
SHORT_VERSION="${SHORT_VERSION#v}"
SHORT_VERSION="${SHORT_VERSION#V}"
require SHORT_VERSION "$SHORT_VERSION"
if [[ -z "${RELEASE_NAME//[[:space:]]/}" ]]; then
  RELEASE_NAME="$APP_NAME $SHORT_VERSION"
fi

mkdir -p "$OUTPUT_DIR"
python3 - \
  "$OUTPUT_DIR" "$OUTPUT_BASENAME" "$APP_NAME" "$REPOSITORY_SLUG" \
  "$RELEASE_NAME" "$RELEASE_NOTES" "$BUILD_VERSION" "$SHORT_VERSION" \
  "$PUBLISHED_AT" "$MINIMUM_SYSTEM_VERSION" "$CHANNEL_LABEL" \
  "$ARM64_URL" "$ARM64_SIZE" "$ARM64_ED_SIGNATURE" \
  "$X86_64_URL" "$X86_64_SIZE" "$X86_64_ED_SIGNATURE" <<'PY'
from __future__ import annotations

from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

(
    output_dir, basename, app_name, repository, release_name, release_notes,
    build, short_version, published_at, minimum_system, channel,
    arm_url, arm_size, arm_signature, intel_url, intel_size, intel_signature,
) = sys.argv[1:]

sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
dc = "http://purl.org/dc/elements/1.1/"
ET.register_namespace("sparkle", sparkle)
ET.register_namespace("dc", dc)

try:
    published = datetime.fromisoformat(published_at.replace("Z", "+00:00"))
except ValueError:
    published = datetime.now(timezone.utc)
if published.tzinfo is None:
    published = published.replace(tzinfo=timezone.utc)

notes = " ".join(release_notes.replace("\r", "").split())
if not notes:
    notes = "Bug fixes and improvements."

def write_feed(architecture: str, url: str, size: str, signature: str) -> None:
    rss = ET.Element("rss", {"version": "2.0"})
    channel_node = ET.SubElement(rss, "channel")
    ET.SubElement(channel_node, "title").text = f"{app_name} Updates ({channel}, {architecture})"
    ET.SubElement(channel_node, "link").text = f"https://github.com/{repository}/releases"
    ET.SubElement(channel_node, "description").text = f"{channel} updates for {architecture}"
    ET.SubElement(channel_node, "language").text = "en"
    item = ET.SubElement(channel_node, "item")
    ET.SubElement(item, "title").text = release_name
    ET.SubElement(item, "pubDate").text = format_datetime(published.astimezone(timezone.utc))
    description = ET.SubElement(item, "description", {f"{{{sparkle}}}format": "plain-text"})
    description.text = notes
    ET.SubElement(item, f"{{{sparkle}}}minimumSystemVersion").text = minimum_system
    ET.SubElement(item, "enclosure", {
        "url": url,
        f"{{{sparkle}}}version": build,
        f"{{{sparkle}}}shortVersionString": short_version,
        f"{{{sparkle}}}edSignature": signature.strip(),
        "type": "application/x-apple-diskimage",
        "length": size,
    })
    tree = ET.ElementTree(rss)
    ET.indent(tree, space="  ")
    target = Path(output_dir) / f"{basename}-{architecture}.xml"
    tree.write(target, encoding="utf-8", xml_declaration=True)

write_feed("arm64", arm_url, arm_size, arm_signature)
write_feed("x86_64", intel_url, intel_size, intel_signature)
PY

echo "Generated signed Sparkle appcasts:"
ls -la "$OUTPUT_DIR/$OUTPUT_BASENAME-arm64.xml" "$OUTPUT_DIR/$OUTPUT_BASENAME-x86_64.xml"
