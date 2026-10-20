#!/bin/bash
set -euo pipefail

fail() {
    echo "Release notarization failed: $1" >&2
    exit 1
}

DAL_NOTARIZATION_MODE="${DAL_NOTARIZATION_MODE:-}"
case "$DAL_NOTARIZATION_MODE" in
    submit|verify) ;;
    *) fail "DAL_NOTARIZATION_MODE must be submit or verify" ;;
esac

CLOUD_DMG="${CLOUD_DMG:-}"
LOCAL_DMG="${LOCAL_DMG:-}"
for artifact in "$CLOUD_DMG" "$LOCAL_DMG"; do
    [ -n "$artifact" ] && [ -f "$artifact" ] && [ ! -L "$artifact" ] \
        || fail "both Cloud and Local DMGs must be regular files"
done
[ "$CLOUD_DMG" != "$LOCAL_DMG" ] || fail "Cloud and Local DMGs must be distinct"

XCRUN_BIN="/usr/bin/xcrun"
SPCTL_BIN="/usr/sbin/spctl"
if [ "${DAL_NOTARIZATION_TEST_MODE:-0}" = "1" ]; then
    XCRUN_BIN="${DAL_NOTARIZATION_XCRUN_BIN:-$XCRUN_BIN}"
    SPCTL_BIN="${DAL_NOTARIZATION_SPCTL_BIN:-$SPCTL_BIN}"
elif [ "${DAL_NOTARIZATION_TEST_MODE:-0}" != "0" ]; then
    fail "invalid notarization test-mode flag"
fi
[ -f "$XCRUN_BIN" ] && [ -x "$XCRUN_BIN" ] || fail "xcrun is unavailable"
[ -f "$SPCTL_BIN" ] && [ -x "$SPCTL_BIN" ] || fail "spctl is unavailable"

if [ "$DAL_NOTARIZATION_MODE" = "submit" ]; then
    NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-}"
    NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
    NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"
    [ -f "$NOTARY_KEY_PATH" ] && [ ! -L "$NOTARY_KEY_PATH" ] \
        || fail "NOTARY_KEY_PATH must be a regular private-key file"
    [[ "$NOTARY_KEY_ID" =~ ^[A-Z0-9]{10,64}$ ]] \
        || fail "NOTARY_KEY_ID must contain 10 to 64 uppercase letters or digits"
    [[ "$NOTARY_ISSUER_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
        || fail "NOTARY_ISSUER_ID must be a UUID"
fi

for artifact in "$CLOUD_DMG" "$LOCAL_DMG"; do
    if [ "$DAL_NOTARIZATION_MODE" = "submit" ]; then
        "$XCRUN_BIN" notarytool submit "$artifact" \
            --key "$NOTARY_KEY_PATH" \
            --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" \
            --wait \
            --timeout 60m
        "$XCRUN_BIN" stapler staple "$artifact"
    fi
    "$XCRUN_BIN" stapler validate "$artifact"
    "$SPCTL_BIN" --assess --type open --context context:primary-signature \
        --verbose=4 "$artifact"
done

echo "NOTARIZATION_RESULT: PASS ($DAL_NOTARIZATION_MODE)"
