#!/bin/bash
# shellcheck disable=SC2016
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && /bin/pwd -P)"

fail() {
    echo "Release verification failed: $1" >&2
    exit 1
}

RELEASE_VERIFY_MODE="${RELEASE_VERIFY_MODE:-build}"
case "$RELEASE_VERIFY_MODE" in
    build|verify) ;;
    *) fail "RELEASE_VERIFY_MODE must be build or verify" ;;
esac

APP_VERSION="${APP_VERSION:-}"
if ! [[ "$APP_VERSION" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]]; then
    fail "APP_VERSION must be major.minor.patch with bounded numeric components"
fi

APP_BUILD="${APP_BUILD:-}"
case "$APP_BUILD" in
    ''|*[!0-9]*) fail "APP_BUILD must be numeric" ;;
esac

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ "$RELEASE_VERIFY_MODE" = "build" ]; then
    [ -n "$CODESIGN_IDENTITY" ] && [ "$CODESIGN_IDENTITY" != "-" ] \
        || fail "a non-ad-hoc CODESIGN_IDENTITY is required"
fi

EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-}"
case "$EXPECTED_TEAM_ID" in
    ??????????) ;;
    *) fail "EXPECTED_TEAM_ID must contain exactly 10 uppercase letters or digits" ;;
esac
case "$EXPECTED_TEAM_ID" in
    *[!A-Z0-9]*) fail "EXPECTED_TEAM_ID must contain exactly 10 uppercase letters or digits" ;;
esac

RELEASE_BASE_URL="${RELEASE_BASE_URL:-}"
if ! [[ "$RELEASE_BASE_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~-]+)*$ ]]; then
    fail "RELEASE_BASE_URL must be an HTTPS URL without credentials, query, fragment, or trailing slash"
fi
case "$RELEASE_BASE_URL" in
    */v"$APP_VERSION") ;;
    *) fail "RELEASE_BASE_URL must end with the exact v$APP_VERSION release tag" ;;
esac

RELEASE_NOTES="${RELEASE_NOTES:-}"
[ -n "$RELEASE_NOTES" ] || fail "RELEASE_NOTES is required"
RELEASE_DATE="${RELEASE_DATE:-}"
if [ "$RELEASE_VERIFY_MODE" = "build" ] && [ -z "$RELEASE_DATE" ]; then
    RELEASE_DATE="$(/bin/date -u '+%Y-%m-%d')"
