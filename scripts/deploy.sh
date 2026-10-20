#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
APP_PATH="${APP_PATH:-/Applications/Dal.app}"
[ "${APP_BUNDLE_ID:-pro.daliang.muse}" = "pro.daliang.muse" ] || {
    echo "只能部署 Dal 自有应用身份" >&2; exit 1;
}
python3 "$SCRIPT_DIR/app_identity.py" "$APP_PATH"
# 候选先在隔离目录完成构建与签名，不提前终止正在工作的应用。
CANDIDATE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dal-deploy.XXXXXX")"
CANDIDATE="$CANDIDATE_ROOT/candidate.noindex/Dal.app"
APP_PATH="$CANDIDATE" APP_NAME=Dal APP_BUNDLE_ID=pro.daliang.muse \
    bash "$SCRIPT_DIR/package-app.sh"
INSTALL_ARGS=()
if [ "$APP_PATH" = /Applications/Dal.app ]; then INSTALL_ARGS+=(--migrate-legacy); fi
if [ "${LAUNCH_APP:-1}" = 0 ]; then INSTALL_ARGS+=(--no-launch); fi
python3 "$SCRIPT_DIR/install-app.py" "$CANDIDATE" --destination "$APP_PATH" "${INSTALL_ARGS[@]}"
# 候选留作回滚证据但不再被当成应用收录。
mv "$CANDIDATE" "$CANDIDATE.disabled"
