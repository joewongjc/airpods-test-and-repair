#!/bin/bash
set -e

APP_NAME="AirPods Fix"
BUNDLE_DIR="$APP_NAME.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_CACHE_DIR="$SCRIPT_DIR/.build/ModuleCache.noindex"

echo "Building $APP_NAME..."

# Clean previous build
rm -rf "$SCRIPT_DIR/$BUNDLE_DIR"

# Create .app bundle structure
mkdir -p "$SCRIPT_DIR/$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$SCRIPT_DIR/$BUNDLE_DIR/Contents/Resources"
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

echo ""
echo "Build complete: $BUNDLE_DIR"
echo "Run with: open \"$SCRIPT_DIR/$BUNDLE_DIR\""
