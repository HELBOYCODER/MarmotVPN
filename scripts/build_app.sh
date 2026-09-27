#!/bin/bash
# MarmotVPN build — compiles the Swift app and assembles MarmotVPN.app
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/MarmotVPN.app"
BOTTLES_SRC="${BOTTLES_SRC:-$ROOT/../research}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/scripts" "$APP/Contents/Resources/bottles"

echo "==> compiling swift"
xcrun swiftc -O -module-cache-path build/mc -o "$APP/Contents/MacOS/MarmotVPN" \
  -target arm64-apple-macosx13.0 \
  -framework AppKit -framework Vision -framework ServiceManagement \
  Sources/MarmotVPN/main.swift 2>&1 | tee /tmp/marmot_build.log
[ -x "$APP/Contents/MacOS/MarmotVPN" ] || { echo "BUILD_FAIL"; exit 1; }

echo "==> bundling runtime bottles"
for f in lzo lz4 pkcs11-helper openssl@3 ca-certificates openvpn; do
  cp "$BOTTLES_SRC/$f.tar.gz" "$APP/Contents/Resources/bottles/$f.tar.gz"
done

echo "==> bundling scripts"
cp scripts/setup_runtime.sh "$APP/Contents/Resources/scripts/setup_runtime.sh"
chmod +x "$APP/Contents/Resources/scripts/setup_runtime.sh"

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MarmotVPN</string>
  <key>CFBundleDisplayName</key><string>MarmotVPN</string>
  <key>CFBundleIdentifier</key><string>com.helboycoder.marmotvpn</string>
  <key>CFBundleVersion</key><string>1.0.0</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>MarmotVPN</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT — MarmotVPN contributors</string>
</dict>
</plist>
PLIST
echo "APPL????" > "$APP/Contents/PkgInfo"

if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> ad-hoc codesign"
codesign --force --deep -s - "$APP"

echo "BUILD_OK $APP"
