#!/bin/bash
#
# package.sh — build Session Pet into a real, distributable SessionPet.app
#
# WHAT THIS DOES:
#   1. Builds the SPM executable in release mode (`swift build -c release`).
#   2. Assembles a proper macOS .app bundle at ./SessionPet.app:
#        SessionPet.app/Contents/MacOS/SessionPet   (the compiled binary)
#        SessionPet.app/Contents/Info.plist         (bundle metadata, incl. LSUIElement)
#        SessionPet.app/Contents/Resources/         (empty, reserved for icons/assets)
#   3. Ad-hoc code-signs the bundle so Gatekeeper/quarantine doesn't block
#      double-click launches (no Apple Developer account needed for this —
#      it's a local, unnotarized signature, fine for running on your own Mac).
#
# HOW TO USE:
#   cd app/
#   ./package.sh
#   open SessionPet.app                 # launch it directly
#   # or: drag SessionPet.app into /Applications, then launch from there /
#   #     Spotlight, and optionally enable "Open at Login" in System Settings
#   #     > General > Login Items (or via the in-app login-item toggle, once
#   #     LoginItem.swift is wired up — see Sources/SessionPet/LoginItem.swift).
#
# Re-run this script any time you change source and want a fresh .app —
# it always rebuilds and re-assembles the bundle from scratch.

set -euo pipefail

APP_NAME="SessionPet"
BUNDLE_ID="com.abhay.sessionpet"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Building $APP_NAME (release)..."
swift build -c release

BIN_PATH=".build/release/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "error: expected binary not found at $BIN_PATH" >&2
    exit 1
fi

APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "==> Assembling $APP_NAME.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

if [ -f "$SCRIPT_DIR/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Session Pet</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "==> Ad-hoc code-signing bundle..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Installing to /Applications..."
INSTALLED="/Applications/$APP_NAME.app"
rm -rf "$INSTALLED"
cp -R "$APP_BUNDLE" "$INSTALLED"

echo "==> Done. Installed: $INSTALLED"
echo "    Open it from Spotlight/Finder like any other app, or: open \"$INSTALLED\""
