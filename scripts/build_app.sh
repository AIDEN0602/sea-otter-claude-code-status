#!/usr/bin/env bash
# Builds NotchOtter with SPM, then assembles and ad-hoc codesigns a proper
# .app bundle at dist/NotchOtter.app. Xcode is not required (CommandLineTools
# `swift build` only).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
DIST_DIR="$REPO_ROOT/dist"
APP_BUNDLE="$DIST_DIR/NotchOtter.app"
SPRITES_SRC="$REPO_ROOT/assets/sprites/A"
BUNDLE_ID="com.minje.notchotter"
BUILD_CONFIG="${1:-release}"

echo "==> Building NotchOtter ($BUILD_CONFIG configuration)"
(cd "$APP_DIR" && swift build -c "$BUILD_CONFIG")

BIN_PATH="$(cd "$APP_DIR" && swift build -c "$BUILD_CONFIG" --show-bin-path)/NotchOtter"

if [ ! -x "$BIN_PATH" ]; then
  echo "error: could not locate built NotchOtter binary at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/sprites"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/NotchOtter"
chmod +x "$APP_BUNDLE/Contents/MacOS/NotchOtter"

if [ -d "$SPRITES_SRC" ]; then
  cp -R "$SPRITES_SRC"/* "$APP_BUNDLE/Contents/Resources/sprites/"
else
  echo "error: sprite source directory not found: $SPRITES_SRC" >&2
  exit 1
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>NotchOtter</string>
    <key>CFBundleDisplayName</key>
    <string>NotchOtter</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>NotchOtter</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSUserNotificationUsageDescription</key>
    <string>NotchOtter shows a notification when a Claude Code session needs your approval, finishes, or hits repeated errors.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>NotchOtter uses AppleScript to focus the matching Ghostty terminal window when you click a session.</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc codesigning"
codesign -s - --force --deep "$APP_BUNDLE"

echo "==> Verifying signature"
codesign -v "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
