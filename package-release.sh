#!/bin/bash
set -euo pipefail

APP_NAME="AirPods Fix"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
DMG_ROOT="$DIST_DIR/dmg-root"
DMG_PATH="$DIST_DIR/${APP_NAME}-macOS.dmg"

"$SCRIPT_DIR/build.sh"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
mkdir -p "$DMG_ROOT"

cp -R "$SCRIPT_DIR/$APP_NAME.app" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$DMG_ROOT"

echo ""
echo "Release package created:"
echo "$DMG_PATH"
