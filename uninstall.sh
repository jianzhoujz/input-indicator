#!/usr/bin/env bash
set -euo pipefail

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

DEST_APP="/Applications/$APP_NAME.app"
LEGACY_USER_APP="$HOME/Applications/$APP_NAME.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_ID.plist"

launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" >/dev/null 2>&1 || true
pkill -f "$DEST_APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || true
pkill -f "$LEGACY_USER_APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1 || true
rm -f "$AGENT_PLIST"
rm -rf "$DEST_APP"
rm -rf "$LEGACY_USER_APP"

echo "Uninstalled $APP_NAME"
