#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && /bin/pwd -P)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && /bin/pwd -P)"

fail() {
    echo "Release binary preparation failed: $1" >&2
    exit 1
}

RUNNER_TEMP="${RUNNER_TEMP:-}"
[ -n "$RUNNER_TEMP" ] && [ -d "$RUNNER_TEMP" ] && [ ! -L "$RUNNER_TEMP" ] \
    || fail "RUNNER_TEMP must be an existing non-symbolic-link directory"
RUNNER_TEMP="$(cd "$RUNNER_TEMP" && /bin/pwd -P)"

PREBUILT_BINARY="${DAL_PACKAGE_PREBUILT_BINARY:-}"
case "$PREBUILT_BINARY" in
    "$RUNNER_TEMP"/*/Dal) ;;
    *) fail "DAL_PACKAGE_PREBUILT_BINARY must be a Dal path below RUNNER_TEMP" ;;
esac
PREBUILT_DIR="$(dirname "$PREBUILT_BINARY")"
[ ! -e "$PREBUILT_DIR" ] && [ ! -L "$PREBUILT_DIR" ] \
    || fail "prebuilt output directory already exists"
/bin/mkdir -m 700 "$PREBUILT_DIR"

trash_path() {
    local path="$1"
    [ -e "$path" ] || [ -L "$path" ] || return 0
    local trash_dir target
    trash_dir="$HOME/.Trash"
    /bin/mkdir -p "$trash_dir"
    target="$trash_dir/$(basename "$path")-$(/bin/date '+%Y%m%d-%H%M%S')-$$"
    while [ -e "$target" ] || [ -L "$target" ]; do target="$target-$RANDOM"; done
    /bin/mv "$path" "$target"
}

PREPARED=0
cleanup() {
    local status="$?"
    trap - EXIT HUP INT TERM
    if [ "$PREPARED" -ne 1 ]; then
        set +e
        trash_path "$PREBUILT_DIR"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

run_swift_build() {
    set +e
    swift build "$@" 2>&1 | /usr/bin/grep -E "Build complete|Build succeeded|error:|warning:"
    local build_status=${PIPESTATUS[0]}
    set -e
    [ "$build_status" -eq 0 ] || fail "swift build failed with exit code $build_status"
}

XCBUILD_BIN="/Library/Developer/SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild"
if [ -x "$XCBUILD_BIN" ]; then
    echo "Building universal release binary before the signing window..."
    run_swift_build -c release --package-path "$PROJECT_DIR" --arch arm64 --arch x86_64
else
    echo "xcbuild unavailable; building the runner architecture before the signing window..."
    run_swift_build -c release --package-path "$PROJECT_DIR"
fi

if [ -f "$PROJECT_DIR/.build/apple/Products/Release/Dal" ]; then
    SOURCE_BINARY="$PROJECT_DIR/.build/apple/Products/Release/Dal"
elif [ -f "$PROJECT_DIR/.build/release/Dal" ]; then
    SOURCE_BINARY="$PROJECT_DIR/.build/release/Dal"
else
    SOURCE_BINARY="$(/usr/bin/find "$PROJECT_DIR/.build" -path '*/release/Dal' -type f \
        -not -path '*/x86_64/*' -not -path '*/arm64/*' -print -quit)"
fi
[ -n "$SOURCE_BINARY" ] && [ -f "$SOURCE_BINARY" ] && [ ! -L "$SOURCE_BINARY" ] \
    || fail "release binary was not produced as a regular file"

/bin/cp "$SOURCE_BINARY" "$PREBUILT_BINARY"
/bin/chmod 500 "$PREBUILT_BINARY"
[ -f "$PREBUILT_BINARY" ] && [ ! -L "$PREBUILT_BINARY" ] && [ -x "$PREBUILT_BINARY" ] \
    || fail "prebuilt release binary is missing or unsafe"
PREPARED=1
echo "Prebuilt release binary ready: $PREBUILT_BINARY"
