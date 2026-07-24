#!/bin/bash
#
# dist.sh — package SessionPet.app into a distributable zip.
#
# Run package.sh first (or this calls it for you). Produces
# SessionPet-<version>.zip in this directory, ready to attach to a GitHub
# Release or hand to someone directly.
#
# ditto (not zip/Finder-compress) is required here — it's the only tool
# that reliably preserves the ad-hoc code signature and resource fork
# inside the .app bundle when zipping on macOS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

./package.sh

APP_BUNDLE="$SCRIPT_DIR/SessionPet.app"
VERSION=$(defaults read "$APP_BUNDLE/Contents/Info.plist" CFBundleShortVersionString)
ZIP_PATH="$SCRIPT_DIR/SessionPet-$VERSION.zip"

echo "==> Zipping $APP_BUNDLE..."
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "==> Done: $ZIP_PATH"
echo "    This build is ad-hoc signed, not notarized — recipients will see"
echo "    a Gatekeeper warning on first launch. See README.md for the"
echo "    right-click-Open workaround."
