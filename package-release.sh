#!/bin/bash
set -euo pipefail

APP_NAME="AirPods Fix"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
DMG_ROOT="$DIST_DIR/dmg-root"
APP_PATH="$SCRIPT_DIR/$APP_NAME.app"
APP_VERSION="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SCRIPT_DIR/Resources/Info.plist")}"
DMG_PATH="$DIST_DIR/AirPods-Fix-${APP_VERSION}.dmg"

APPLE_SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
ENABLE_NOTARIZATION="${ENABLE_NOTARIZATION:-0}"
APPLE_NOTARY_KEY_PATH="${APPLE_NOTARY_KEY_PATH:-}"
APPLE_NOTARY_KEY_ID="${APPLE_NOTARY_KEY_ID:-}"
APPLE_NOTARY_ISSUER_ID="${APPLE_NOTARY_ISSUER_ID:-}"

sign_path() {
    local target="$1"
    local options=()

    if [[ -z "$APPLE_SIGNING_IDENTITY" ]]; then
        return 0
    fi

    if [[ "$target" == *.app ]]; then
        options=(--options runtime)
    fi

    codesign \
        --force \
        --timestamp \
        "${options[@]}" \
        --sign "$APPLE_SIGNING_IDENTITY" \
        "$target"
}

verify_signature() {
    local target="$1"
    [[ -n "$APPLE_SIGNING_IDENTITY" ]] || return 0
    codesign --verify --deep --strict --verbose=2 "$target"
}

notarize_dmg() {
    [[ "$ENABLE_NOTARIZATION" == "1" ]] || return 0

    if [[ -z "$APPLE_NOTARY_KEY_PATH" || -z "$APPLE_NOTARY_KEY_ID" || -z "$APPLE_NOTARY_ISSUER_ID" ]]; then
        echo "Notarization requested but notary credentials are incomplete." >&2
        exit 1
    fi

    xcrun notarytool submit \
        "$DMG_PATH" \
        --key "$APPLE_NOTARY_KEY_PATH" \
        --key-id "$APPLE_NOTARY_KEY_ID" \
        --issuer "$APPLE_NOTARY_ISSUER_ID" \
        --wait

    xcrun stapler staple "$DMG_PATH"
}

"$SCRIPT_DIR/build.sh"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
mkdir -p "$DMG_ROOT"

if [[ -n "$APPLE_SIGNING_IDENTITY" ]]; then
    if [[ -f "$APP_PATH/Contents/Resources/bin/blueutil" ]]; then
        sign_path "$APP_PATH/Contents/Resources/bin/blueutil"
    fi
    sign_path "$APP_PATH/Contents/MacOS/airpods-fix-gui"
    sign_path "$APP_PATH/Contents/MacOS/airpods-fix"
    sign_path "$APP_PATH"
    verify_signature "$APP_PATH"
    echo "Signed app with identity: $APPLE_SIGNING_IDENTITY"
else
    echo "Warning: no signing identity configured. The release artifact will be unsigned."
fi

cp -R "$APP_PATH" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$DMG_ROOT"

if [[ -n "$APPLE_SIGNING_IDENTITY" ]]; then
    sign_path "$DMG_PATH"
fi

notarize_dmg

echo ""
echo "Release package created:"
echo "$DMG_PATH"
