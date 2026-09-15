#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
CONFIGURATION="$(printf '%s' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"
ARCHS="${ARCHS:-}"
RELEASE_VERSION="${RELEASE_VERSION:-}"
BUILD_VERSION="${BUILD_VERSION:-}"
APP_PATH="$PROJECT_ROOT/dist/CodexWithChatGPT.app"
STAGING_PATH="$PROJECT_ROOT/dist/.CodexWithChatGPT.app.staging"
INFO_PLIST_PATH="$STAGING_PATH/Contents/Info.plist"
APP_ICON_PATH="$STAGING_PATH/Contents/Resources/AppIcon.icns"
APP_BINARY_PATH="$STAGING_PATH/Contents/MacOS/CodexWithChatGPT"
CLI_PATH="$STAGING_PATH/Contents/Helpers/c2c"
SPARKLE_FRAMEWORK_PATH="$STAGING_PATH/Contents/Frameworks/Sparkle.framework"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

case "$CONFIGURATION" in
  debug|release) ;;
  *)
    echo "Unsupported CONFIGURATION: $CONFIGURATION (expected debug or release)." >&2
    exit 1
    ;;
esac

SWIFT_BUILD_ARGS=(-c "$CONFIGURATION")
NORMALIZED_ARCHS="${ARCHS//,/ }"
for arch in $NORMALIZED_ARCHS; do
  case "$arch" in
    arm64|x86_64) SWIFT_BUILD_ARGS+=(--arch "$arch") ;;
    *)
      echo "Unsupported ARCHS entry: $arch (expected arm64 or x86_64)." >&2
      exit 1
      ;;
  esac
done

if [[ -n "$RELEASE_VERSION" ]] \
    && [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  echo "Invalid RELEASE_VERSION: $RELEASE_VERSION" >&2
  exit 1
fi
if [[ -n "$BUILD_VERSION" && ! "$BUILD_VERSION" =~ ^[0-9]+$ ]]; then
  echo "BUILD_VERSION must be an unsigned integer." >&2
  exit 1
fi

cd "$PROJECT_ROOT"
swift build "${SWIFT_BUILD_ARGS[@]}" --product CodexWithChatGPT
swift build "${SWIFT_BUILD_ARGS[@]}" --product c2c
BUILD_PATH="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
APP_BINARY_SOURCE="$BUILD_PATH/CodexWithChatGPT"
CLI_SOURCE="$BUILD_PATH/c2c"
SPARKLE_FRAMEWORK_SOURCE="$BUILD_PATH/Sparkle.framework"

for required in \
  "$APP_BINARY_SOURCE" \
  "$CLI_SOURCE" \
  "$SPARKLE_FRAMEWORK_SOURCE" \
  "$PROJECT_ROOT/Packaging/Info.plist" \
  "$PROJECT_ROOT/Packaging/AppIcon.icns"; do
  if [[ ! -e "$required" ]]; then
    echo "Required build product is missing: $required" >&2
    exit 1
  fi
done

rm -rf "$STAGING_PATH"
mkdir -p \
  "$STAGING_PATH/Contents/MacOS" \
  "$STAGING_PATH/Contents/Helpers" \
  "$STAGING_PATH/Contents/Resources" \
  "$STAGING_PATH/Contents/Frameworks"

ditto "$APP_BINARY_SOURCE" "$APP_BINARY_PATH"
ditto "$CLI_SOURCE" "$CLI_PATH"
ditto "$PROJECT_ROOT/Packaging/Info.plist" "$INFO_PLIST_PATH"
ditto "$PROJECT_ROOT/Packaging/AppIcon.icns" "$APP_ICON_PATH"
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$SPARKLE_FRAMEWORK_PATH"
chmod 755 "$APP_BINARY_PATH" "$CLI_PATH"

if [[ -n "$RELEASE_VERSION" ]]; then
  "$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$INFO_PLIST_PATH"
fi
if [[ -n "$BUILD_VERSION" ]]; then
  "$PLIST_BUDDY" -c "Set :CFBundleVersion $BUILD_VERSION" "$INFO_PLIST_PATH"
fi

RPATHS="$(
  otool -l "$APP_BINARY_PATH" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  '
)"
if ! grep -Fqx "@executable_path/../Frameworks" <<<"$RPATHS"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY_PATH"
fi
if ! otool -L "$APP_BINARY_PATH" \
    | grep -Fq "@rpath/Sparkle.framework/Versions/B/Sparkle"; then
  echo "Packaged executable is not linked to Sparkle.framework." >&2
  exit 1
