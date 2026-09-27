#!/bin/bash
# Build MarmotVPN-<version>.dmg — drag-to-Applications installer image
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(defaults read "$PWD/build/MarmotVPN.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 1.0.0)
DMG="build/MarmotVPN-v${VERSION}-mac.dmg"
STAGE="build/dmg_stage"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/MarmotVPN.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# pretty volume: icon + background + window layout via AppleScript-less DS_Store is optional;
# keep it minimal and reliable:
hdiutil create -volname "MarmotVPN ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

codesign --force -s - "$DMG" 2>/dev/null || true
echo "DMG_OK $DMG ($(du -h "$DMG" | cut -f1))"
