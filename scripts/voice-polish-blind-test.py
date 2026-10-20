#!/usr/bin/env python3
"""Dal Voice Polish 与 Typeless 同音频人工盲测准备与计分工具。"""

import argparse
import hashlib
import json
import math
import random
import re
import secrets
import shutil
import subprocess
import tempfile
import wave
from datetime import datetime, timezone
from pathlib import Path

MINIMUM_SAMPLE_COUNT = 100
MINIMUM_AUDIO_DURATION_SECONDS = 0.5
CANONICAL_AUDIO_SAMPLE_RATE = 16_000
ALLOWED_ROUTES = {"fast", "structured", "deep"}
MINIMUM_ROUTE_SAMPLE_COUNTS = {
    "fast": 20,
    "structured": 20,
    "deep": 10,
}
BASE_ROUTE_CALL_COUNTS = {"fast": 1, "structured": 1, "deep": 2}
MAXIMUM_ROUTE_CALL_COUNTS = {"fast": 1, "structured": 2, "deep": 3}
REQUIRED_CATEGORIES = (
    "proper_noun",
    "self_correction",
    "aside",
    "disordered",
    "list",
    "numbers",
    "mixed_language",
    "ai_prompt",
)
ALLOWED_RATINGS = {"left", "right", "tie", "both_unusable"}
RATING_DIMENSIONS = (
    "overall",
    "writing_quality",
    "terminology",
    "fact_preservation",
    "sendability",
)
REQUIRED_DAL_METRICS = {
    "latency_ms",
    "route",
    "call_count",
    "repair_used",
    "fallback_used",
    "confirmed_alias_total",
    "confirmed_alias_correct",
    "critical_fact_total",
    "critical_fact_preserved",
    "whitelist_hallucination_count",
}


def load_json(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    temporary.replace(path)


def audio_digest(path: Path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def text_digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def required_text(value, field, sample_id):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"样本 {sample_id} 的 {field} 必须是非空字符串")
    return value


def required_number(value, field, sample_id):
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        or value < 0
    ):
        raise ValueError(f"样本 {sample_id} 的 {field} 必须是有限非负数")
    return value


def required_integer(value, field, sample_id):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"样本 {sample_id} 的 {field} 必须是非负整数")
    return value


def required_boolean(value, field, sample_id):
    if not isinstance(value, bool):
        raise ValueError(f"样本 {sample_id} 的 {field} 必须是布尔值")
    return value


def validate_dal_metrics(item, sample_id):
    if not isinstance(item, dict) or not REQUIRED_DAL_METRICS.issubset(item):
        return False
    validate_route(item["route"], sample_id)
    required_number(item["latency_ms"], "latency_ms", sample_id)
    call_count = required_integer(item["call_count"], "call_count", sample_id)
    repair_used = required_boolean(item["repair_used"], "repair_used", sample_id)
    fallback_used = required_boolean(item["fallback_used"], "fallback_used", sample_id)
    minimum_calls = BASE_ROUTE_CALL_COUNTS[item["route"]]
    maximum_calls = MAXIMUM_ROUTE_CALL_COUNTS[item["route"]]
    minimum_allowed_calls = 0 if fallback_used else minimum_calls
    if not minimum_allowed_calls <= call_count <= maximum_calls:
        raise ValueError(
            f"样本 {sample_id} 的 {item['route']} route 调用数必须在 "
            f"{minimum_allowed_calls} 到 {maximum_calls} 之间"
        )
    if repair_used != (call_count > minimum_calls):
        raise ValueError(f"样本 {sample_id} 的 repair_used 与 route/call_count 不一致")
    for field in (
        "confirmed_alias_total",
        "confirmed_alias_correct",
        "critical_fact_total",
        "critical_fact_preserved",
        "whitelist_hallucination_count",
    ):
        required_integer(item[field], field, sample_id)
    if item["confirmed_alias_correct"] > item["confirmed_alias_total"]:
        raise ValueError(f"样本 {sample_id} 的 confirmed_alias_correct 不能大于 total")
    if item["critical_fact_preserved"] > item["critical_fact_total"]:
        raise ValueError(f"样本 {sample_id} 的 critical_fact_preserved 不能大于 total")
    return True


