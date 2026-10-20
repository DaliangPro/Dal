#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
if [ "$#" -gt 0 ]; then
  shift
fi
APP_ARGS=()
if [ "${1:-}" = "--args" ]; then
  shift
  APP_ARGS=("$@")
elif [ "$#" -gt 0 ]; then
  echo "usage: $0 [run|--verify|--logs|--telemetry|--debug] [--args <app arguments...>]" >&2
  exit 2
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Dal"
APP_BUNDLE_ID="pro.daliang.muse"
APP_PATH="${DAL_APP_PATH:-/Applications/Dal.app}"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_NAME"

running_app_pids() {
  /bin/ps -axo pid=,command= | /usr/bin/awk -v executable="$APP_EXECUTABLE" '
    {
      pid = $1
      command = $0
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", command)
      if (command == executable || index(command, executable " ") == 1) {
        print pid
      }
    }
  '
}

verify_single_running_instance() {
  local pids count
  pids="$(running_app_pids)"
  count="$(printf '%s\n' "$pids" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
  if [ "$count" -ne 1 ]; then
    echo "ERROR: expected exactly one $APP_NAME process, found $count: $pids" >&2
    return 1
  fi
}

build_app() {
  APP_PATH="$APP_PATH" LAUNCH_APP=0 bash "$ROOT_DIR/scripts/deploy.sh"
}

open_app() {
  if [ "${#APP_ARGS[@]}" -gt 0 ]; then
    /usr/bin/open -n "$APP_PATH" --args "${APP_ARGS[@]}"
  else
    /usr/bin/open -n "$APP_PATH"
  fi
}

case "$MODE" in
  run)
    build_app
    open_app
    ;;
  --verify|verify)
    build_app
    open_app
    sleep 2
    verify_single_running_instance
    ;;
  --logs|logs)
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"Dal\""
    ;;
  --telemetry|telemetry)
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$APP_BUNDLE_ID\""
    ;;
  --debug|debug)
    build_app
    /usr/bin/lldb -- "$APP_PATH/Contents/MacOS/Dal"
    ;;
  *)
    echo "usage: $0 [run|--verify|--logs|--telemetry|--debug] [--args <app arguments...>]" >&2
    exit 2
    ;;
esac
