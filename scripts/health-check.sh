#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

FAILED=0

run_step() {
  local name="$1"
  shift
  local start end status
  start="$(date +%s)"
  echo
  echo "==> $name"
  "$@"
  status=$?
  end="$(date +%s)"
  echo "TOOL:$name EXIT:$status DURATION:$((end - start))s"
  if [ "$status" -ne 0 ]; then
    FAILED=1
  fi
}

skip_step() {
  local name="$1"
  local reason="$2"
  echo
  echo "==> $name"
  echo "SKIP: $reason"
  echo "TOOL:$name EXIT:SKIPPED DURATION:0s"
}

bash_syntax() {
  local status=0
  while IFS= read -r -d '' file; do
    bash -n "$file" || status=1
  done < <(find scripts -type f -name "*.sh" -print0 | sort -z)
  return "$status"
}

python_service_syntax() {
  python3 - <<'PY'
import ast
import pathlib
import sys

paths = [
    pathlib.Path("scripts/build-voice-polish-quality-test-set-v2.py"),
    pathlib.Path("scripts/validate-voice-polish-quality-test-set.py"),
    pathlib.Path("scripts/evaluate-voice-polish-quality-report.py"),
    pathlib.Path("sensevoice-server/server.py"),
    pathlib.Path("sensevoice-server/sensevoice_model.py"),
    pathlib.Path("qwen3-asr-server/server.py"),
    pathlib.Path("local-service-shared/local_service_security.py"),
    pathlib.Path("local-service-shared/test_local_service_security.py"),
    pathlib.Path("local-service-shared/test_server_security_wiring.py"),
]

failed = False
for path in paths:
    try:
        ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        print(f"OK {path}")
    except SyntaxError as exc:
        print(f"ERROR {path}:{exc.lineno}:{exc.offset}: {exc.msg}")
        failed = True

sys.exit(1 if failed else 0)
PY
}

python_service_tests() {
  python3 -m unittest discover -s local-service-shared -p 'test_*.py'
}

model_artifact_policy() {
  local sources=(
    "Muse/Services/ModelArtifactManifest.swift"
    "Muse/Services/ModelManager.swift"
  )

  if grep -Ein 'https?://[^"[:space:]]*/resolve/(main|master|latest)/' "${sources[@]}"; then
    echo "ERROR: model artifact URL uses a floating revision"
    return 1
  fi
  if grep -Ein 'URLSessionConfiguration\.default' "${sources[@]}"; then
    echo "ERROR: model downloads must not use the default URLSession configuration"
    return 1
  fi
  if ! grep -q 'URLSessionConfiguration\.ephemeral' "${sources[@]}"; then
    echo "ERROR: model downloads are missing an ephemeral URLSession configuration"
    return 1
  fi
  if ! grep -q 'ModelArtifactManifest\.all' MuseTests/ModelArtifactVerificationTests.swift; then
    echo "ERROR: model artifact manifest integrity test is missing"
    return 1
  fi
}

package_signing_policy() {
  local package_script="scripts/package-app.sh"
  local signing_script="scripts/sign-app-bundle.sh"
  local validation_script="scripts/test_app_bundle.sh"

  if grep -q 'SERVER_TEMP=' "$package_script"; then
    echo "ERROR: package script still moves local services around the outer signature"
    return 1
  fi
  if grep -E 'codesign[^|]*--sign[^|]*\|\|[[:space:]]*true' "$package_script" "$signing_script"; then
    echo "ERROR: code signing failures must never be ignored"
    return 1
  fi
  if ! grep -Fq '/usr/bin/file' "$signing_script"; then
    echo "ERROR: nested code detection must inspect Mach-O contents"
    return 1
  fi
  if ! grep -Fq 'MetalLib\ executable' "$signing_script"; then
    echo "ERROR: nested code detection must include MetalLib executables"
    return 1
  fi
  if ! grep -Fq '/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$APP_PATH"' "$signing_script"; then
    echo "ERROR: outer app signature is missing"
    return 1
  fi
  if ! grep -Fq '/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_PATH"' "$signing_script"; then
    echo "ERROR: final strict signature verification is missing"
    return 1
  fi
  if ! grep -Fq '/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_PATH"' "$validation_script"; then
    echo "ERROR: bundle validation script is missing strict verification"
    return 1
  fi
  if [ ! -f MuseTests/PackageScriptTests.swift ]; then
    echo "ERROR: package signing regression tests are missing"
    return 1
  fi
}