def category_coverage(categories):
    counts = {category: categories.count(category) for category in REQUIRED_CATEGORIES}
    return {
        "required": {
            category: {"sample_count": count, "passed": count >= 1}
            for category, count in counts.items()
        },
        "passed": all(count >= 1 for count in counts.values()),
    }


def finite_duration(value, sample_id):
    try:
        duration = float(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"样本 {sample_id} 无法取得有效音频时长") from error
    if not math.isfinite(duration) or duration < MINIMUM_AUDIO_DURATION_SECONDS:
        raise ValueError(
            f"样本 {sample_id} 的可解码音频时长必须至少为 "
            f"{MINIMUM_AUDIO_DURATION_SECONDS:.1f} 秒，实际为 {duration!r} 秒"
        )
    return round(duration, 6)


def probe_audio_with_ffprobe(path: Path, sample_id, executable):
    result = subprocess.run(
        [
            executable,
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries",
            "stream=codec_name,sample_rate,channels",
            "-of", "json",
            str(path),
        ],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip().splitlines()
        suffix = f": {detail[-1]}" if detail else ""
        raise ValueError(f"样本 {sample_id} 不是可解码音频{suffix}")
    try:
        payload = json.loads(result.stdout)
        stream = payload["streams"][0]
    except (IndexError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise ValueError(f"样本 {sample_id} 不包含可解码音频流") from error
    codec = str(stream.get("codec_name", "")).strip()
    if not codec:
        raise ValueError(f"样本 {sample_id} 无法取得音频 codec")
    return {
        "probe": "ffprobe",
        "codec": codec,
        "sample_rate_hz": int(stream.get("sample_rate", 0)),
        "channels": int(stream.get("channels", 0)),
    }


def probe_audio_with_afinfo(path: Path, sample_id, executable):
    result = subprocess.run(
        [executable, str(path)],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise ValueError(f"样本 {sample_id} 不是可解码音频")
    duration_match = re.search(
        r"estimated duration:\s*([^\s]+)\s*sec", result.stdout, re.IGNORECASE
    )
    format_match = re.search(r"^Data format:\s*(.+)$", result.stdout, re.MULTILINE)
    if duration_match is None or format_match is None:
        raise ValueError(f"样本 {sample_id} 无法取得稳定音频媒体信息")
    return {
        "probe": "afinfo",
        "codec": format_match.group(1).strip(),
        "container_duration_seconds": finite_duration(duration_match.group(1), sample_id),
    }


def canonical_pcm_with_ffmpeg(path: Path, sample_id, executable):
    result = subprocess.run(
        [
            executable,
            "-nostdin",
            "-v", "error",
            "-i", str(path),
            "-map", "0:a:0",
            "-ac", "1",
            "-ar", str(CANONICAL_AUDIO_SAMPLE_RATE),
            "-f", "s16le",
            "pipe:1",
        ],
        capture_output=True,
        timeout=120,
        check=False,
    )
    if result.returncode != 0 or not result.stdout:
        raise ValueError(f"样本 {sample_id} 不是可完整解码的音频")
    return result.stdout


def canonical_pcm_with_afconvert(path: Path, sample_id, executable):
    with tempfile.TemporaryDirectory(prefix="dal-blind-audio-") as directory:
        output = Path(directory) / "canonical.wav"
        result = subprocess.run(
            [
                executable,
                "-f", "WAVE",
                "-d", f"LEI16@{CANONICAL_AUDIO_SAMPLE_RATE}",
                "-c", "1",
                str(path),
                str(output),
            ],
            capture_output=True,
            timeout=120,
            check=False,
        )
        if result.returncode != 0 or not output.is_file():
            raise ValueError(f"样本 {sample_id} 不是可完整解码的音频")
        try:
            with wave.open(str(output), "rb") as handle:
                if (
                    handle.getnchannels() != 1
                    or handle.getframerate() != CANONICAL_AUDIO_SAMPLE_RATE
                    or handle.getsampwidth() != 2
                ):
                    raise ValueError(f"样本 {sample_id} 无法转换为统一 PCM")
                return handle.readframes(handle.getnframes())
        except (EOFError, wave.Error) as error:
            raise ValueError(f"样本 {sample_id} 无法读取统一 PCM") from error


def canonical_pcm(path: Path, sample_id):
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is not None:
        return canonical_pcm_with_ffmpeg(path, sample_id, ffmpeg)
    afconvert = shutil.which("afconvert")
    if afconvert is not None:
        return canonical_pcm_with_afconvert(path, sample_id, afconvert)
    raise ValueError("无法验证音频内容：找不到 ffmpeg 或 macOS afconvert")


def canonical_pcm_wave_fast_path(path: Path, sample_id):
    try:
        with wave.open(str(path), "rb") as handle:
            if (
                handle.getcomptype() != "NONE"
                or handle.getnchannels() != 1
                or handle.getframerate() != CANONICAL_AUDIO_SAMPLE_RATE
                or handle.getsampwidth() != 2
            ):
                return None
            frame_count = handle.getnframes()
            pcm = handle.readframes(frame_count)
    except (EOFError, wave.Error):
        return None
    if len(pcm) != frame_count * 2:
        raise ValueError(f"样本 {sample_id} 的 PCM WAV 数据不完整")
    return pcm, {
        "probe": "python_wave",
        "codec": "pcm_s16le",
        "sample_rate_hz": CANONICAL_AUDIO_SAMPLE_RATE,
        "channels": 1,
    }


def probe_audio(path: Path, sample_id):
    wave_result = canonical_pcm_wave_fast_path(path, sample_id)
    if wave_result is not None:
        pcm, media = wave_result
    else:
        pcm = canonical_pcm(path, sample_id)
        ffprobe = shutil.which("ffprobe")
        if ffprobe is not None:
            media = probe_audio_with_ffprobe(path, sample_id, ffprobe)
        else:
            afinfo = shutil.which("afinfo")
            if afinfo is None:
                raise ValueError("无法验证音频媒体信息：找不到 ffprobe 或 macOS afinfo")
            media = probe_audio_with_afinfo(path, sample_id, afinfo)
    if len(pcm) % 2 != 0:
        raise ValueError(f"样本 {sample_id} 的统一 PCM 数据损坏")
    decoded_sample_count = len(pcm) // 2
    decoded_duration = finite_duration(
        decoded_sample_count / CANONICAL_AUDIO_SAMPLE_RATE, sample_id
    )
    return {
        **media,
        "duration_seconds": decoded_duration,
        "canonical_sample_rate_hz": CANONICAL_AUDIO_SAMPLE_RATE,
        "canonical_channels": 1,
        "decoded_sample_count": decoded_sample_count,
        "pcm_sha256": hashlib.sha256(pcm).hexdigest(),
    }


def resolve_audio_ref(value, base_directory: Path, sample_id):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"样本 {sample_id} 的 audio_ref 不能为空")
    reference = value.strip()
    if "://" in reference:
        raise ValueError(f"样本 {sample_id} 的 audio_ref 仅支持本地文件: {reference}")
    path = Path(reference).expanduser()
    if not path.is_absolute():
        path = base_directory / path
    try:
        resolved = path.resolve(strict=True)
    except FileNotFoundError as error:
        raise ValueError(f"样本 {sample_id} 的音频文件不存在: {reference}") from error
    if not resolved.is_file():
        raise ValueError(f"样本 {sample_id} 的 audio_ref 不是文件: {reference}")
    return resolved


def validated_sample_audio(sample, base_directory: Path, sample_id, media_cache):
    shared_path = resolve_audio_ref(sample.get("audio_ref"), base_directory, sample_id)
    for field in ("dal_audio_ref", "typeless_audio_ref"):
        if field not in sample:
            continue
        side_path = resolve_audio_ref(sample.get(field), base_directory, sample_id)
        if side_path != shared_path:
            raise ValueError(f"样本 {sample_id} 的 Dal 与 Typeless 必须共用同一音频来源")
    cached = media_cache.get(shared_path)
    if cached is None:
        cached = (audio_digest(shared_path), probe_audio(shared_path, sample_id))
        media_cache[shared_path] = cached
    return shared_path, cached[0], cached[1]


def validated_sample_id(sample):
    raw_id = sample.get("id")
    if not isinstance(raw_id, str) or not raw_id.strip():
        raise ValueError("样本 ID 必须是非空字符串")
    return raw_id.strip()


def validate_route(route, sample_id):
    if not isinstance(route, str) or route not in ALLOWED_ROUTES:
        allowed = ", ".join(sorted(ALLOWED_ROUTES))
        raise ValueError(f"样本 {sample_id} 的 route 无效: {route!r}；仅允许 {allowed}")


def require_unique_audio(digest, sample_id, audio_owner_by_digest):
    previous_sample_id = audio_owner_by_digest.get(digest)
    if previous_sample_id is not None:
        raise ValueError(
            f"样本 {sample_id} 与 {previous_sample_id} 使用了相同音频内容，"
            f"至少需要 {MINIMUM_SAMPLE_COUNT} 条唯一音频证据"
        )
    audio_owner_by_digest[digest] = sample_id


def prepare(args):
    input_path = Path(args.input)
    source = load_json(input_path)
    samples = source["samples"] if isinstance(source, dict) else source
    if len(samples) < MINIMUM_SAMPLE_COUNT:
        raise ValueError(f"同音频人工盲测至少需要 {MINIMUM_SAMPLE_COUNT} 条样本")
    rng = random.Random(args.seed) if args.seed is not None else secrets.SystemRandom()
    dal_left_count = len(samples) // 2
    dal_side_assignments = [True] * dal_left_count + [False] * (
        len(samples) - dal_left_count
    )
    rng.shuffle(dal_side_assignments)
    public_samples = []
    key_samples = []
    seen = set()
    audio_owner_by_digest = {}
    media_cache = {}
    categories = []
    for sample, dal_on_left in zip(samples, dal_side_assignments):
        sample_id = validated_sample_id(sample)
        if sample_id in seen:
            raise ValueError(f"重复样本 ID: {sample_id}")
        seen.add(sample_id)
        category = required_text(sample.get("category"), "category", sample_id).strip()
        reference_transcript = required_text(
            sample.get("reference_transcript", sample.get("input")),
            "reference_transcript",
            sample_id,
        )
        dal = required_text(
            sample.get("dal_output", sample.get("new_output")), "dal_output", sample_id
        )
        typeless = required_text(
            sample.get("typeless_output", sample.get("legacy_output")),
            "typeless_output",
            sample_id,
        )
        dal_metrics = sample.get("dal_metrics")
        validate_dal_metrics(dal_metrics, sample_id)
        typeless_latency = sample.get("typeless_latency_ms")
        if typeless_latency is not None:
            required_number(typeless_latency, "typeless_latency_ms", sample_id)
        audio_path, audio_sha256, audio_probe = validated_sample_audio(
            sample, input_path.parent, sample_id, media_cache
        )
        require_unique_audio(audio_probe["pcm_sha256"], sample_id, audio_owner_by_digest)
        left = dal if dal_on_left else typeless
        right = typeless if dal_on_left else dal
        categories.append(category)
        public_samples.append({
            "id": sample_id,
            "audio_ref": str(audio_path),
            "audio_probe": audio_probe,
            "category": category,
            "reference_transcript": reference_transcript,
            "left": left,
            "right": right,
            "ratings": {dimension: None for dimension in RATING_DIMENSIONS},
        })
        key_samples.append({
            "id": sample_id,
            "audio_ref": str(audio_path),
            "audio_sha256": audio_sha256,
            "audio_probe": audio_probe,
            "category": category,
            "reference_transcript_sha256": text_digest(reference_transcript),
            "left_output_sha256": text_digest(left),
            "right_output_sha256": text_digest(right),
            "dal_side": "left" if dal_on_left else "right",
            "dal_metrics": dal_metrics,
            "typeless_latency_ms": typeless_latency,
        })

    baseline_commit = required_text(args.baseline_commit, "baseline_commit", "metadata").strip()
    public_metadata = {
        "schema_version": 3,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "baseline_commit": baseline_commit,
        "sample_count": len(samples),
        "rating_options": ["left", "right", "tie", "both_unusable"],
        "rating_dimensions": list(RATING_DIMENSIONS),
        "comparison": "Dal Voice Polish vs Typeless（同一音频、匿名随机左右）",
        "category_coverage": category_coverage(categories),
    }
    key_metadata = {
        **public_metadata,
        "randomization": "system_random",
        "dal_side_counts": {
            "left": dal_left_count,
            "right": len(samples) - dal_left_count,
        },
    }
    if args.seed is not None:
        key_metadata["randomization"] = "seeded_test_only"
        key_metadata["seed"] = args.seed
    write_json(Path(args.output), {"metadata": public_metadata, "samples": public_samples})
    write_json(Path(args.key), {"metadata": key_metadata, "samples": key_samples})


def score(args):
    evaluation_path = Path(args.evaluation)
    key_path = Path(args.key)
    evaluation = load_json(evaluation_path)
    key = load_json(key_path)
    evaluation_metadata = evaluation.get("metadata") or {}
    key_metadata = key.get("metadata") or {}
    baseline_commit = required_text(
        key_metadata.get("baseline_commit"), "baseline_commit", "metadata"
    ).strip()
    evaluation_baseline_commit = required_text(
        evaluation_metadata.get("baseline_commit"), "baseline_commit", "metadata"
    ).strip()
    if evaluation_baseline_commit != baseline_commit:
        raise ValueError("公开评测与盲测密钥的 baseline_commit 不一致")
    evaluation_samples = evaluation["samples"]
    key_samples = key["samples"]
    if len(evaluation_samples) < MINIMUM_SAMPLE_COUNT or len(key_samples) < MINIMUM_SAMPLE_COUNT:
        raise ValueError(f"同音频人工盲测至少需要 {MINIMUM_SAMPLE_COUNT} 条样本")

    key_by_id = {}
    key_audio_owner_by_digest = {}
    actual_side_counts = {"left": 0, "right": 0}
    media_cache = {}
    for item in key_samples:
        sample_id = validated_sample_id(item)
        if sample_id in key_by_id:
            raise ValueError(f"盲测密钥中存在重复样本 ID: {sample_id}")
        dal_side = item.get("dal_side")
        if dal_side not in actual_side_counts:
            raise ValueError(f"样本 {sample_id} 的 dal_side 无效")
        actual_side_counts[dal_side] += 1
        validate_dal_metrics(item.get("dal_metrics"), sample_id)
        typeless_latency = item.get("typeless_latency_ms")
        if typeless_latency is not None:
            required_number(typeless_latency, "typeless_latency_ms", sample_id)
        audio_path, audio_sha256, audio_probe = validated_sample_audio(
            item, key_path.parent, sample_id, media_cache
        )
        if item.get("audio_sha256") != audio_sha256:
            raise ValueError(f"样本 {sample_id} 的音频文件与准备阶段证据不一致")
        if item.get("audio_probe") != audio_probe:
            raise ValueError(f"样本 {sample_id} 的音频媒体信息与准备阶段证据不一致")
        require_unique_audio(audio_probe["pcm_sha256"], sample_id, key_audio_owner_by_digest)
        key_by_id[sample_id] = {
            **item,
            "validated_audio_path": audio_path,
            "validated_audio_sha256": audio_sha256,
            "validated_audio_probe": audio_probe,
        }

    evaluation_ids = set()
    evaluation_audio_owner_by_digest = {}
    evaluation_categories = []
    for item in evaluation_samples:
        sample_id = validated_sample_id(item)
        if sample_id in evaluation_ids:
            raise ValueError(f"评测文件中存在重复样本 ID: {sample_id}")
        evaluation_ids.add(sample_id)
        key_item = key_by_id.get(sample_id)
        if key_item is None:
            raise ValueError(f"评测样本 {sample_id} 在盲测密钥中不存在")
        category = required_text(item.get("category"), "category", sample_id).strip()
        reference_transcript = required_text(
            item.get("reference_transcript"), "reference_transcript", sample_id
        )
        left = required_text(item.get("left"), "left", sample_id)
        right = required_text(item.get("right"), "right", sample_id)
        if (
            category != key_item.get("category")
            or text_digest(reference_transcript)
            != key_item.get("reference_transcript_sha256")
            or text_digest(left) != key_item.get("left_output_sha256")
            or text_digest(right) != key_item.get("right_output_sha256")
        ):
            raise ValueError(f"样本 {sample_id} 的固定评测内容在准备后被修改")
        audio_path, audio_sha256, audio_probe = validated_sample_audio(
            item, evaluation_path.parent, sample_id, media_cache
        )
        if (
            audio_path != key_item["validated_audio_path"]
            or audio_sha256 != key_item["validated_audio_sha256"]
            or audio_probe != key_item["validated_audio_probe"]
            or item.get("audio_probe") != audio_probe
        ):
            raise ValueError(f"样本 {sample_id} 的公开评测与盲测密钥未共用同一音频来源")
        require_unique_audio(
            audio_probe["pcm_sha256"], sample_id, evaluation_audio_owner_by_digest
        )
        evaluation_categories.append(category)
    if evaluation_ids != set(key_by_id):
        raise ValueError("公开评测与盲测密钥的样本集合不一致")
    coverage = category_coverage(evaluation_categories)
    if (evaluation.get("metadata") or {}).get("category_coverage") != coverage:
        raise ValueError("公开评测的 category 覆盖信息在准备后被修改")

    counts_by_dimension = {
        dimension: {"dal_win": 0, "typeless_win": 0, "tie": 0, "both_unusable": 0}
        for dimension in RATING_DIMENSIONS
    }
    missing = []
    for sample in evaluation_samples:
        sample_id = sample["id"]
        ratings = sample.get("ratings") or {}
        dal_side = (key_by_id.get(sample_id) or {}).get("dal_side")
        for dimension in RATING_DIMENSIONS:
            rating = ratings.get(dimension)
            if rating not in ALLOWED_RATINGS or dal_side not in {"left", "right"}:
                missing.append(f"{sample_id}:{dimension}")
                continue
            if rating == "tie":
                counts_by_dimension[dimension]["tie"] += 1
            elif rating == "both_unusable":
                counts_by_dimension[dimension]["both_unusable"] += 1
            elif rating == dal_side:
                counts_by_dimension[dimension]["dal_win"] += 1
            else:
                counts_by_dimension[dimension]["typeless_win"] += 1
    if missing:
        raise ValueError("以下样本尚未填写有效评分: " + ", ".join(missing))

    dimension_reports = {}
    for dimension, counts in counts_by_dimension.items():
        total = sum(counts.values())
        dimension_reports[dimension] = {
            "counts": counts,
            "dal_win_or_tie_rate": ratio(counts["dal_win"] + counts["tie"], total),
            "dal_loss_rate": ratio(counts["typeless_win"], total),
            "both_unusable_rate": ratio(counts["both_unusable"], total),
        }

    metrics = engineering_metrics(key_samples)
    total = sum(counts_by_dimension["overall"].values())
    overall = dimension_reports["overall"]
    manual_gate = (
        total >= MINIMUM_SAMPLE_COUNT
        and overall["dal_win_or_tie_rate"] >= 0.85
        and overall["dal_loss_rate"] <= 0.15
        and overall["both_unusable_rate"] <= 0.01
    )
    engineering_gate = metrics["complete"] and all((
        metrics["confirmed_alias_correction_rate"] == 1.0,
        metrics["whitelist_hallucination_count"] == 0,
        metrics["critical_fact_retention_rate"] == 1.0,
        metrics["single_call_rate"] >= 0.85,
        metrics["repair_rate"] <= 0.02,
        metrics["fallback_rate"] <= 0.01,
        metrics["latency_targets_passed"],
    ))
    sides_balanced = abs(actual_side_counts["left"] - actual_side_counts["right"]) <= 1
    randomization_gate = (
        key_metadata.get("randomization") == "system_random"
        and key_metadata.get("dal_side_counts") == actual_side_counts
        and sides_balanced
    )
    report = {
        "schema_version": 3,
        "scored_at": datetime.now(timezone.utc).isoformat(),
        "baseline_commit": baseline_commit,
        "sample_count": total,
        "dimensions": dimension_reports,
        "engineering_metrics": metrics,
        "category_coverage": coverage,
        "targets": {
            "minimum_samples": MINIMUM_SAMPLE_COUNT,
            "dal_win_or_tie_rate": 0.85,
            "maximum_dal_loss_rate": 0.15,
            "maximum_both_unusable_rate": 0.01,
        },
        "manual_gate_passed": manual_gate,
        "engineering_gate_passed": engineering_gate,
        "category_coverage_passed": coverage["passed"],
        "randomization_gate_passed": randomization_gate,
        "product_ready": (
            manual_gate and engineering_gate and coverage["passed"] and randomization_gate
        ),
    }
    write_json(Path(args.output), report)


def ratio(numerator, denominator):
    return numerator / denominator if denominator else 0


def percentile(values, probability):
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * probability) - 1))
    return ordered[index]


