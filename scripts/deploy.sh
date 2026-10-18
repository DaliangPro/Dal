#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
APP_PATH="${APP_PATH:-/Applications/Muse.app}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-pro.daliang.muse}"
LAUNCH_APP="${LAUNCH_APP:-1}"

# 同名 app（如 Meta 的 Muse，com.meta.endo）可能占用 /Applications/Muse.app：
# 目标存在但 bundle id 不符时拒绝覆盖，退出也按 bundle id 而非名字
if [ -d "$APP_PATH" ]; then
    EXISTING_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
    if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "$APP_BUNDLE_ID" ]; then
        echo "Refusing to deploy: $APP_PATH belongs to $EXISTING_ID, not $APP_BUNDLE_ID (set APP_PATH)" >&2
        exit 1
    fi
fi

echo "Stopping Muse..."
osascript -e "quit app id \"$APP_BUNDLE_ID\"" 2>/dev/null || true
sleep 1

APP_PATH="$APP_PATH" bash "$SCRIPT_DIR/package-app.sh"

if [ "$LAUNCH_APP" = "1" ]; then
    echo "Launching via GUI session (no shell env vars)..."
    launchctl asuser "$(id -u)" /usr/bin/open "$APP_PATH"
else
    echo "Skipping launch because LAUNCH_APP=$LAUNCH_APP"
fi

echo "Done."