ci_release_policy() {
  local required_files=(
    ".github/workflows/ci.yml"
    ".github/workflows/release-verify.yml"
    "scripts/notarize-release-artifacts.sh"
    "scripts/release-verify.sh"
    "scripts/prepare-release-binary.sh"
    "scripts/run-signed-release-build.sh"
    "scripts/verify-release-artifact.sh"
    "scripts/verify-release-environments.sh"
    "scripts/verify-release-version.sh"
    ".swiftlint.yml"
    ".swiftlint-baseline.json"
    "MuseTests/CIWorkflowTests.swift"
    "MuseTests/ReleaseVerifyScriptTests.swift"
  )
  local file
  for file in "${required_files[@]}"; do
    if [ ! -f "$file" ]; then
      echo "ERROR: required CI/release gate is missing: $file"
      return 1
    fi
  done
  if ! grep -Fq 'static let updateChannelEnabled = false' Muse/Services/UpdateChecker.swift; then
    echo "ERROR: automatic updates must remain disabled until real dual-artifact acceptance"
    return 1
  fi
  if grep -Fq 'static let updateChannelEnabled = true' Muse/Services/UpdateChecker.swift; then
    echo "ERROR: automatic update channel was enabled before real acceptance"
    return 1
  fi
}

run_optional_tool() {
  local name="$1"
  local command_name="$2"
  shift 2
  if command -v "$command_name" >/dev/null 2>&1; then
    run_step "$name" "$@"
  elif [ "${MUSE_REQUIRE_STATIC_TOOLS:-0}" = "1" ]; then
    echo
    echo "==> $name"
    echo "ERROR: $command_name not installed; CI static quality gate is mandatory"
    echo "TOOL:$name EXIT:MISSING DURATION:0s"
    FAILED=1
    return 1
  else
    skip_step "$name" "$command_name not installed"
  fi
}

swiftlint_changed_files() {
  local files
  files="$(git diff --name-only HEAD^ HEAD -- '*.swift')"
  if [ -z "$files" ]; then
    echo "No changed Swift files; strict SwiftLint gate is not needed for this commit"
    return 0
  fi
  # 文件路径来自 git，不含用户输入；SwiftLint 需要逐个接收这些路径。
  # shellcheck disable=SC2086
  swiftlint lint --strict --config .swiftlint.yml $files
}

echo "CODE HEALTH CHECK"
echo "Project: Muse"
echo "Branch:  $(git branch --show-current 2>/dev/null || echo unknown)"
echo "Date:    $(date '+%Y-%m-%d %H:%M:%S %Z')"

run_step "swift-build-debug" swift build
run_step "swift-build-release" swift build -c release
run_step "swift-test" swift test
run_step "manual-release-tests" python3 -m unittest discover -s scripts -p 'test_publish_release.py' -v
run_step "model-artifact-policy" model_artifact_policy
run_step "package-signing-policy" package_signing_policy
run_step "ci-release-policy" ci_release_policy
run_step "bash-syntax" bash_syntax
run_step "python-service-syntax" python_service_syntax
run_step "python-service-tests" python_service_tests
run_step "voice-polish-quality-test-set" python3 scripts/validate-voice-polish-quality-test-set.py

run_optional_tool "shellcheck" shellcheck shellcheck scripts/*.sh
run_optional_tool "swiftlint" swiftlint swiftlint_changed_files
run_optional_tool "periphery" periphery periphery scan

echo
if [ "$FAILED" -eq 0 ]; then
  echo "HEALTH_CHECK_RESULT: PASS"
else
  echo "HEALTH_CHECK_RESULT: FAIL"
fi

exit "$FAILED"
