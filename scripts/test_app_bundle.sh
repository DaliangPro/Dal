#!/bin/bash
set -euo pipefail

APP_PATH="${1:-${APP_PATH:-/Applications/Dal.app}}"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXPECTED_BUNDLE_ID="${APP_BUNDLE_ID:-pro.daliang.muse}"
EXPECTED_APP_NAME="${APP_NAME:-Dal}"
EXPECTED_VERSION="${APP_VERSION:-2.2.0}"
EXPECTED_BUILD="${APP_BUILD:-1}"
EXPECTED_MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"
EXPECT_LOCAL_BUNDLE="${EXPECT_LOCAL_BUNDLE:-auto}"
DAL_DEFER_GATEKEEPER_ASSESSMENT="${DAL_DEFER_GATEKEEPER_ASSESSMENT:-0}"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

read_plist() {
    local key="$1"
    /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" 2>/dev/null
}

[ -d "$APP_PATH" ] || fail "app bundle not found at $APP_PATH"
[ -f "$INFO_PLIST" ] || fail "Info.plist missing at $INFO_PLIST"
[ -f "$APP_PATH/Contents/MacOS/Dal" ] || fail "app executable missing"
[ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ] || fail "app icon missing"
[ -f "$APP_PATH/Contents/Resources/BrandLogo.png" ] || fail "brand wordmark missing"
case "$DAL_DEFER_GATEKEEPER_ASSESSMENT" in
    0|1) ;;
    *) fail "DAL_DEFER_GATEKEEPER_ASSESSMENT must be 0 or 1" ;;
esac

[ "$(read_plist CFBundleExecutable)" = "Dal" ] || fail "CFBundleExecutable should be Dal"
[ "$(read_plist CFBundleIdentifier)" = "$EXPECTED_BUNDLE_ID" ] || fail "CFBundleIdentifier should be $EXPECTED_BUNDLE_ID"
[ "$(read_plist CFBundleName)" = "$EXPECTED_APP_NAME" ] || fail "CFBundleName should be $EXPECTED_APP_NAME"
[ "$(read_plist CFBundleDisplayName)" = "$EXPECTED_APP_NAME" ] || fail "CFBundleDisplayName should be $EXPECTED_APP_NAME"
[ "$(read_plist CFBundlePackageType)" = "APPL" ] || fail "CFBundlePackageType should be APPL"
[ "$(read_plist CFBundleShortVersionString)" = "$EXPECTED_VERSION" ] || fail "CFBundleShortVersionString should be $EXPECTED_VERSION"
[ "$(read_plist CFBundleVersion)" = "$EXPECTED_BUILD" ] || fail "CFBundleVersion should be $EXPECTED_BUILD"
[ -n "$(read_plist DalSourceCommit)" ] || fail "DalSourceCommit should be present"
[[ "$(read_plist DalSourceCommit)" =~ ^[0-9a-f]{40}$ ]] \
    || fail "DalSourceCommit should be a full lowercase Git commit"
[ "$(read_plist CFBundleIconFile)" = "AppIcon" ] || fail "CFBundleIconFile should be AppIcon"
[ "$(read_plist LSMinimumSystemVersion)" = "$EXPECTED_MIN_SYSTEM_VERSION" ] || fail "LSMinimumSystemVersion should be $EXPECTED_MIN_SYSTEM_VERSION"
[ -n "$(read_plist NSMicrophoneUsageDescription)" ] || fail "NSMicrophoneUsageDescription should be present"
[ -n "$(read_plist NSAppleEventsUsageDescription)" ] || fail "NSAppleEventsUsageDescription should be present"
[ "$(read_plist LSUIElement)" = "true" ] || fail "LSUIElement should be true"

case "$EXPECT_LOCAL_BUNDLE" in
    1)
        [ -d "$APP_PATH/Contents/MacOS/sensevoice-server-dist" ] || fail "Local bundle missing sensevoice-server dist"
        [ -L "$APP_PATH/Contents/MacOS/sensevoice-server" ] || fail "Local bundle missing sensevoice-server executable link"
        [ -x "$APP_PATH/Contents/MacOS/sensevoice-server" ] || fail "sensevoice-server entry is not executable"
        [ -d "$APP_PATH/Contents/MacOS/qwen3-asr-server-dist" ] || fail "Local bundle missing qwen3-asr-server dist"
        [ -L "$APP_PATH/Contents/MacOS/qwen3-asr-server" ] || fail "Local bundle missing qwen3-asr-server executable link"
        [ -x "$APP_PATH/Contents/MacOS/qwen3-asr-server" ] || fail "qwen3-asr-server entry is not executable"
        [ -f "$APP_PATH/Contents/Resources/LocalServices/sensevoice-server-wrapper.sh" ] || fail "Local bundle missing sealed sensevoice wrapper resource"
        [ -f "$APP_PATH/Contents/Resources/LocalServices/qwen3-asr-server-wrapper.sh" ] || fail "Local bundle missing sealed qwen3 wrapper resource"
        ;;
    0)
        [ ! -e "$APP_PATH/Contents/MacOS/sensevoice-server-dist" ] || fail "Cloud bundle contains sensevoice-server dist"
        [ ! -e "$APP_PATH/Contents/MacOS/sensevoice-server" ] || fail "Cloud bundle contains sensevoice-server wrapper"
        [ ! -e "$APP_PATH/Contents/MacOS/qwen3-asr-server-dist" ] || fail "Cloud bundle contains qwen3-asr-server dist"
        [ ! -e "$APP_PATH/Contents/MacOS/qwen3-asr-server" ] || fail "Cloud bundle contains qwen3-asr-server wrapper"
        [ ! -e "$APP_PATH/Contents/Resources/LocalServices" ] || fail "Cloud bundle contains local service resources"
        ;;
    auto) ;;
    *) fail "EXPECT_LOCAL_BUNDLE must be 0, 1, or auto" ;;
esac

if ! /usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_PATH"; then
    fail "strict code signature verification failed"
fi

SIGNED_DETAILS="$(/usr/bin/codesign -dvvv "$APP_PATH" 2>&1)"
SIGNED_AUTHORITY="$(printf '%s\n' "$SIGNED_DETAILS" | /usr/bin/awk -F= '/^Authority=/{print $2; exit}')"
case "$SIGNED_AUTHORITY" in
    "Developer ID Application:"*)
        if [ "$DAL_DEFER_GATEKEEPER_ASSESSMENT" != "1" ]; then
            /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH" \
                || fail "Gatekeeper assessment failed"
        fi
        ;;
esac

echo "PASS: app bundle metadata and strict signature are valid"
