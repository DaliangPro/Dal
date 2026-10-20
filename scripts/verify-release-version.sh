#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && /bin/pwd -P)"

fail() {
    echo "Release version policy failed: $1" >&2
    exit 1
}

valid_version() {
    [[ "$1" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]]
}

version_is_greater() {
    /usr/bin/awk -v candidate="$1" -v current="$2" '
        BEGIN {
            split(candidate, candidateParts, ".")
            split(current, currentParts, ".")
            for (partIndex = 1; partIndex <= 3; partIndex++) {
                candidateValue = candidateParts[partIndex] + 0
                currentValue = currentParts[partIndex] + 0
                if (candidateValue > currentValue) exit 0
                if (candidateValue < currentValue) exit 1
            }
            exit 1
        }
    '
}

EXPECTED_REPOSITORY="DaliangPro/Dal"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
APP_VERSION="${APP_VERSION:-}"
[ "$GITHUB_REPOSITORY" = "$EXPECTED_REPOSITORY" ] \
    || fail "workflow must run in $EXPECTED_REPOSITORY"
valid_version "$APP_VERSION" || fail "APP_VERSION must be bounded major.minor.patch"
[ -x /usr/bin/jq ] || fail "jq is unavailable"

TEST_MODE="${DAL_RELEASE_VERSION_TEST_MODE:-0}"
RELEASES_FIXTURE="${DAL_RELEASE_RELEASES_FIXTURE:-}"
UPDATES_FIXTURE="${DAL_RELEASE_UPDATES_FIXTURE:-}"
if [ "$TEST_MODE" = "1" ]; then
    [ -f "$RELEASES_FIXTURE" ] && [ ! -L "$RELEASES_FIXTURE" ] \
        || fail "release fixture is missing or unsafe"
    [ -f "$UPDATES_FIXTURE" ] && [ ! -L "$UPDATES_FIXTURE" ] \
        || fail "updates fixture is missing or unsafe"
    RELEASES_JSON="$(/bin/cat "$RELEASES_FIXTURE")"
    UPDATES_JSON="$UPDATES_FIXTURE"
else
    [ "$TEST_MODE" = "0" ] || fail "invalid test-mode flag"
    [ -z "$RELEASES_FIXTURE" ] && [ -z "$UPDATES_FIXTURE" ] \
        || fail "fixture injection is forbidden outside test mode"
    [ -n "${GH_TOKEN:-}" ] || fail "GH_TOKEN is required"
    command -v gh >/dev/null 2>&1 || fail "GitHub CLI is unavailable"
    RELEASES_JSON="$(gh api --paginate --slurp \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2026-03-10' \
        "repos/$GITHUB_REPOSITORY/releases?per_page=100")" \
        || fail "unable to list existing releases"
    UPDATES_JSON="$PROJECT_DIR/updates.json"
fi

[ -f "$UPDATES_JSON" ] && [ ! -L "$UPDATES_JSON" ] \
    || fail "updates.json is missing or unsafe"
MANIFEST_LATEST="$(/usr/bin/jq -er '.latest | select(type == "string")' "$UPDATES_JSON")" \
    || fail "updates.json latest is invalid"
valid_version "$MANIFEST_LATEST" || fail "updates.json latest must be bounded major.minor.patch"

NORMALIZED_RELEASES="$(printf '%s' "$RELEASES_JSON" | /usr/bin/jq -c '
    if type != "array" then error("release response must be an array")
    elif length > 0 and (.[0] | type) == "array" then [ .[][] ]
    else .
    end
')" || fail "release response is invalid"
printf '%s' "$NORMALIZED_RELEASES" | /usr/bin/jq -e '
    type == "array"
    and all(.[];
        (.tag_name | type) == "string"
        and (.draft | type) == "boolean"
        and (.prerelease | type) == "boolean"
    )
' >/dev/null || fail "release response fields are invalid"

HIGHEST_PUBLISHED=""
TARGET_EXISTS=0
while IFS=$'\t' read -r tag_name is_draft is_prerelease; do
    [ -n "$tag_name" ] || continue
    if [ "$tag_name" = "v$APP_VERSION" ]; then
        TARGET_EXISTS=1
    fi
    case "$tag_name" in
        v*) release_version="${tag_name#v}" ;;
        *) continue ;;
    esac
    valid_version "$release_version" || continue
    if [ "$is_draft" = "false" ] && [ "$is_prerelease" = "false" ]; then
        if [ -z "$HIGHEST_PUBLISHED" ] || version_is_greater "$release_version" "$HIGHEST_PUBLISHED"; then
            HIGHEST_PUBLISHED="$release_version"
        fi
    fi
done < <(printf '%s' "$NORMALIZED_RELEASES" | /usr/bin/jq -r '
    .[] | [.tag_name, (.draft | tostring), (.prerelease | tostring)] | @tsv
')

[ "$TARGET_EXISTS" -eq 0 ] || fail "release v$APP_VERSION already exists"
[ -n "$HIGHEST_PUBLISHED" ] || HIGHEST_PUBLISHED="0.0.0"
[ "$MANIFEST_LATEST" = "$HIGHEST_PUBLISHED" ] \
    || fail "updates.json latest does not match the highest published release ($HIGHEST_PUBLISHED)"
version_is_greater "$APP_VERSION" "$HIGHEST_PUBLISHED" \
    || fail "APP_VERSION must be newer than the highest published release ($HIGHEST_PUBLISHED)"

echo "RELEASE_VERSION_POLICY_RESULT: PASS ($HIGHEST_PUBLISHED -> $APP_VERSION)"