def engineering_metrics(key_samples):
    complete = True
    dal_metrics = []
    typeless_latencies = []
    for sample in key_samples:
        item = sample.get("dal_metrics")
        if not validate_dal_metrics(item, sample.get("id", "")):
            complete = False
            continue
        typeless_latency = sample.get("typeless_latency_ms")
        if typeless_latency is None:
            complete = False
        else:
            typeless_latencies.append(
                required_number(typeless_latency, "typeless_latency_ms", sample.get("id", ""))
            )
        dal_metrics.append(item)

    alias_total = sum(item["confirmed_alias_total"] for item in dal_metrics)
    alias_correct = sum(item["confirmed_alias_correct"] for item in dal_metrics)
    fact_total = sum(item["critical_fact_total"] for item in dal_metrics)
    fact_preserved = sum(item["critical_fact_preserved"] for item in dal_metrics)
    if alias_total <= 0 or fact_total <= 0 or len(dal_metrics) != len(key_samples):
        complete = False

    latency_by_route = {}
    latency_targets_passed = complete
    latency_targets = {
        "fast": {"p50": 1_500, "p95": 3_000},
        "structured": {"p50": 2_500, "p95": 5_000},
        "deep": {"p50": 5_000, "p95": 8_000},
    }
    for route, targets in latency_targets.items():
        values = [item["latency_ms"] for item in dal_metrics if item["route"] == route]
        p50 = percentile(values, 0.50)
        p95 = percentile(values, 0.95)
        minimum_sample_count = MINIMUM_ROUTE_SAMPLE_COUNTS[route]
        passed = (
            len(values) >= minimum_sample_count
            and p50 <= targets["p50"]
            and p95 <= targets["p95"]
        )
        latency_targets_passed = latency_targets_passed and passed
        latency_by_route[route] = {
            "sample_count": len(values),
            "minimum_sample_count": minimum_sample_count,
            "p50_ms": p50,
            "p95_ms": p95,
            "target_p50_ms": targets["p50"],
            "target_p95_ms": targets["p95"],
            "passed": passed,
        }

    automatic_sample_count = len(dal_metrics)
    llm_request_items = [item for item in dal_metrics if item["call_count"] > 0]
    llm_request_sample_count = len(llm_request_items)
    return {
        "complete": complete,
        "confirmed_alias_correction_rate": ratio(alias_correct, alias_total),
        "whitelist_hallucination_count": sum(
            item["whitelist_hallucination_count"] for item in dal_metrics
        ),
        "critical_fact_retention_rate": ratio(fact_preserved, fact_total),
        "automatic_sample_count": automatic_sample_count,
        "llm_request_sample_count": llm_request_sample_count,
        "single_call_rate": ratio(
            sum(item["call_count"] == 1 for item in llm_request_items),
            llm_request_sample_count,
        ),
        "repair_rate": ratio(
            sum(item["repair_used"] for item in llm_request_items),
            llm_request_sample_count,
        ),
        "fallback_rate": ratio(
            sum(item["fallback_used"] for item in dal_metrics), automatic_sample_count
        ),
        "latency_by_route": latency_by_route,
        "latency_targets_passed": latency_targets_passed,
        "typeless_latency_p50_ms": percentile(typeless_latencies, 0.50),
        "typeless_latency_p95_ms": percentile(typeless_latencies, 0.95),
    }


def parser():
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--input", required=True)
    prepare_parser.add_argument("--output", required=True)
    prepare_parser.add_argument("--key", required=True)
    prepare_parser.add_argument("--seed", type=int)
    prepare_parser.add_argument("--baseline-commit", required=True)
    prepare_parser.set_defaults(function=prepare)

    score_parser = commands.add_parser("score")
    score_parser.add_argument("--evaluation", required=True)
    score_parser.add_argument("--key", required=True)
    score_parser.add_argument("--output", required=True)
    score_parser.set_defaults(function=score)
    return root


if __name__ == "__main__":
    arguments = parser().parse_args()
    arguments.function(arguments)
