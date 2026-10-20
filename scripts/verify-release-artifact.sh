#!/bin/bash
set -euo pipefail

fail() {
    echo "Release artifact policy failed: $1" >&2
    exit 1
}

EXPECTED_REPOSITORY="DaliangPro/Dal"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITHUB_RUN_ID="${GITHUB_RUN_ID:-}"
EXPECTED_ARTIFACT_ID="${EXPECTED_ARTIFACT_ID:-}"
EXPECTED_ARTIFACT_DIGEST="${EXPECTED_ARTIFACT_DIGEST:-}"

[ "$GITHUB_REPOSITORY" = "$EXPECTED_REPOSITORY" ] \
    || fail "workflow must run in $EXPECTED_REPOSITORY"
case "$GITHUB_RUN_ID" in
    ''|*[!0-9]*) fail "GITHUB_RUN_ID must be numeric" ;;
esac
case "$EXPECTED_ARTIFACT_ID" in
    ''|*[!0-9]*) fail "EXPECTED_ARTIFACT_ID must be numeric" ;;
esac
if ! [[ "$EXPECTED_ARTIFACT_DIGEST" =~ ^[0-9a-f]{64}$ ]]; then
    fail "upload-artifact digest must be a bare lowercase SHA256"
fi
[ -x /usr/bin/jq ] || fail "jq is unavailable"

TEST_MODE="${DAL_RELEASE_ARTIFACT_TEST_MODE:-0}"
FIXTURE_PATH="${DAL_RELEASE_ARTIFACT_FIXTURE:-}"
if [ "$TEST_MODE" = "1" ]; then
    [ -n "$FIXTURE_PATH" ] && [ -f "$FIXTURE_PATH" ] && [ ! -L "$FIXTURE_PATH" ] \
        || fail "artifact fixture is missing or unsafe"
    ARTIFACT_METADATA="$(/bin/cat "$FIXTURE_PATH")"
else
    [ "$TEST_MODE" = "0" ] || fail "invalid test-mode flag"
    [ -z "$FIXTURE_PATH" ] || fail "fixture injection is forbidden outside test mode"
    [ -n "${GH_TOKEN:-}" ] || fail "GH_TOKEN is required"
    command -v gh >/dev/null 2>&1 || fail "GitHub CLI is unavailable"
    ARTIFACT_METADATA="$(gh api \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2026-03-10' \
        "repos/$GITHUB_REPOSITORY/actions/artifacts/$EXPECTED_ARTIFACT_ID")" \
        || fail "unable to load artifact metadata"
fi

printf '%s' "$ARTIFACT_METADATA" | /usr/bin/jq -e \
    --arg digest "sha256:$EXPECTED_ARTIFACT_DIGEST" \
    --argjson artifact_id "$EXPECTED_ARTIFACT_ID" \
    --argjson run_id "$GITHUB_RUN_ID" '
        .id == $artifact_id
        and .expired == false
        and .workflow_run.id == $run_id
        and .digest == $digest
    ' >/dev/null || fail "artifact ID, digest, expiry, or source run does not match"

echo "RELEASE_ARTIFACT_POLICY_RESULT: PASS"
