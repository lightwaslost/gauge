#!/usr/bin/env bash
# Builds a release Gauge.app into ./build, ad-hoc signed. Pass --dmg to also make a disk image.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Gauge.app
VERSION=${VERSION:-0.1.0}

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Gauge "$APP/Contents/MacOS/Gauge"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Gauge</string>
    <key>CFBundleDisplayName</key><string>Gauge</string>
    <key>CFBundleIdentifier</key><string>app.gauge.mac</string>
    <key>CFBundleExecutable</key><string>Gauge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--dmg" ]]; then
    STAGE=build/dmg
    rm -rf "$STAGE" build/Gauge.dmg
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname Gauge -srcfolder "$STAGE" -ov -format UDZO build/Gauge.dmg >/dev/null
    rm -rf "$STAGE"
    echo "Built build/Gauge.dmg"
fi
