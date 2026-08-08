#!/bin/bash
# Build Vibenotch.app from the SPM release binary. CLT-only (no xcodebuild).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Vibenotch.app"
swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Vibenotch "$APP/Contents/MacOS/Vibenotch"
# Localizations live in the SPM resource bundle; Bundle.module finds it under
# Contents/Resources, so without this copy the app is English-only.
cp -R .build/release/Vibenotch_Vibenotch.bundle "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Vibenotch</string>
  <key>CFBundleDisplayName</key><string>Vibenotch</string>
  <key>CFBundleIdentifier</key><string>com.rebelpaulo.vibenotch</string>
  <key>CFBundleVersion</key><string>0.2.0</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleExecutable</key><string>Vibenotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Vibenotch raises the terminal window of the agent session you click.</string>
</dict>
PLIST
# Stable ad-hoc signature keyed to the bundle identifier (keeps TCC grants sticky).
codesign --force --sign - --identifier com.rebelpaulo.vibenotch "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature"
echo "built: $APP"
