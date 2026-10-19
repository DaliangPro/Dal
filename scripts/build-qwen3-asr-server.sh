#!/bin/bash
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SERVER_DIR="$PROJECT_DIR/qwen3-asr-server"

trash_path() {
    local path="$1"
    [ -e "$path" ] || [ -L "$path" ] || return 0
    local trash_dir base target
    trash_dir="$HOME/.Trash"
    /bin/mkdir -p "$trash_dir"
    base="$(basename "$path")"
    target="$trash_dir/${base}-$(/bin/date '+%Y%m%d-%H%M%S')-$$"
    while [ -e "$target" ] || [ -L "$target" ]; do
        target="$target-$RANDOM"
    done
    /bin/mv "$path" "$target"
}

echo "=== Building qwen3-asr-server standalone binary ==="

cd "$SERVER_DIR"

# Ensure venv exists (use python3.14 for MLX compatibility)
if [ ! -d .venv ]; then
    echo "Creating venv..."
    # 用 uv 建 venv（自带 python 管理，不依赖系统 brew python3.14 是否存在）
    uv venv --python 3.14.6 .venv
fi

source .venv/bin/activate

# Install dependencies + pyinstaller（.venv 由 uv 创建，不含 pip，改用 uv pip）
echo "Installing dependencies..."
REQUIREMENTS_FILE="requirements.lock.txt"
[ -f "$REQUIREMENTS_FILE" ] || {
    echo "Missing pinned dependency file: $REQUIREMENTS_FILE" >&2
    exit 1
}
uv pip install -q -r "$REQUIREMENTS_FILE"
uv pip check

# 旧构建可恢复地移入废纸篓；不覆盖仓库中的 spec 文件。
trash_path "$SERVER_DIR/build"
trash_path "$SERVER_DIR/dist"
/bin/mkdir -p "$SERVER_DIR/build/spec"

# Build standalone binary
echo "Running PyInstaller..."
pyinstaller \
    --onedir \
    --name qwen3-asr-server \
    --specpath "$SERVER_DIR/build/spec" \
    --paths "$PROJECT_DIR/local-service-shared" \
    --hidden-import=mlx \
    --hidden-import=mlx.core \
    --hidden-import=mlx.nn \
    --hidden-import=mlx_qwen3_asr \
    --hidden-import=llama_cpp \
    --hidden-import=numpy \
    --hidden-import=soundfile \
    --hidden-import=uvicorn \
    --hidden-import=uvicorn.logging \
    --hidden-import=uvicorn.loops \
    --hidden-import=uvicorn.loops.auto \
    --hidden-import=uvicorn.protocols \
    --hidden-import=uvicorn.protocols.http \
    --hidden-import=uvicorn.protocols.http.auto \
    --hidden-import=uvicorn.protocols.websockets \
    --hidden-import=uvicorn.protocols.websockets.auto \
    --hidden-import=uvicorn.lifespan \
    --hidden-import=uvicorn.lifespan.on \
    --hidden-import=fastapi \
    --hidden-import=starlette \
    --hidden-import=starlette.routing \
    --hidden-import=starlette.middleware \
    --collect-all mlx \
    --collect-all mlx_qwen3_asr \
    --collect-all llama_cpp \
    --noconfirm \
    server.py

echo ""
echo "=== Signing binaries for macOS Gatekeeper ==="
DIST="$SERVER_DIR/dist/qwen3-asr-server"
# Ad-hoc sign all executables and dylibs to avoid Gatekeeper blocking
find "$DIST" -type f \( -name "*.dylib" -o -name "*.so" -o -name "*.metallib" -o -perm +111 \) -exec codesign --force --sign - {} \; 2>/dev/null || true
codesign --force --sign - "$DIST/qwen3-asr-server" 2>/dev/null || true
echo "Signing complete."

echo ""
echo "=== Build complete ==="
echo "Output: $DIST"
du -sh "$DIST" 2>/dev/null || true
echo ""
echo "Test with:"
echo "  $DIST/qwen3-asr-server --model-path <path-to-qwen3-asr-model> --port 8766"
