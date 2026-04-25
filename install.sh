#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VARIANT="${1:-doubao}"

case "$VARIANT" in
  doubao)
    APP_NAME="DoubaoInputIndicator"
    AGENT_ID="local.doubao-input-indicator"
    ;;
  wetype|wechat)
    APP_NAME="WeTypeInputIndicator"
    AGENT_ID="local.wetype-input-indicator"
    ;;
  *)
    echo "Usage: $0 [doubao|wetype]" >&2
    exit 2
    ;;
esac

SRC_APP="$ROOT/build/$APP_NAME.app"
DEST_APP="/Applications/$APP_NAME.app"
LEGACY_USER_APP="$HOME/Applications/$APP_NAME.app"
BUILD_APP="$ROOT/build/$APP_NAME.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_ID.plist"

stop_running_app() {
  launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" >/dev/null 2>&1 || true
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -f "$DEST_APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || true
  pkill -f "$LEGACY_USER_APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || true
  pkill -f "$BUILD_APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || true
}

stop_running_app
"$ROOT/build.sh" "$VARIANT" >/dev/null

mkdir -p "$HOME/Library/LaunchAgents"
stop_running_app
rm -rf "$DEST_APP"
rm -rf "$LEGACY_USER_APP"
cp -R "$SRC_APP" "$DEST_APP"

cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$AGENT_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-g</string>
    <string>$DEST_APP</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
PLIST

stop_running_app
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" >/dev/null
launchctl enable "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1 || true

echo "Installed: $DEST_APP"
echo "LaunchAgent: $AGENT_PLIST"
