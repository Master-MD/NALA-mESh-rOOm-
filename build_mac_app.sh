#!/usr/bin/env bash

set -euo pipefail

APP_NAME="NALA 3D Studio"
APP_BUNDLE="build/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Building App Bundle for $APP_NAME..."

# 1. Clean and Create directories
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 2. Copy Info.plist
cp src_app/Info.plist "$CONTENTS_DIR/"

# 3. Compile Swift Code
echo "Compiling Swift code via swiftc..."
# We explicitly link ApplicationServices to avoid some SwiftUI linker issues
swiftc -parse-as-library src_app/main.swift -o "$MACOS_DIR/$APP_NAME" -framework SwiftUI -framework RealityKit -framework AppKit

# 4. Strip binary to save space
strip "$MACOS_DIR/$APP_NAME"

# 4.5 Generate App Icon (if available)
ICON_SRC="assets/nala_meshroom_icon.jpg"
if [[ -f "$ICON_SRC" ]]; then
    echo "Synthesizing AppIcon.icns from $ICON_SRC..."
    mkdir -p build/MyIcon.iconset
    sips -s format png "$ICON_SRC" --out build/icon_master.png > /dev/null
    sips -z 16 16     build/icon_master.png --out build/MyIcon.iconset/icon_16x16.png > /dev/null
    sips -z 32 32     build/icon_master.png --out build/MyIcon.iconset/icon_16x16@2x.png > /dev/null
    sips -z 32 32     build/icon_master.png --out build/MyIcon.iconset/icon_32x32.png > /dev/null
    sips -z 64 64     build/icon_master.png --out build/MyIcon.iconset/icon_32x32@2x.png > /dev/null
    sips -z 128 128   build/icon_master.png --out build/MyIcon.iconset/icon_128x128.png > /dev/null
    sips -z 256 256   build/icon_master.png --out build/MyIcon.iconset/icon_128x128@2x.png > /dev/null
    sips -z 256 256   build/icon_master.png --out build/MyIcon.iconset/icon_256x256.png > /dev/null
    sips -z 512 512   build/icon_master.png --out build/MyIcon.iconset/icon_256x256@2x.png > /dev/null
    sips -z 512 512   build/icon_master.png --out build/MyIcon.iconset/icon_512x512.png > /dev/null
    sips -z 1024 1024 build/icon_master.png --out build/MyIcon.iconset/icon_512x512@2x.png > /dev/null
    iconutil -c icns build/MyIcon.iconset -o "$RESOURCES_DIR/AppIcon.icns"
    rm -R build/MyIcon.iconset build/icon_master.png
fi

echo "App Bundle created at $APP_BUNDLE"

# 5. Create DMG (Optional, but requested)
DMG_NAME="build/NALA_3D_Studio_v1.dmg"
echo "Packaging into DMG..."
rm -f "$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG_NAME"

echo "✅ Success! DMG created at $DMG_NAME"
