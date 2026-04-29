#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/TypeNo.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ENTITLEMENTS="$ROOT_DIR/App/TypeNo.entitlements"
ZIP_PATH="$DIST_DIR/TypeNo.app.zip"
DMG_PATH="$DIST_DIR/TypeNo.dmg"
BUILD_MODE="${TYPENO_BUILD_MODE:-universal}"
ALLOW_NATIVE_FALLBACK="${TYPENO_ALLOW_NATIVE_FALLBACK:-0}"
NOTARIZE_APP=0

find_codesign_identity() {
    if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
        printf '%s\n' "$CODE_SIGN_IDENTITY"
        return 0
    fi

    local identities preferred
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

    preferred="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"
    if [ -n "$preferred" ]; then
        printf '%s\n' "$preferred"
        return 0
    fi

    preferred="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)"
    if [ -n "$preferred" ]; then
        printf '%s\n' "$preferred"
    fi
}

build_native() {
    echo "==> Building TypeNo for the current Mac architecture..."
    swift build -c release --package-path "$ROOT_DIR" || return 1
    BINARY_PATH="$ROOT_DIR/.build/release/TypeNo"
}

build_universal() {
    echo "==> Building TypeNo universal binary (arm64 + x86_64)..."
    swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT_DIR" || return 1
    BINARY_PATH="$ROOT_DIR/.build/apple/Products/Release/TypeNo"
}

mkdir -p "$DIST_DIR"
rm -rf "$APP_DIR" "$ZIP_PATH" "$DMG_PATH"

BINARY_PATH=""
if [ "$BUILD_MODE" = "native" ]; then
    build_native
else
    if ! build_universal; then
        if [ "$ALLOW_NATIVE_FALLBACK" = "1" ]; then
            echo "Universal build failed; falling back to native build because TYPENO_ALLOW_NATIVE_FALLBACK=1."
            build_native
        else
            echo "Universal build failed. Set TYPENO_ALLOW_NATIVE_FALLBACK=1 for local native packaging." >&2
            exit 1
        fi
    fi
fi

if [ ! -x "$BINARY_PATH" ]; then
    echo "Built binary not found at $BINARY_PATH" >&2
    exit 1
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY_PATH" "$MACOS_DIR/TypeNo"
cp "$ROOT_DIR/App/Info.plist" "$CONTENTS_DIR/Info.plist"

if [ -f "$ROOT_DIR/App/TypeNo.icns" ]; then
    cp "$ROOT_DIR/App/TypeNo.icns" "$RESOURCES_DIR/TypeNo.icns"
fi

chmod +x "$MACOS_DIR/TypeNo"

if command -v lipo >/dev/null 2>&1; then
    echo "==> Binary architectures:"
    lipo -info "$MACOS_DIR/TypeNo" || true
fi

CODE_SIGN_NAME="$(find_codesign_identity)"
if [ -n "$CODE_SIGN_NAME" ]; then
    echo "==> Signing app with: $CODE_SIGN_NAME"
    codesign --force --sign "$CODE_SIGN_NAME" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        --timestamp \
        "$APP_DIR"
else
    echo "==> No Developer ID signing identity found; using ad-hoc signature."
    codesign --force --sign - --timestamp=none "$APP_DIR"
fi

codesign --verify --deep --strict "$APP_DIR"

if [ -n "$CODE_SIGN_NAME" ] \
    && [ -n "${APPLE_ID:-}" ] \
    && [ -n "${APPLE_TEAM_ID:-}" ] \
    && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]; then
    NOTARIZE_APP=1
fi

if [ "$NOTARIZE_APP" = "1" ]; then
    echo "==> Notarizing app bundle before packaging..."
    NOTARY_ZIP_PATH="$DIST_DIR/TypeNo-notary.zip"
    rm -f "$NOTARY_ZIP_PATH"
    ditto -c -k --keepParent "$APP_DIR" "$NOTARY_ZIP_PATH"
    xcrun notarytool submit "$NOTARY_ZIP_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait
    xcrun stapler staple "$APP_DIR"
    rm -f "$NOTARY_ZIP_PATH"
else
    echo "==> Skipping notarization; Apple notarization environment variables are not fully configured."
fi

echo "==> Creating zip: $ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo "==> Creating dmg: $DMG_PATH"
DMG_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/typeno-dmg.XXXXXX")"
cleanup() {
    rm -rf "$DMG_STAGING_DIR"
}
trap cleanup EXIT

cp -R "$APP_DIR" "$DMG_STAGING_DIR/TypeNo.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create \
    -volname "TypeNo" \
    -srcfolder "$DMG_STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

if [ -n "$CODE_SIGN_NAME" ]; then
    echo "==> Signing dmg with: $CODE_SIGN_NAME"
    codesign --force --sign "$CODE_SIGN_NAME" --timestamp "$DMG_PATH"
fi

if [ "$NOTARIZE_APP" = "1" ]; then
    echo "==> Notarizing dmg..."
    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait
    xcrun stapler staple "$DMG_PATH"
fi

echo "==> Release packages:"
ls -lh "$ZIP_PATH" "$DMG_PATH"