fi
if [ -n "$RELEASE_DATE" ] && ! [[ "$RELEASE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    fail "RELEASE_DATE must use YYYY-MM-DD"
fi

BUILD_DMG_SCRIPT="$SCRIPT_DIR/build-dmg.sh"
NOTARIZE_SCRIPT="$SCRIPT_DIR/notarize-release-artifacts.sh"
TEST_APP_BUNDLE_SCRIPT="$SCRIPT_DIR/test_app_bundle.sh"
CODESIGN_BIN="/usr/bin/codesign"
HDIUTIL_BIN="/usr/bin/hdiutil"
SHASUM_BIN="/usr/bin/shasum"
JQ_BIN="/usr/bin/jq"
if [ "${MUSE_RELEASE_VERIFY_TEST_MODE:-0}" = "1" ]; then
    BUILD_DMG_SCRIPT="${MUSE_RELEASE_BUILD_DMG_SCRIPT:-$BUILD_DMG_SCRIPT}"
    NOTARIZE_SCRIPT="${MUSE_RELEASE_NOTARIZE_SCRIPT:-$NOTARIZE_SCRIPT}"
    TEST_APP_BUNDLE_SCRIPT="${MUSE_RELEASE_TEST_APP_BUNDLE_SCRIPT:-$TEST_APP_BUNDLE_SCRIPT}"
    CODESIGN_BIN="${MUSE_RELEASE_CODESIGN_BIN:-$CODESIGN_BIN}"
    HDIUTIL_BIN="${MUSE_RELEASE_HDIUTIL_BIN:-$HDIUTIL_BIN}"
    SHASUM_BIN="${MUSE_RELEASE_SHASUM_BIN:-$SHASUM_BIN}"
fi
for tool in "$BUILD_DMG_SCRIPT" "$NOTARIZE_SCRIPT" "$TEST_APP_BUNDLE_SCRIPT" \
    "$CODESIGN_BIN" "$HDIUTIL_BIN" "$SHASUM_BIN" "$JQ_BIN"; do
    [ -f "$tool" ] && [ -x "$tool" ] || fail "required tool is unavailable: $tool"
done

UPDATES_JSON="$PROJECT_DIR/updates.json"
[ -f "$UPDATES_JSON" ] && [ ! -L "$UPDATES_JSON" ] || fail "updates.json is missing or unsafe"
LATEST_VERSION="$("$JQ_BIN" -er '.latest | select(type == "string")' "$UPDATES_JSON")" \
    || fail "updates.json latest version is invalid"
if ! [[ "$LATEST_VERSION" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]]; then
    fail "updates.json latest version is invalid"
fi

version_is_greater() {
    /usr/bin/awk -v candidate="$1" -v current="$2" '
        BEGIN {
            candidateCount = split(candidate, candidateParts, ".")
            currentCount = split(current, currentParts, ".")
            count = candidateCount > currentCount ? candidateCount : currentCount
            for (partIndex = 1; partIndex <= count; partIndex++) {
                candidateValue = partIndex <= candidateCount ? candidateParts[partIndex] + 0 : 0
                currentValue = partIndex <= currentCount ? currentParts[partIndex] + 0 : 0
                if (candidateValue > currentValue) exit 0
                if (candidateValue < currentValue) exit 1
            }
            exit 1
        }
    '
}
version_is_greater "$APP_VERSION" "$LATEST_VERSION" \
    || fail "APP_VERSION must be newer than updates.json latest ($LATEST_VERSION)"

RELEASE_OUTPUT_DIR="${RELEASE_OUTPUT_DIR:-$PROJECT_DIR/dist/release}"
if [ -L "$RELEASE_OUTPUT_DIR" ]; then
    fail "RELEASE_OUTPUT_DIR must not be a symbolic link"
fi
if [ "$RELEASE_VERIFY_MODE" = "build" ]; then
    /bin/mkdir -p "$RELEASE_OUTPUT_DIR"
    if [ -n "$(/usr/bin/find "$RELEASE_OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        fail "RELEASE_OUTPUT_DIR must be empty in build mode"
    fi
else
    [ -d "$RELEASE_OUTPUT_DIR" ] || fail "RELEASE_OUTPUT_DIR is missing in verify mode"
fi
RELEASE_OUTPUT_DIR="$(cd "$RELEASE_OUTPUT_DIR" && /bin/pwd -P)"

CLOUD_DMG="$RELEASE_OUTPUT_DIR/Muse-v${APP_VERSION}-cloud.dmg"
LOCAL_DMG="$RELEASE_OUTPUT_DIR/Muse-v${APP_VERSION}-local.dmg"
MANIFEST_PATH="$RELEASE_OUTPUT_DIR/manifest-fragment.json"
MOUNTED_PATH=""
MANIFEST_TEMP=""

trash_path() {
    local path="$1"
    [ -e "$path" ] || [ -L "$path" ] || return 0
    local trash_dir base stamp target
    trash_dir="$HOME/.Trash"
    /bin/mkdir -p "$trash_dir"
    base="$(basename "$path")"
    stamp="$(/bin/date '+%Y%m%d-%H%M%S')"
    target="$trash_dir/${base}-${stamp}"
    while [ -e "$target" ] || [ -L "$target" ]; do
        target="$trash_dir/${base}-${stamp}-$RANDOM"
    done
    /bin/mv "$path" "$target"
}

cleanup() {
    local status="$?"
    trap - EXIT HUP INT TERM
    set +e
    if [ -n "$MOUNTED_PATH" ]; then
        "$HDIUTIL_BIN" detach "$MOUNTED_PATH" >/dev/null 2>&1
        trash_path "$MOUNTED_PATH"
    fi
    if [ -n "$MANIFEST_TEMP" ]; then
        trash_path "$MANIFEST_TEMP"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$RELEASE_VERIFY_MODE" = "build" ]; then
    SENSEVOICE_LAUNCHER="$PROJECT_DIR/sensevoice-server/dist/sensevoice-server/sensevoice-server"
    QWEN_LAUNCHER="$PROJECT_DIR/qwen3-asr-server/dist/qwen3-asr-server/qwen3-asr-server"
    [ -f "$SENSEVOICE_LAUNCHER" ] && [ ! -L "$SENSEVOICE_LAUNCHER" ] && [ -x "$SENSEVOICE_LAUNCHER" ] \
        || fail "SenseVoice frozen launcher is missing or unsafe"
    [ -f "$QWEN_LAUNCHER" ] && [ ! -L "$QWEN_LAUNCHER" ] && [ -x "$QWEN_LAUNCHER" ] \
        || fail "Qwen frozen launcher is missing or unsafe"

    for artifact_kind in cloud local; do
        ARTIFACT_KIND="$artifact_kind" \
        APP_VERSION="$APP_VERSION" \
        APP_BUILD="$APP_BUILD" \
        CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
        DIST_DIR="$RELEASE_OUTPUT_DIR" \
        MUSE_DEFER_GATEKEEPER_ASSESSMENT=1 \
            /bin/bash "$BUILD_DMG_SCRIPT"
    done
fi

if [ "$RELEASE_VERIFY_MODE" = "build" ]; then
    NOTARIZATION_MODE=submit
else
    NOTARIZATION_MODE=verify
fi
CLOUD_DMG="$CLOUD_DMG" \
LOCAL_DMG="$LOCAL_DMG" \
MUSE_NOTARIZATION_MODE="$NOTARIZATION_MODE" \
    /bin/bash "$NOTARIZE_SCRIPT"

verify_dmg() {
    local artifact_kind="$1"
    local dmg_path="$2"
    local expected_local="$3"
    local mount_path app_path app_count signature_details team_id

    [ -f "$dmg_path" ] && [ ! -L "$dmg_path" ] || fail "$artifact_kind DMG is missing or unsafe"
    "$CODESIGN_BIN" --verify --strict --verbose=4 "$dmg_path"
    "$HDIUTIL_BIN" verify "$dmg_path"

    mount_path="$(mktemp -d "${TMPDIR:-/tmp}/muse-release-${artifact_kind}.XXXXXX")"
    "$HDIUTIL_BIN" attach -readonly -nobrowse -mountpoint "$mount_path" "$dmg_path"
    MOUNTED_PATH="$mount_path"
    app_path="$mount_path/Muse.app"
    app_count="$(/usr/bin/find "$mount_path" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    [ "$app_count" = "1" ] && [ -d "$app_path" ] || fail "$artifact_kind DMG must contain exactly one root Muse.app"

    EXPECT_LOCAL_BUNDLE="$expected_local" \
    APP_VERSION="$APP_VERSION" \
    APP_BUILD="$APP_BUILD" \
        /bin/bash "$TEST_APP_BUNDLE_SCRIPT" "$app_path"
    "$CODESIGN_BIN" --verify --deep --strict --verbose=4 "$app_path"
    signature_details="$("$CODESIGN_BIN" -dvvv "$app_path" 2>&1)"
    echo "$signature_details" | /usr/bin/grep -q '^Authority=Developer ID Application:' \
        || fail "$artifact_kind App is not signed with Developer ID Application"
    echo "$signature_details" | /usr/bin/grep -q 'flags=.*runtime' \
        || fail "$artifact_kind App is not signed with Hardened Runtime"
    team_id="$(echo "$signature_details" | /usr/bin/awk -F= '/^TeamIdentifier=/ {print $2; exit}')"
    [ "$team_id" = "$EXPECTED_TEAM_ID" ] \
        || fail "$artifact_kind App TeamIdentifier does not match EXPECTED_TEAM_ID"

    "$HDIUTIL_BIN" detach "$mount_path"
    MOUNTED_PATH=""
    trash_path "$mount_path"
}

verify_dmg cloud "$CLOUD_DMG" 0
verify_dmg local "$LOCAL_DMG" 1

hash_file() {
    local path="$1"
    local output digest
    output="$("$SHASUM_BIN" -a 256 "$path")"
    digest="${output%% *}"
    case "$digest" in
        ????????????????????????????????????????????????????????????????) ;;
        *) fail "unable to calculate SHA256 for $(basename "$path")" ;;
    esac
    case "$digest" in
        *[!0-9a-fA-F]*) fail "invalid SHA256 for $(basename "$path")" ;;
    esac
    printf '%s' "$digest" | /usr/bin/tr 'A-F' 'a-f'
}

cloud_hash="$(hash_file "$CLOUD_DMG")"
local_hash="$(hash_file "$LOCAL_DMG")"
cloud_url="$RELEASE_BASE_URL/$(basename "$CLOUD_DMG")"
local_url="$RELEASE_BASE_URL/$(basename "$LOCAL_DMG")"

validate_manifest() {
    local path="$1"
    "$JQ_BIN" -e \
        --arg version "$APP_VERSION" \
        --arg date "$RELEASE_DATE" \
        --arg notes "$RELEASE_NOTES" \
        --arg cloudURL "$cloud_url" \
        --arg cloudHash "$cloud_hash" \
        --arg localURL "$local_url" \
        --arg localHash "$local_hash" \
        '
            keys == ["artifacts", "date", "notes", "version"] and
            .version == $version and
            .date == $date and
            (.date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and
            .notes == $notes and
            (.artifacts | keys == ["cloud", "local"]) and
            (.artifacts.cloud | keys == ["sha256", "url"]) and
            (.artifacts.local | keys == ["sha256", "url"]) and
            .artifacts.cloud.url == $cloudURL and
            .artifacts.cloud.sha256 == $cloudHash and
            .artifacts.local.url == $localURL and
            .artifacts.local.sha256 == $localHash
        ' "$path" >/dev/null
}

if [ "$RELEASE_VERIFY_MODE" = "build" ]; then
    [ ! -e "$MANIFEST_PATH" ] && [ ! -L "$MANIFEST_PATH" ] \
        || fail "manifest output already exists"
    MANIFEST_TEMP="$(mktemp "$RELEASE_OUTPUT_DIR/.manifest-fragment.XXXXXX")"
    "$JQ_BIN" -n \
        --arg version "$APP_VERSION" \
        --arg date "$RELEASE_DATE" \
        --arg notes "$RELEASE_NOTES" \
        --arg cloudURL "$cloud_url" \
        --arg cloudHash "$cloud_hash" \
        --arg localURL "$local_url" \
        --arg localHash "$local_hash" \
        '{
            version: $version,
            date: $date,
            notes: $notes,
            artifacts: {
                cloud: {url: $cloudURL, sha256: $cloudHash},
                local: {url: $localURL, sha256: $localHash}
            }
        }' > "$MANIFEST_TEMP"
    /bin/chmod 600 "$MANIFEST_TEMP"
    validate_manifest "$MANIFEST_TEMP" \
        || fail "generated manifest fragment does not match the verified artifacts"
    /bin/mv "$MANIFEST_TEMP" "$MANIFEST_PATH"
    MANIFEST_TEMP=""
else
    [ -f "$MANIFEST_PATH" ] && [ ! -L "$MANIFEST_PATH" ] \
        || fail "manifest fragment is missing or unsafe"
    if [ -z "$RELEASE_DATE" ]; then
        RELEASE_DATE="$("$JQ_BIN" -er '.date | select(type == "string")' "$MANIFEST_PATH")" \
            || fail "manifest date is invalid"
    fi
    validate_manifest "$MANIFEST_PATH" \
        || fail "manifest fragment does not match the verified artifacts"
fi

echo "Release artifacts verified: $APP_VERSION ($APP_BUILD)"
echo "Cloud SHA256: $cloud_hash"
echo "Local SHA256: $local_hash"
echo "Manifest fragment: $MANIFEST_PATH"
echo "RELEASE_VERIFY_RESULT: PASS"
