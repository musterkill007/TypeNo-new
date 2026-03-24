#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/dist/TypeNo.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$ROOT_DIR/dist"

swift build -c release --package-path "$ROOT_DIR"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/TypeNo" "$MACOS_DIR/TypeNo"
cp "$ROOT_DIR/App/Info.plist" "$CONTENTS_DIR/Info.plist"

if [ -f "$ROOT_DIR/App/TypeNo.icns" ]; then
    cp "$ROOT_DIR/App/TypeNo.icns" "$RESOURCES_DIR/TypeNo.icns"
fi

chmod +x "$MACOS_DIR/TypeNo"

echo "Built $APP_DIR"
