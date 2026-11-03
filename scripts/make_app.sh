#!/bin/bash
# Build Fetchly.app (run on a Mac with Xcode 15+ / Swift 5.9+; macOS 26 "Tahoe" SDK gets the Liquid Glass look automatically)
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Fetchly --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Fetchly"
APP="build/Fetchly.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Fetchly"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Fetchly</string>
  <key>CFBundleDisplayName</key><string>Fetchly</string>
  <key>CFBundleIdentifier</key><string>com.example.fetchly</string>
  <key>CFBundleExecutable</key><string>Fetchly</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true   # ad-hoc sign so Gatekeeper lets you open it locally
echo "Built $APP  ->  open $APP"
