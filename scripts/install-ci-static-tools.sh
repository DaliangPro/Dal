#!/usr/bin/env bash
set -euo pipefail

# 固定 SwiftLint，避免规则或 baseline 格式随 Homebrew 更新漂移。
TOOLS_ROOT="${RUNNER_TEMP:?需要 CI 临时目录}/dal-static-tools"
mkdir -p "$TOOLS_ROOT"
brew install shellcheck periphery
curl --fail --location --retry 3 \
  https://github.com/realm/SwiftLint/releases/download/0.65.0/portable_swiftlint.zip \
  --output "$TOOLS_ROOT/swiftlint.zip"
echo "d6cb0aa7a2f5f1ef306fc9e37bcb54dc9a26facc8f7784ac0c3dd3eccf5c6ba6  $TOOLS_ROOT/swiftlint.zip" \
  | shasum -a 256 --check
mkdir -p "$TOOLS_ROOT/swiftlint"
ditto -x -k "$TOOLS_ROOT/swiftlint.zip" "$TOOLS_ROOT/swiftlint"
echo "$TOOLS_ROOT/swiftlint" >> "${GITHUB_PATH:?需要 CI PATH 文件}"
"$TOOLS_ROOT/swiftlint/swiftlint" version
shellcheck --version
periphery version
