#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AppMoverNative"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_DIR/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Packaging/AppIcon-1024.png" "$RESOURCES_DIR/AppIcon.png"

TMP_ICON_PNG="$(mktemp /tmp/appmover-icon.XXXXXX.png)"
TMP_ICON_RSRC="$(mktemp /tmp/appmover-icon.XXXXXX.rsrc)"
cp "$ROOT_DIR/Packaging/AppIcon-1024.png" "$TMP_ICON_PNG"
sips -i "$TMP_ICON_PNG" >/dev/null
DeRez -only icns "$TMP_ICON_PNG" > "$TMP_ICON_RSRC"
Rez -append "$TMP_ICON_RSRC" -o "$APP_DIR/Icon"$'\r' >/dev/null
SetFile -a C "$APP_DIR" >/dev/null
rm -f "$TMP_ICON_PNG" "$TMP_ICON_RSRC"

# Use ad-hoc signing so the bundle can launch locally without a paid certificate.
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Created $APP_DIR"
