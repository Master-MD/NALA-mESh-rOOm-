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

echo "App Bundle created at $APP_BUNDLE"

# 5. Create DMG (Optional, but requested)
DMG_NAME="build/NALA_3D_Studio_v1.dmg"
echo "Packaging into DMG..."
rm -f "$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG_NAME"

echo "✅ Success! DMG created at $DMG_NAME"
