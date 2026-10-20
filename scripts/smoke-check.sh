#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
RUN_UI_INJECTION=0
RUN_APP_LAUNCH=0

usage() {
    cat <<'EOF'
usage: scripts/smoke-check.sh [--ui-injection] [--app-launch] [--all]

Default checks:
  swift build
  swift test

Optional checks:
  --ui-injection  Run TextEdit clipboard injection tests. Requires macOS UI permissions.
  --app-launch    Build the app bundle and verify the packaged app process starts.
  --all           Run all optional checks.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ui-injection)
            RUN_UI_INJECTION=1
            ;;
        --app-launch)
            RUN_APP_LAUNCH=1
            ;;
        --all)
            RUN_UI_INJECTION=1
            RUN_APP_LAUNCH=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
    shift
done

cd "$ROOT_DIR"

run_step() {
    echo
    echo "==> $*"
    "$@"
}

run_step swift build
run_step swift test

if [ "$RUN_UI_INJECTION" = "1" ]; then
    echo
    echo "==> DAL_RUN_UI_INJECTION_TEST=1 swift test --filter TextInjectionEngineIntegrationTests"
    DAL_RUN_UI_INJECTION_TEST=1 swift test --filter TextInjectionEngineIntegrationTests
fi

if [ "$RUN_APP_LAUNCH" = "1" ]; then
    run_step "$ROOT_DIR/scripts/build_and_run.sh" --verify
fi

echo
echo "Smoke checks completed."
