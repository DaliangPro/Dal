#!/bin/bash
set -euo pipefail

APP_PATH="${1:-${APP_PATH:-}}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-pro.daliang.muse}"
INFO_PLIST="$APP_PATH/Contents/Info.plist"

fail() {
    echo "Signing failed: $1" >&2
    exit 1
}

[ -n "$APP_PATH" ] || fail "APP_PATH is required"
[ -d "$APP_PATH" ] || fail "app bundle not found at $APP_PATH"
[ -f "$INFO_PLIST" ] || fail "Info.plist missing at $INFO_PLIST"
[ -n "$SIGNING_IDENTITY" ] || fail "SIGNING_IDENTITY is required"
DAL_DEFER_GATEKEEPER_ASSESSMENT="${DAL_DEFER_GATEKEEPER_ASSESSMENT:-0}"
case "$DAL_DEFER_GATEKEEPER_ASSESSMENT" in
    0|1) ;;
    *) fail "DAL_DEFER_GATEKEEPER_ASSESSMENT must be 0 or 1" ;;
esac

case "$APP_BUNDLE_ID" in
    pro.daliang.muse|pro.daliang.muse.preview|pro.daliang.muse.interactive-test) ;;
    *) fail "拒绝为其他应用签名" ;;
esac
ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" \
    || fail "应用身份缺失"
[ "$ACTUAL_BUNDLE_ID" = "$APP_BUNDLE_ID" ] || fail "应用身份不匹配"
[ ! -L "$APP_PATH" ] && [ ! -L "$APP_PATH/Contents" ] && [ ! -L "$INFO_PLIST" ] \
    || fail "拒绝符号链接应用"

MAIN_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null)" \
    || fail "unable to read CFBundleExecutable"
MAIN_EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$MAIN_EXECUTABLE"
NESTED_CODESIGN_BIN="/usr/bin/codesign"
if [ "${DAL_PACKAGE_SIGNING_TEST_MODE:-0}" = "1" ] \
    && [ -n "${DAL_NESTED_CODESIGN_BIN:-}" ]; then
    [ -x "$DAL_NESTED_CODESIGN_BIN" ] || fail "test nested codesign shim is not executable"
    NESTED_CODESIGN_BIN="$DAL_NESTED_CODESIGN_BIN"
fi

is_macho_file() {
    local candidate="$1"
    local description
    description="$(/usr/bin/file -b "$candidate")" || return 1
    case "$description" in
        *Mach-O*|*MetalLib\ executable*) return 0 ;;
        *) return 1 ;;
    esac
}

echo "Signing nested Mach-O code with '$SIGNING_IDENTITY'..."
while IFS= read -r -d '' candidate; do
    [ "$candidate" = "$MAIN_EXECUTABLE_PATH" ] && continue
    is_macho_file "$candidate" || continue

    echo "Signing nested Mach-O: ${candidate#"$APP_PATH"/}"
    if [[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]]; then
        sign_status=0
        "$NESTED_CODESIGN_BIN" --force --timestamp --options runtime \
            --sign "$SIGNING_IDENTITY" "$candidate" || sign_status="$?"
    else
        sign_status=0
        "$NESTED_CODESIGN_BIN" --force --sign "$SIGNING_IDENTITY" "$candidate" \
            || sign_status="$?"
    fi
    if [ "$sign_status" -ne 0 ]; then
        echo "Nested code signing failed: $candidate" >&2
        exit 1
    fi
done < <(/usr/bin/find "$APP_PATH/Contents" -type f -print0)

echo "Signing outer app bundle last..."
if [[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]]; then
    /usr/bin/codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" "$APP_PATH"
else
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$APP_PATH"
fi

# 从此处开始只允许读 Bundle：严格验签、读取元数据和 Gatekeeper 评估。
/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_PATH"

SIGNED_DETAILS="$(/usr/bin/codesign -dvvv "$APP_PATH" 2>&1)"
SIGNED_IDENTIFIER="$(printf '%s\n' "$SIGNED_DETAILS" | /usr/bin/awk -F= '/^Identifier=/{print $2; exit}')"
SIGNED_AUTHORITY="$(printf '%s\n' "$SIGNED_DETAILS" | /usr/bin/awk -F= '/^Authority=/{print $2; exit}')"
if [ "$SIGNED_IDENTIFIER" != "$APP_BUNDLE_ID" ]; then
    fail "expected bundle id '$APP_BUNDLE_ID', got '$SIGNED_IDENTIFIER'"
fi
if [ "$SIGNING_IDENTITY" != "-" ] \
    && [ -n "$SIGNED_AUTHORITY" ] \
    && [ "$SIGNED_AUTHORITY" != "$SIGNING_IDENTITY" ]; then
    fail "expected authority '$SIGNING_IDENTITY', got '$SIGNED_AUTHORITY'"
fi

case "$SIGNED_AUTHORITY" in
    "Developer ID Application:"*)
        if [ "$DAL_DEFER_GATEKEEPER_ASSESSMENT" != "1" ]; then
            /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH"
        fi
        ;;
esac

echo "Signing validated: $SIGNED_IDENTIFIER / ${SIGNED_AUTHORITY:-ad-hoc}"
