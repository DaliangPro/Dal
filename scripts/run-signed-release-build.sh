#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"

fail() {
    echo "Signed release build failed: $1" >&2
    exit 1
}

APPLE_CERTIFICATE_P12_BASE64="${APPLE_CERTIFICATE_P12_BASE64:-}"
APPLE_CERTIFICATE_PASSWORD="${APPLE_CERTIFICATE_PASSWORD:-}"
APPLE_CODESIGN_IDENTITY="${APPLE_CODESIGN_IDENTITY:-}"
APPLE_NOTARY_KEY_P8_BASE64="${APPLE_NOTARY_KEY_P8_BASE64:-}"
APPLE_NOTARY_KEY_ID="${APPLE_NOTARY_KEY_ID:-}"
APPLE_NOTARY_ISSUER_ID="${APPLE_NOTARY_ISSUER_ID:-}"
[ -n "$APPLE_CERTIFICATE_P12_BASE64" ] || fail "missing APPLE_CERTIFICATE_P12_BASE64"
[ -n "$APPLE_CERTIFICATE_PASSWORD" ] || fail "missing APPLE_CERTIFICATE_PASSWORD"
case "$APPLE_CODESIGN_IDENTITY" in
    "Developer ID Application:"*) ;;
    *) fail "APPLE_CODESIGN_IDENTITY must be a Developer ID Application identity" ;;
esac
[ -n "$APPLE_NOTARY_KEY_P8_BASE64" ] || fail "missing APPLE_NOTARY_KEY_P8_BASE64"
[[ "$APPLE_NOTARY_KEY_ID" =~ ^[A-Z0-9]{10,64}$ ]] \
    || fail "APPLE_NOTARY_KEY_ID must contain 10 to 64 uppercase letters or digits"
