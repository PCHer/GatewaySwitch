#!/bin/bash
set -euo pipefail

APP_NAME="GatewaySwitch"
VERSION="v1.0"
REPO="PCHer/GatewaySwitch"
URL="https://github.com/$REPO/releases/download/$VERSION/$APP_NAME-1.0.zip"

echo "Downloading $APP_NAME $VERSION..."
cd /tmp
rm -f "$APP_NAME-1.0.zip"
curl -fsSL#O "$URL"

echo "Extracting..."
unzip -oq "$APP_NAME-1.0.zip"

echo "Removing quarantine attributes..."
xattr -dr com.apple.quarantine "$APP_NAME.app"

echo "Installing to /Applications..."
rm -rf "/Applications/$APP_NAME.app"
mv "$APP_NAME.app" /Applications/

echo "Done! Run $APP_NAME from /Applications."
