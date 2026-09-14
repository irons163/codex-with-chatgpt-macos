#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
TARGET_ARCH="${TARGET_ARCH:-}"
ARCH_LABEL="${ARCH_LABEL:-}"
RELEASE_VERSION="${RELEASE_VERSION:-}"
BUILD_VERSION="${BUILD_VERSION:-}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SPARKLE_SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-}"
SPARKLE_ED_PRIVATE_KEY="${SPARKLE_ED_PRIVATE_KEY:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
DIST_DIR="${DIST_DIR:-$PROJECT_ROOT/dist}"
WORK_DIR="${WORK_DIR:-$PROJECT_ROOT/build/release-${TARGET_ARCH:-unknown}}"

fail() { echo "build-release-dmg: $*" >&2; exit 1; }
require() { [[ -n "${2//[[:space:]]/}" ]] || fail "$1 is required."; }

require TARGET_ARCH "$TARGET_ARCH"
require ARCH_LABEL "$ARCH_LABEL"
require RELEASE_VERSION "$RELEASE_VERSION"
require BUILD_VERSION "$BUILD_VERSION"
require CODE_SIGN_IDENTITY "$CODE_SIGN_IDENTITY"
require NOTARY_PROFILE "$NOTARY_PROFILE"
require SPARKLE_SIGN_UPDATE "$SPARKLE_SIGN_UPDATE"
require SPARKLE_ED_PRIVATE_KEY "$SPARKLE_ED_PRIVATE_KEY"
require SPARKLE_PUBLIC_ED_KEY "$SPARKLE_PUBLIC_ED_KEY"
[[ "$TARGET_ARCH" == "arm64" || "$TARGET_ARCH" == "x86_64" ]] \
  || fail "TARGET_ARCH must be arm64 or x86_64."
[[ "$BUILD_VERSION" =~ ^[0-9]+$ ]] || fail "BUILD_VERSION must be an unsigned integer."
[[ -x "$SPARKLE_SIGN_UPDATE" ]] || fail "SPARKLE_SIGN_UPDATE is not executable."
case "$WORK_DIR" in
  "$PROJECT_ROOT"/build/release-*) ;;
  *) fail "WORK_DIR must be under $PROJECT_ROOT/build/release-." ;;
esac

SAFE_VERSION="$(printf '%s' "$RELEASE_VERSION" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
require SAFE_VERSION "$SAFE_VERSION"
APP_NAME="CodexWithChatGPT"
DISPLAY_NAME="Codex with ChatGPT"
DMG_NAME="${APP_NAME}-${SAFE_VERSION}-${ARCH_LABEL}.dmg"
DSYM_NAME="${APP_NAME}-${SAFE_VERSION}-${ARCH_LABEL}.dSYM.zip"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$DIST_DIR"

echo "==> Packaging signed app for $TARGET_ARCH"
CONFIGURATION=release \
ARCHS="$TARGET_ARCH" \
RELEASE_VERSION="$RELEASE_VERSION" \
BUILD_VERSION="$BUILD_VERSION" \
CODESIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  "$PROJECT_ROOT/scripts/package-app.sh"

APP_PATH="$WORK_DIR/${APP_NAME}.app"
ditto "$PROJECT_ROOT/dist/${APP_NAME}.app" "$APP_PATH"
rm -rf "$PROJECT_ROOT/dist/${APP_NAME}.app"
APP_BINARY="$APP_PATH/Contents/MacOS/$APP_NAME"
CLI_BINARY="$APP_PATH/Contents/Helpers/c2c"
BUILT_ARCHS="$(lipo -archs "$APP_BINARY")"
CLI_ARCHS="$(lipo -archs "$CLI_BINARY")"
[[ "$BUILT_ARCHS" == "$TARGET_ARCH" ]] \
  || fail "App architecture is $BUILT_ARCHS, expected $TARGET_ARCH."
[[ "$CLI_ARCHS" == "$TARGET_ARCH" ]] \
  || fail "CLI architecture is $CLI_ARCHS, expected $TARGET_ARCH."

echo "==> Generating dSYM"
DSYM_PATH="$WORK_DIR/${APP_NAME}.app.dSYM"
DSYM_ZIP="$WORK_DIR/$DSYM_NAME"
dsymutil "$APP_BINARY" -o "$DSYM_PATH"
ditto -c -k --sequesterRsrc --keepParent "$DSYM_PATH" "$DSYM_ZIP"

echo "==> Creating signed DMG"
STAGING_DIR="$WORK_DIR/dmg-staging"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"
DMG_PATH="$WORK_DIR/$DMG_NAME"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
codesign --force --timestamp --sign "$CODE_SIGN_IDENTITY" "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"

echo "==> Notarizing and stapling DMG"
NOTARY_JSON="$WORK_DIR/notary-result.json"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json \
  | tee "$NOTARY_JSON"
python3 - "$NOTARY_JSON" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    status = json.load(handle).get("status")
if status != "Accepted":
    raise SystemExit(f"Notarization failed with status: {status or 'unknown'}")
PY
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

echo "==> Signing final DMG bytes for Sparkle"
ED_SIGNATURE="$(
  printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" \
    | "$SPARKLE_SIGN_UPDATE" --ed-key-file - -p "$DMG_PATH" \
    | tail -n 1 \
    | tr -d '[:space:]'
)"
printf '%s' "$ED_SIGNATURE" | grep -Eq '^[A-Za-z0-9+/]{86}==$' \
  || fail "sign_update did not return a valid Ed25519 signature."

swift - "$SPARKLE_PUBLIC_ED_KEY" "$ED_SIGNATURE" "$DMG_PATH" <<'SWIFT'
import CryptoKit
import Foundation
let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 3,
      let publicKeyData = Data(base64Encoded: args[0]),
      let signatureData = Data(base64Encoded: args[1]) else { exit(1) }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
let archive = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)
guard key.isValidSignature(signatureData, for: archive) else {
    fputs("Sparkle private and public keys do not match.\n", stderr)
    exit(1)
}
SWIFT

ditto "$DMG_PATH" "$DIST_DIR/$DMG_NAME"
ditto "$DSYM_ZIP" "$DIST_DIR/$DSYM_NAME"
printf '%s\n' "$ED_SIGNATURE" > "$DIST_DIR/$DMG_NAME.edSignature"
ls -la "$DIST_DIR/$DMG_NAME" "$DIST_DIR/$DSYM_NAME" "$DIST_DIR/$DMG_NAME.edSignature"
