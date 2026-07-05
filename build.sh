#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="GatewaySwitch"
BUNDLE_ID="com.gatewayswitch.app"

echo "Building $APP_NAME..."
swift build -c release --package-path "$PROJECT_DIR"

BUILD_DIR="$PROJECT_DIR/.build/release"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

echo "Creating app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [ -f "$PROJECT_DIR/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null

echo "Done! App bundle created at: $APP_BUNDLE"
echo "Run it with: open \"$APP_BUNDLE\""