[[ "$APPLE_NOTARY_ISSUER_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || fail "APPLE_NOTARY_ISSUER_ID must be a UUID"
if [ -n "${CODESIGN_IDENTITY:-}" ] && [ "$CODESIGN_IDENTITY" != "$APPLE_CODESIGN_IDENTITY" ]; then
    fail "CODESIGN_IDENTITY does not match APPLE_CODESIGN_IDENTITY"
fi
export CODESIGN_IDENTITY="$APPLE_CODESIGN_IDENTITY"

RUNNER_TEMP="${RUNNER_TEMP:-}"
[ -n "$RUNNER_TEMP" ] && [ -d "$RUNNER_TEMP" ] && [ ! -L "$RUNNER_TEMP" ] \
    || fail "RUNNER_TEMP must be an existing non-symbolic-link directory"
RUNNER_TEMP="$(cd "$RUNNER_TEMP" && /bin/pwd -P)"
DAL_PACKAGE_PREBUILT_BINARY="${DAL_PACKAGE_PREBUILT_BINARY:-}"
DAL_PACKAGE_PREBUILT_SHA256="${DAL_PACKAGE_PREBUILT_SHA256:-}"
case "$DAL_PACKAGE_PREBUILT_BINARY" in
    "$RUNNER_TEMP"/*/Dal) ;;
    *) fail "DAL_PACKAGE_PREBUILT_BINARY must be a Dal path below RUNNER_TEMP" ;;
esac
PREBUILT_DIR="$(dirname "$DAL_PACKAGE_PREBUILT_BINARY")"
[ -d "$PREBUILT_DIR" ] && [ ! -L "$PREBUILT_DIR" ] \
    || fail "prebuilt binary directory is missing or unsafe"
[ "$(cd "$PREBUILT_DIR" && /bin/pwd -P)/Dal" = "$DAL_PACKAGE_PREBUILT_BINARY" ] \
    || fail "prebuilt binary path is not canonical"
[ -f "$DAL_PACKAGE_PREBUILT_BINARY" ] && [ ! -L "$DAL_PACKAGE_PREBUILT_BINARY" ] \
    && [ -x "$DAL_PACKAGE_PREBUILT_BINARY" ] \
    || fail "prebuilt binary is missing or unsafe"
[[ "$DAL_PACKAGE_PREBUILT_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || fail "DAL_PACKAGE_PREBUILT_SHA256 must be 64 lowercase hexadecimal characters"
ACTUAL_PREBUILT_SHA256="$(/usr/bin/shasum -a 256 "$DAL_PACKAGE_PREBUILT_BINARY" | /usr/bin/awk '{print $1}')"
[ "$ACTUAL_PREBUILT_SHA256" = "$DAL_PACKAGE_PREBUILT_SHA256" ] \
    || fail "prebuilt binary SHA256 mismatch before opening the signing keychain"
export DAL_PACKAGE_PREBUILT_BINARY DAL_PACKAGE_PREBUILT_SHA256
export DAL_PACKAGE_REQUIRE_PREBUILT=1
CERTIFICATE_PATH="$RUNNER_TEMP/dal-release-certificate.p12"
KEYCHAIN_PATH="$RUNNER_TEMP/dal-release-signing.keychain-db"
NOTARY_KEY_PATH="$RUNNER_TEMP/AuthKey_${APPLE_NOTARY_KEY_ID}.p8"
[ ! -e "$CERTIFICATE_PATH" ] && [ ! -L "$CERTIFICATE_PATH" ] \
    || fail "temporary certificate path already exists"
[ ! -e "$KEYCHAIN_PATH" ] && [ ! -L "$KEYCHAIN_PATH" ] \
    || fail "temporary keychain path already exists"
[ ! -e "$NOTARY_KEY_PATH" ] && [ ! -L "$NOTARY_KEY_PATH" ] \
    || fail "temporary notarization key path already exists"

trash_path() {
    local path="$1"
    [ -e "$path" ] || [ -L "$path" ] || return 0
    local trash_dir base target
    trash_dir="$HOME/.Trash"
    /bin/mkdir -p "$trash_dir"
    base="$(basename "$path")"
    target="$trash_dir/${base}-$(/bin/date '+%Y%m%d-%H%M%S')-$$"
    while [ -e "$target" ] || [ -L "$target" ]; do
        target="$target-$RANDOM"
    done
    /bin/mv "$path" "$target"
}

ORIGINAL_KEYCHAINS=()
while IFS= read -r keychain; do
    keychain="${keychain#\"}"
    keychain="${keychain%\"}"
    [ -n "$keychain" ] || continue
    ORIGINAL_KEYCHAINS[${#ORIGINAL_KEYCHAINS[@]}]="$keychain"
done < <(/usr/bin/security list-keychains -d user | /usr/bin/sed 's/^[[:space:]]*//')

cleanup_signing() {
    local status="$?"
    trap - EXIT HUP INT TERM
    set +e
    /usr/bin/security lock-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1
    if [ "${#ORIGINAL_KEYCHAINS[@]}" -gt 0 ]; then
        /usr/bin/security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1
    fi
    trash_path "$CERTIFICATE_PATH"
    trash_path "$KEYCHAIN_PATH"
    trash_path "$NOTARY_KEY_PATH"
    exit "$status"
}
trap cleanup_signing EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

KEYCHAIN_PASSWORD="$(/usr/bin/uuidgen)"
printf '%s' "$APPLE_NOTARY_KEY_P8_BASE64" | /usr/bin/base64 --decode > "$NOTARY_KEY_PATH" \
    || fail "unable to decode notarization private key"
/bin/chmod 600 "$NOTARY_KEY_PATH"
printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | /usr/bin/base64 --decode > "$CERTIFICATE_PATH" \
    || fail "unable to decode signing certificate"
/usr/bin/security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
/usr/bin/security set-keychain-settings -lut 1800 "$KEYCHAIN_PATH"
/usr/bin/security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
/usr/bin/security import "$CERTIFICATE_PATH" -k "$KEYCHAIN_PATH" \
    -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
/usr/bin/security set-key-partition-list -S apple-tool:,apple: -s \
    -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
/usr/bin/security list-keychains -d user -s "$KEYCHAIN_PATH" "${ORIGINAL_KEYCHAINS[@]}"
/usr/bin/security find-identity -v -p codesigning "$KEYCHAIN_PATH" | \
    /usr/bin/grep -F -- "$APPLE_CODESIGN_IDENTITY" >/dev/null \
    || fail "configured Developer ID identity is unavailable in the temporary keychain"

# 私钥仅在消费哈希锁定预构建二进制的签名窗口可用；联网仅限 Apple 时间戳与公证链。
NOTARY_KEY_ID="$APPLE_NOTARY_KEY_ID"
NOTARY_ISSUER_ID="$APPLE_NOTARY_ISSUER_ID"
export NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID
unset APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD KEYCHAIN_PASSWORD
unset APPLE_NOTARY_KEY_P8_BASE64 APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID
(
    umask 022
    /bin/bash "$SCRIPT_DIR/release-verify.sh"
)
