#!/bin/bash
set -euo pipefail

APP_NAME="AirPods Fix"
BUNDLE_DIR="$APP_NAME.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_CACHE_DIR="$SCRIPT_DIR/.build/ModuleCache.noindex"
APP_VERSION="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SCRIPT_DIR/Resources/Info.plist")}"

echo "Building $APP_NAME..."

# Clean previous build
rm -rf "$SCRIPT_DIR/$BUNDLE_DIR"

# Create .app bundle structure
mkdir -p "$SCRIPT_DIR/$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$SCRIPT_DIR/$BUNDLE_DIR/Contents/Resources"
mkdir -p "$SCRIPT_DIR/$BUNDLE_DIR/Contents/Resources/bin"
mkdir -p "$MODULE_CACHE_DIR"

# Compile Swift source
swiftc \
    -O \
    -whole-module-optimization \
    -module-cache-path "$MODULE_CACHE_DIR" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework AVFoundation \
    -framework CoreAudio \
    -o "$SCRIPT_DIR/$BUNDLE_DIR/Contents/MacOS/airpods-fix-gui" \
    "$SCRIPT_DIR/Sources/AirPodsFixApp.swift"

# Create launcher script
cat > "$SCRIPT_DIR/$BUNDLE_DIR/Contents/MacOS/airpods-fix" << 'LAUNCHER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/airpods-fix-gui"
LAUNCHER
chmod +x "$SCRIPT_DIR/$BUNDLE_DIR/Contents/MacOS/airpods-fix"

# Copy resources
cp "$SCRIPT_DIR/Resources/Info.plist" "$SCRIPT_DIR/$BUNDLE_DIR/Contents/Info.plist"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$SCRIPT_DIR/$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$SCRIPT_DIR/$BUNDLE_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$SCRIPT_DIR/$BUNDLE_DIR/Contents/Info.plist"

if BLUEUTIL_PATH="$(command -v blueutil 2>/dev/null)"; then
    cp -L "$BLUEUTIL_PATH" "$SCRIPT_DIR/$BUNDLE_DIR/Contents/Resources/bin/blueutil"
    chmod +x "$SCRIPT_DIR/$BUNDLE_DIR/Contents/Resources/bin/blueutil"
    echo "Bundled blueutil from: $BLUEUTIL_PATH"
else
    echo "Warning: blueutil not found. The packaged app will still run,"
    echo "but Bluetooth reconnect features will require blueutil on the target Mac."
fi

echo ""
echo "Build complete: $BUNDLE_DIR"
echo "Version: $APP_VERSION"
echo "Run with: open \"$SCRIPT_DIR/$BUNDLE_DIR\""