fi

SIGNING_IDENTITY="${CODESIGN_IDENTITY:--}"
IS_DISTRIBUTION_BUILD=false
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  IS_DISTRIBUTION_BUILD=true
fi

delete_plist_key() {
  "$PLIST_BUDDY" -c "Delete :$1" "$INFO_PLIST_PATH" >/dev/null 2>&1 || true
}

delete_plist_key "SUPublicEDKey"
delete_plist_key "SUAllowsInsecureUpdates"
if [[ "$IS_DISTRIBUTION_BUILD" == true ]]; then
  SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
  KEY_CHECK_PATH="$(mktemp)"
  trap 'rm -f "$KEY_CHECK_PATH"' EXIT
  if [[ -z "${SPARKLE_PUBLIC_ED_KEY//[[:space:]]/}" ]] \
      || ! printf '%s' "$SPARKLE_PUBLIC_ED_KEY" | base64 -D >"$KEY_CHECK_PATH" 2>/dev/null \
      || [[ "$(wc -c <"$KEY_CHECK_PATH" | tr -d '[:space:]')" != "32" ]]; then
    echo "SPARKLE_PUBLIC_ED_KEY must be a Base64-encoded 32-byte Ed25519 public key." >&2
    exit 1
  fi
  rm -f "$KEY_CHECK_PATH"
  trap - EXIT
  "$PLIST_BUDDY" -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$INFO_PLIST_PATH"
else
  # Local ad-hoc builds have no production update key. This key is removed and
  # insecure updates are prohibited for every Developer ID release build.
  "$PLIST_BUDDY" -c "Add :SUAllowsInsecureUpdates bool true" "$INFO_PLIST_PATH"
fi

sign_target() {
  local target="$1"
  local args=(--force --sign "$SIGNING_IDENTITY")
  if [[ "$IS_DISTRIBUTION_BUILD" == true ]]; then
    args+=(--timestamp --options runtime --preserve-metadata=identifier,entitlements,flags)
  else
    args+=(--preserve-metadata=identifier,entitlements)
  fi
  codesign "${args[@]}" "$target"
}

while IFS= read -r nested_binary; do
  [[ -n "$nested_binary" ]] && sign_target "$nested_binary"
done < <(
  find "$SPARKLE_FRAMEWORK_PATH/Versions" -type f -print0 \
    | while IFS= read -r -d '' candidate; do
        file "$candidate" | grep -Fq "Mach-O" && printf '%s\n' "$candidate"
      done \
    | awk '{ path=$0; depth=gsub("/", "/", path); print depth "\t" $0 }' \
    | sort -rn \
    | cut -f2-
)
while IFS= read -r nested_bundle; do
  [[ -n "$nested_bundle" ]] && sign_target "$nested_bundle"
done < <(
  find "$SPARKLE_FRAMEWORK_PATH/Versions" -type d \
    \( -name "*.xpc" -o -name "*.app" \) -print \
    | awk '{ path=$0; depth=gsub("/", "/", path); print depth "\t" $0 }' \
    | sort -rn \
    | cut -f2-
)

sign_target "$CLI_PATH"
sign_target "$SPARKLE_FRAMEWORK_PATH"
sign_target "$STAGING_PATH"
codesign --verify --deep --strict --verbose=2 "$STAGING_PATH"

if [[ "$IS_DISTRIBUTION_BUILD" == true ]]; then
  SIGNATURE_DETAILS="$(codesign -d --verbose=4 "$STAGING_PATH" 2>&1)"
  grep -Fq "Authority=Developer ID Application" <<<"$SIGNATURE_DETAILS" \
    || { echo "App is not signed with Developer ID Application." >&2; exit 1; }
  grep -Fq "Timestamp=" <<<"$SIGNATURE_DETAILS" \
    || { echo "Distribution signature has no secure timestamp." >&2; exit 1; }
  if "$PLIST_BUDDY" -c "Print :SUAllowsInsecureUpdates" "$INFO_PLIST_PATH" >/dev/null 2>&1; then
    echo "Distribution package must not allow insecure Sparkle updates." >&2
    exit 1
  fi
fi

"$CLI_PATH" --version >/dev/null
rm -rf "$APP_PATH"
mv "$STAGING_PATH" "$APP_PATH"
printf '%s\n' "$APP_PATH"
