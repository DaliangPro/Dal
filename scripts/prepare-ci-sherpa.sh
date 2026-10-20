#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="$ROOT_DIR/Frameworks/sherpa-onnx.xcframework"
if [ -e "$DESTINATION" ]; then
  echo '拒绝覆盖已有 Sherpa Framework；本入口只用于干净的 CI checkout' >&2
  exit 1
fi
ARTIFACT='sherpa-onnx-v1.12.33-osx-universal2-static-lib'
STAGING="${RUNNER_TEMP:?需要 CI 临时目录}/dal-sherpa"
mkdir -p "$STAGING" "$ROOT_DIR/Frameworks"
curl --fail --location --retry 3 \
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.33/$ARTIFACT.tar.bz2" \
  --output "$STAGING/framework.tar.bz2"
echo "8aedcf8ddd8c5d464b35a63efc6d47f4243e1a5d6da8e088aec9c964658cecc1  $STAGING/framework.tar.bz2" \
  | shasum -a 256 --check
tar -xf "$STAGING/framework.tar.bz2" -C "$STAGING"
mkdir -p "$STAGING/Headers"
curl --fail --location --retry 3 \
  https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/5092b4487125b6584b77aaa3c9dcf5f97063dce8/sherpa-onnx/c-api/c-api.h \
  --output "$STAGING/Headers/c-api.h"
echo "3ca64ce5af66d965fb2cd7cabbfc187d88808f4b65015c1439b47014825def25  $STAGING/Headers/c-api.h" \
  | shasum -a 256 --check
/usr/bin/libtool -static -o "$STAGING/libsherpa-onnx.a" "$STAGING/$ARTIFACT/lib/"*.a
xcodebuild -create-xcframework \
  -library "$STAGING/libsherpa-onnx.a" \
  -headers "$STAGING/Headers" \
  -output "$DESTINATION"
test -s "$DESTINATION/Info.plist"
swift package --package-path "$ROOT_DIR" describe --type json | python3 -c '
import json, sys
package = json.load(sys.stdin)
assert any(target["name"] == "SherpaOnnxLib" for target in package["targets"]), "Framework 未被 SwiftPM 启用"
print("已启用真实 SherpaOnnxLib binary target")
'
