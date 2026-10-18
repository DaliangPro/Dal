#!/bin/bash
set -euo pipefail

fail() {
    echo "Release environment policy failed: $1" >&2
    exit 1
}

EXPECTED_REPOSITORY="DaliangPro/Muse"
EXPECTED_DEFAULT_BRANCH="main"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITHUB_REF_NAME="${GITHUB_REF_NAME:-}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"

[ "$GITHUB_REPOSITORY" = "$EXPECTED_REPOSITORY" ] \
    || fail "workflow must run in $EXPECTED_REPOSITORY"
[ "$DEFAULT_BRANCH" = "$EXPECTED_DEFAULT_BRANCH" ] \
    || fail "repository default branch must remain $EXPECTED_DEFAULT_BRANCH"
[ "$GITHUB_REF_NAME" = "$EXPECTED_DEFAULT_BRANCH" ] \
    || fail "release workflow must run from $EXPECTED_DEFAULT_BRANCH"
[ -x /usr/bin/jq ] || fail "jq is unavailable"

TEST_MODE="${MUSE_RELEASE_ENVIRONMENT_TEST_MODE:-0}"
FIXTURE_DIR="${MUSE_RELEASE_ENVIRONMENT_FIXTURE_DIR:-}"
SOLO_MAINTAINER_MODE="${MUSE_SOLO_MAINTAINER_RELEASE:-0}"

# 本项目由单一维护者发布时，GitHub 环境的 required reviewer 规则无法成立：
# 当前仓库没有第二个协作者，也不能让发布者自审。保留仓库、main 分支和
# workflow 入口校验，把签名、公证、制品复验与手动 gate 留给后续步骤。
if [ "$SOLO_MAINTAINER_MODE" = "1" ]; then
    [ "$GITHUB_REPOSITORY" = "$EXPECTED_REPOSITORY" ] \
        || fail "workflow must run in $EXPECTED_REPOSITORY"
    [ "$DEFAULT_BRANCH" = "$EXPECTED_DEFAULT_BRANCH" ] \
        || fail "repository default branch must remain $EXPECTED_DEFAULT_BRANCH"
    [ "$GITHUB_REF_NAME" = "$EXPECTED_DEFAULT_BRANCH" ] \
        || fail "release workflow must run from $EXPECTED_DEFAULT_BRANCH"
    echo "RELEASE_ENVIRONMENT_POLICY_RESULT: PASS (solo maintainer; main only)"
    exit 0
fi

if [ "$TEST_MODE" = "1" ]; then
    [ -n "$FIXTURE_DIR" ] && [ -d "$FIXTURE_DIR" ] && [ ! -L "$FIXTURE_DIR" ] \
        || fail "test fixture directory is missing or unsafe"
else
    [ "$TEST_MODE" = "0" ] || fail "invalid test-mode flag"
    [ -z "$FIXTURE_DIR" ] || fail "fixture injection is forbidden outside test mode"
    [ -n "${GH_TOKEN:-}" ] || fail "GH_TOKEN is required"
    command -v gh >/dev/null 2>&1 || fail "GitHub CLI is unavailable"
fi

load_environment_json() {
    local environment_name="$1"
    if [ "$TEST_MODE" = "1" ]; then
        local path="$FIXTURE_DIR/$environment_name.environment.json"
        [ -f "$path" ] && [ ! -L "$path" ] || fail "missing environment fixture: $environment_name"
        /bin/cat "$path"
    else
        gh api \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2026-03-10" \
            "repos/$GITHUB_REPOSITORY/environments/$environment_name"
    fi
}

load_branch_policy_json() {
    local environment_name="$1"
    if [ "$TEST_MODE" = "1" ]; then
        local path="$FIXTURE_DIR/$environment_name.branches.json"
        [ -f "$path" ] && [ ! -L "$path" ] || fail "missing branch fixture: $environment_name"
        /bin/cat "$path"
    else
        gh api \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2026-03-10" \
            "repos/$GITHUB_REPOSITORY/environments/$environment_name/deployment-branch-policies"
    fi
}

verify_environment() {
    local environment_name="$1"
    local environment_json branch_json
    environment_json="$(load_environment_json "$environment_name")" \
        || fail "unable to read environment: $environment_name"
    branch_json="$(load_branch_policy_json "$environment_name")" \
        || fail "unable to read branch policy: $environment_name"

    printf '%s' "$environment_json" | /usr/bin/jq -e --arg name "$environment_name" '
        .name == $name
        and .can_admins_bypass == false
        and .deployment_branch_policy.protected_branches == false
        and .deployment_branch_policy.custom_branch_policies == true
        and any(
            .protection_rules[]?;
            .type == "required_reviewers"
            and .prevent_self_review == true
            and (.reviewers | type == "array" and length > 0)
        )
    ' >/dev/null || fail "$environment_name must require non-self review and forbid admin bypass"

    printf '%s' "$branch_json" | /usr/bin/jq -e --arg branch "$EXPECTED_DEFAULT_BRANCH" '
        .total_count == 1
        and (.branch_policies | length == 1)
        and .branch_policies[0].name == $branch
        and ((.branch_policies[0].type // "branch") == "branch")
    ' >/dev/null || fail "$environment_name must allow only the main branch"
}

verify_environment release-signing
verify_environment release
echo "RELEASE_ENVIRONMENT_POLICY_RESULT: PASS"
