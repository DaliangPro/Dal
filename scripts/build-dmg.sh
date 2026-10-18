#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && /bin/pwd -P)"
APP_NAME="Muse"
APP_VERSION="${APP_VERSION:-2.1.2}"
case "$APP_VERSION" in
    ''|.*|*.|*..*|*[!0-9.]*)
        echo "APP_VERSION must be numeric dot-separated" >&2
        exit 1
        ;;
esac

ARTIFACT_KIND="${ARTIFACT_KIND:-}"
case "$ARTIFACT_KIND" in
    cloud) BUNDLE_LOCAL_ASR=0 ;;
    local) BUNDLE_LOCAL_ASR=1 ;;
    *)
        echo "ARTIFACT_KIND must be cloud or local" >&2
        exit 1
        ;;
esac

DIST_DIR="${DIST_DIR:-$PROJECT_DIR/dist}"
DMG_NAME="${DMG_NAME:-Muse-v${APP_VERSION}-${ARTIFACT_KIND}.dmg}"
case "$DMG_NAME" in
    [A-Za-z0-9]*.dmg) ;;
    *)
        echo "DMG_NAME must be a .dmg basename" >&2
        exit 1
        ;;
esac
case "$DMG_NAME" in
    */*|*[!A-Za-z0-9._-]*)
        echo "DMG_NAME must be a .dmg basename" >&2
        exit 1
        ;;
esac

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
ALLOW_ADHOC_DMG="${ALLOW_ADHOC_DMG:-0}"
ALLOW_LOCAL_SIGNING="${ALLOW_LOCAL_SIGNING:-0}"
UPDATE_READY="yes"
if [ -z "$CODESIGN_IDENTITY" ] || [ "$CODESIGN_IDENTITY" = "-" ]; then
    if [ "$ALLOW_ADHOC_DMG" != "1" ]; then
        echo "CODESIGN_IDENTITY is required; set ALLOW_ADHOC_DMG=1 only for development artifacts" >&2
        exit 1
    fi
    CODESIGN_IDENTITY="-"
    UPDATE_READY="no"
elif [ "$CODESIGN_IDENTITY" = "Muse Local" ] && [ "$ALLOW_LOCAL_SIGNING" = "1" ]; then
    # Muse 的公开手动分发沿用本机 Muse Local 证书；它没有 Developer ID
    # TeamIdentifier，也不进入自动更新清单，但仍保留应用包的严格签名校验。
    UPDATE_READY="no"
fi

CODESIGN_BIN="/usr/bin/codesign"
HDIUTIL_BIN="/usr/bin/hdiutil"
SHASUM_BIN="/usr/bin/shasum"
MV_BIN="/bin/mv"
if [ "${MUSE_DMG_TEST_MODE:-0}" = "1" ]; then
    CODESIGN_BIN="${MUSE_DMG_CODESIGN_BIN:-$CODESIGN_BIN}"
    HDIUTIL_BIN="${MUSE_DMG_HDIUTIL_BIN:-$HDIUTIL_BIN}"
    SHASUM_BIN="${MUSE_DMG_SHASUM_BIN:-$SHASUM_BIN}"
    MV_BIN="${MUSE_DMG_MV_BIN:-$MV_BIN}"
    [ -x "$CODESIGN_BIN" ] || { echo "test codesign shim is not executable" >&2; exit 1; }
    [ -x "$HDIUTIL_BIN" ] || { echo "test hdiutil shim is not executable" >&2; exit 1; }
    [ -x "$SHASUM_BIN" ] || { echo "test shasum shim is not executable" >&2; exit 1; }
    [ -x "$MV_BIN" ] || { echo "test mv shim is not executable" >&2; exit 1; }
fi

VOLUME_NAME="${VOLUME_NAME:-$APP_NAME ${ARTIFACT_KIND}}"
/bin/mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && /bin/pwd -P)"
DMG_PATH="$DIST_DIR/$DMG_NAME"
TX_ID="$(/usr/bin/uuidgen)"
PARTIAL_DMG="$DIST_DIR/.${DMG_NAME%.dmg}.partial-$TX_ID.dmg"
PREVIOUS_DMG="$DIST_DIR/.${DMG_NAME}.previous-$TX_ID"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/muse-dmg.XXXXXX")"
/bin/chmod 755 "$STAGING_DIR"
PUBLISHED=0

trash_path() {
    local path="$1"
    [ -e "$path" ] || [ -L "$path" ] || return 0

    local trash_dir base stamp target
    trash_dir="$HOME/.Trash"
    /bin/mkdir -p "$trash_dir"
    base="$(basename "$path")"
    stamp="$(date +%Y%m%d-%H%M%S)"
    target="$trash_dir/${base}-${stamp}"
    while [ -e "$target" ] || [ -L "$target" ]; do
        target="$trash_dir/${base}-${stamp}-$RANDOM"
    done
    "$MV_BIN" "$path" "$target"
}

cleanup() {
    local status="$?"
    trap - EXIT
    set +e
    trash_path "$STAGING_DIR"
    trash_path "$PARTIAL_DMG"
    if [ -e "$PREVIOUS_DMG" ] || [ -L "$PREVIOUS_DMG" ]; then
        if [ "$PUBLISHED" -eq 1 ]; then
            trash_path "$PREVIOUS_DMG"
        elif [ ! -e "$DMG_PATH" ] && [ ! -L "$DMG_PATH" ]; then
            "$MV_BIN" "$PREVIOUS_DMG" "$DMG_PATH"
        else
            trash_path "$PREVIOUS_DMG"
        fi
    fi
    exit "$status"
}
trap cleanup EXIT

[ ! -e "$PARTIAL_DMG" ] && [ ! -L "$PARTIAL_DMG" ] \
    || { echo "Partial DMG path already exists" >&2; exit 1; }
[ ! -e "$PREVIOUS_DMG" ] && [ ! -L "$PREVIOUS_DMG" ] \
    || { echo "Previous DMG path already exists" >&2; exit 1; }

APP_PATH="$STAGING_DIR/${APP_NAME}.app"
CODESIGN_IDENTITY="$CODESIGN_IDENTITY" BUNDLE_LOCAL_ASR="$BUNDLE_LOCAL_ASR" APP_PATH="$APP_PATH" \
    /bin/bash "$SCRIPT_DIR/package-app.sh"
EXPECT_LOCAL_BUNDLE="$BUNDLE_LOCAL_ASR" \
    /bin/bash "$SCRIPT_DIR/test_app_bundle.sh" "$APP_PATH"
"$CODESIGN_BIN" --verify --deep --strict --verbose=4 "$APP_PATH"

APP_SIGNATURE_DETAILS="$("$CODESIGN_BIN" -dvvv "$APP_PATH" 2>&1)"
APP_TEAM="$(echo "$APP_SIGNATURE_DETAILS" | /usr/bin/awk -F= '/^TeamIdentifier=/ {print $2; exit}')"
if [ "$UPDATE_READY" = "yes" ]; then
    [ -n "$APP_TEAM" ] && [ "$APP_TEAM" != "not set" ] || {
        echo "Release App must have a non-empty TeamIdentifier" >&2
        exit 1
    }
    echo "$APP_SIGNATURE_DETAILS" | /usr/bin/grep -q '^Authority=Developer ID Application:' || {
        echo "Release App must use a Developer ID Application identity" >&2
        exit 1
    }
    echo "$APP_SIGNATURE_DETAILS" | /usr/bin/grep -q 'flags=.*runtime' || {
        echo "Release App must enable Hardened Runtime" >&2
        exit 1
    }
fi

/bin/ln -s /Applications "$STAGING_DIR/Applications"
echo "Creating verified DMG at $DMG_PATH..."
"$HDIUTIL_BIN" create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    "$PARTIAL_DMG"

if [ "$UPDATE_READY" = "yes" ]; then
    "$CODESIGN_BIN" --force --timestamp --sign "$CODESIGN_IDENTITY" "$PARTIAL_DMG"
    "$CODESIGN_BIN" --verify --strict --verbose=4 "$PARTIAL_DMG"
else
    echo "WARNING: local/ad-hoc DMG is not eligible for the update manifest" >&2
fi

"$HDIUTIL_BIN" verify "$PARTIAL_DMG"
DMG_SHA256="$("$SHASUM_BIN" -a 256 "$PARTIAL_DMG" | /usr/bin/awk '{print $1}')"
[ "${#DMG_SHA256}" -eq 64 ] || {
    echo "Failed to calculate DMG SHA256" >&2
    exit 1
}

if [ -e "$DMG_PATH" ] || [ -L "$DMG_PATH" ]; then
    "$MV_BIN" "$DMG_PATH" "$PREVIOUS_DMG"
fi
"$MV_BIN" "$PARTIAL_DMG" "$DMG_PATH"
PUBLISHED=1
trash_path "$PREVIOUS_DMG"

echo "DMG ready at $DMG_PATH"
echo "Artifact: $ARTIFACT_KIND"
echo "TeamIdentifier: ${APP_TEAM:-not set}"
echo "SHA256: $DMG_SHA256"
echo "UPDATE_READY: $UPDATE_READY"
