#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VARIANT="${1:-doubao}"
APP_VERSION="${APP_VERSION:-${VERSION:-1.1.2}}"

case "$VARIANT" in
  doubao)
    APP_NAME="DoubaoInputIndicator"
    DISPLAY_NAME="豆包输入法指示器"
    ;;
  wetype|wechat)
    APP_NAME="WeTypeInputIndicator"
    DISPLAY_NAME="微信输入法指示器"
    ;;
  *)
    echo "Usage: $0 [doubao|wetype]" >&2
    exit 2
    ;;
esac

APP_PATH="$ROOT/build/$APP_NAME.app"
DIST_DIR="$ROOT/dist"
WORK_DIR="$ROOT/build/dmg-$APP_NAME"
STAGE_DIR="$WORK_DIR/stage"
RW_DMG="$WORK_DIR/$APP_NAME-rw.dmg"
FINAL_DMG="$DIST_DIR/$APP_NAME-$APP_VERSION.dmg"
VOLUME_NAME="$APP_NAME"
MOUNT_DIR="/Volumes/$VOLUME_NAME"
DMG_ASSET_DIR="$ROOT/packaging/dmg"

"$ROOT/build.sh" "$VARIANT" >/dev/null

rm -rf "$WORK_DIR"
mkdir -p "$STAGE_DIR/.background" "$DIST_DIR"

cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
# The VS Code .DS_Store references a root-level .background.tiff. Finder
# rewrites the current volume-specific alias below, but keep this copy so the
# imported layout data remains internally consistent.
cp "$DMG_ASSET_DIR/background.tiff" "$STAGE_DIR/.background.tiff"
cp "$DMG_ASSET_DIR/background.tiff" "$STAGE_DIR/.background/background.tiff"
cp "$DMG_ASSET_DIR/VolumeIcon.icns" "$STAGE_DIR/.VolumeIcon.icns"
cp "$DMG_ASSET_DIR/DS_Store" "$STAGE_DIR/.DS_Store"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -fs HFS+ \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDRW \
  "$RW_DMG" >/dev/null

cleanup() {
  hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
rmdir "$MOUNT_DIR" >/dev/null 2>&1 || true

hdiutil attach "$RW_DMG" \
  -readwrite \
  -noverify \
  -noautoopen \
  -mountpoint "$MOUNT_DIR" >/dev/null

SetFile -a C "$MOUNT_DIR" >/dev/null 2>&1 || true

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
  open
  delay 1
  set current view of container window to icon view
  set toolbar visible of container window to false
  set statusbar visible of container window to false
  set bounds of container window to {100, 400, 580, 752}
  set theViewOptions to icon view options of container window
  set arrangement of theViewOptions to not arranged
  set background picture of theViewOptions to (POSIX file "$MOUNT_DIR/.background/background.tiff" as alias)
  set icon size of theViewOptions to 80
  set text size of theViewOptions to 12
  set position of item "$APP_NAME.app" of container window to {120, 160}
  set position of item "Applications" of container window to {360, 160}
  update without registering applications
  delay 1
  close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" >/dev/null
trap - EXIT

rm -f "$FINAL_DMG"
hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$FINAL_DMG" >/dev/null

rm -rf "$WORK_DIR"

echo "$FINAL_DMG"
