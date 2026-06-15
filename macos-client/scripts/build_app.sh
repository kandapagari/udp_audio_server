#!/usr/bin/env bash
# Assemble a distributable UDPTTSMenuBar.app bundle from the SwiftPM build.
# Usage: macos-client/scripts/build_app.sh   (run from anywhere)
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"   # macos-client/
APP_NAME="UDPTTSMenuBar"
BUNDLE="$HERE/build/${APP_NAME}.app"

echo "› swift build -c release"
swift build -c release --package-path "$HERE"
BIN="$(swift build -c release --package-path "$HERE" --show-bin-path)/${APP_NAME}"

echo "› assembling ${BUNDLE}"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/${APP_NAME}"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>UDP TTS</string>
    <key>CFBundleDisplayName</key>     <string>UDP TTS</string>
    <key>CFBundleIdentifier</key>      <string>com.udptts.menubar</string>
    <key>CFBundleVersion</key>         <string>0.1.0</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <!-- Menu-bar agent: no Dock icon, no main window. -->
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper/launchd accept the local bundle.
echo "› codesign (ad-hoc)"
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || \
    echo "  (codesign skipped — bundle still runs locally)"

echo "✓ built $BUNDLE"
echo "  run:  open \"$BUNDLE\"     (look for the waveform icon in the menu bar)"
