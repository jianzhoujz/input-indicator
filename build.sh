#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VARIANT="${1:-doubao}"
APP_VERSION="${APP_VERSION:-${VERSION:-1.0.2}}"
APP_BUILD="${APP_BUILD:-$APP_VERSION}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-12.0}"

case "$VARIANT" in
  doubao)
    APP_NAME="DoubaoInputIndicator"
    DISPLAY_NAME="豆包输入法指示器"
    BUNDLE_ID="local.doubao-input-indicator"
    SWIFT_DEFINE=""
    ;;
  wetype|wechat)
    APP_NAME="WeTypeInputIndicator"
    DISPLAY_NAME="微信输入法指示器"
    BUNDLE_ID="local.wetype-input-indicator"
    SWIFT_DEFINE="WETYPE"
    ;;
  *)
    echo "Usage: $0 [doubao|wetype]" >&2
    exit 2
    ;;
esac

APP="$ROOT/build/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"
RESOURCES="$APP/Contents/Resources"
mkdir -p "$ROOT/build"
TMP_DIR="$(mktemp -d "$ROOT/build/$APP_NAME.XXXXXX")"
SLICE_BINS=()

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RESOURCES"

compile_slice() {
  local arch="$1"
  local output="$TMP_DIR/$APP_NAME-$arch"

  local args=(swiftc)
  if [[ -n "$SWIFT_DEFINE" ]]; then
    args+=(-D "$SWIFT_DEFINE")
  fi

  args+=(
    -target "$arch-apple-macosx$DEPLOYMENT_TARGET" \
    -O \
    -framework AppKit \
    -framework Carbon \
    -framework CoreGraphics \
    "$ROOT/Sources/DoubaoInputIndicator.swift" \
    -o "$output"
  )

  "${args[@]}"
  SLICE_BINS+=("$output")
}

compile_slice arm64
compile_slice x86_64
lipo -create "${SLICE_BINS[@]}" -output "$BIN"
chmod +x "$BIN"

ICONSET="$RESOURCES/AppIcon.iconset"
swift "$ROOT/tools/make_app_icon.swift" "$ICONSET" "⌨️"
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$DEPLOYMENT_TARGET</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "$APP"
