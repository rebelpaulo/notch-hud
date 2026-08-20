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
  <key>CFBundleVersion</key><string>1.0.1</string>
  <key>CFBundleShortVersionString</key><string>1.0.1</string>
  <key>CFBundleExecutable</key><string>Vibenotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Vibenotch raises agent terminal windows and opens Terminal when you choose to install an update.</string>
</dict>
</plist>
PLIST
# The closing </plist> above was missing until now: the app still launched (the
# real Info.plist is linked into the binary via -sectcreate) but plutil refused
# the bundle copy, and anything reading it through CFBundle — LaunchServices
# included — saw a malformed file. Fail the build rather than ship that again.
plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Sign with a stable identity when one exists, ad-hoc otherwise.
#
# This is not about trust — nobody is verifying us — it is about IDENTITY
# STAYING THE SAME between builds. An ad-hoc signature has no certificate, so
# the identity IS the hash of the binary: change one byte and macOS sees a
# different application. Every Keychain "Always Allow" and every Automation
# grant is recorded against that identity, so every rebuild silently orphans
# them and the prompts come back. Signing with a certificate makes the identity
# the certificate, and the grants survive.
#
# VIBENOTCH_SIGN_IDENTITY overrides; otherwise we look for a local self-signed
# "Vibenotch Signing" certificate. Not finding one is NORMAL and not an error:
# ad-hoc still produces a working app, and asking someone to create a root
# certificate just to try a menu-bar app would be a rude thing to require.
SIGN_IDENTITY="${VIBENOTCH_SIGN_IDENTITY:-}"
# `find-identity -p codesigning`, NOT `find-certificate`. A certificate is only
# half of an identity: the other half is the private key. find-certificate
# happily matches one whose key is missing — and then codesign FAILS outright
# instead of taking the ad-hoc path below, so a stray certificate in someone's
# keychain would break their build rather than leave them where they started.
# find-identity lists only real cert+key pairs.
#
# WITHOUT `-v`, deliberately. `-v` means "valid", and a self-signed certificate
# is never trusted by default — Keychain Access reports it as
# CSSMERR_TP_NOT_TRUSTED until someone marks it Always Trust. codesign does not
# care: it signs with an untrusted certificate perfectly well. Filtering on
# `-v` therefore skipped the one certificate this block exists to find, fell
# back to ad-hoc, and silently changed the app's identity — which is precisely
# what costs the user their Keychain grants on the next rebuild. Trust is a
# question for whoever VERIFIES a signature; we only need a stable one.
if [ -z "$SIGN_IDENTITY" ] \
  && security find-identity -p codesigning 2>/dev/null | grep -q '"Vibenotch Signing"'; then
  SIGN_IDENTITY="Vibenotch Signing"
fi
if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --identifier com.rebelpaulo.vibenotch "$APP"
  echo "signed with: $SIGN_IDENTITY (grants survive rebuilds)"
else
  codesign --force --sign - --identifier com.rebelpaulo.vibenotch "$APP"
  echo "signed ad-hoc — macOS will re-ask for Keychain/Automation access after each rebuild."
  echo "  To stop that: create a self-signed Code Signing certificate named 'Vibenotch Signing'"
  echo "  in Keychain Access (Certificate Assistant > Create a Certificate), then rebuild."
fi
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority|Signature"
echo "built: $APP"
