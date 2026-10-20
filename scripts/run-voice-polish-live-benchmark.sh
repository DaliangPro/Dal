#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_PATH="${DAL_VOICE_POLISH_LIVE_REPORT:-$PROJECT_DIR/build/voice-polish-live-report.json}"
LIMIT="${DAL_VOICE_POLISH_LIVE_LIMIT:-100}"

mkdir -p "$(dirname "$REPORT_PATH")"
cd "$PROJECT_DIR"
DAL_VOICE_POLISH_LIVE=1 \
DAL_VOICE_POLISH_LIVE_LIMIT="$LIMIT" \
DAL_VOICE_POLISH_LIVE_REPORT="$REPORT_PATH" \
swift test --filter VoicePolishLiveBenchmarkTests/testExplicitLiveProviderBenchmark

echo "Voice Polish Live Benchmark 报告：$REPORT_PATH"
