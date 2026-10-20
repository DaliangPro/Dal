#!/usr/bin/env python3
"""校验 Dal 语音润色核心语义测试集的身份、来源和盲测边界。"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "docs/2026-08-17-Dal-Voice-Polish-Quality-Test-Set.json"
CORE = ROOT / "docs/2026-08-17-Dal-Voice-Polish-Core-Semantic-Test-Set.json"

EXPECTED_SCHEMA_VERSION = 2
EXPECTED_NAME = "Dal 语音润色核心语义测试集 V2"
EXPECTED_IDS = [
    "micro-02",
    "micro-04",
    "micro-05",
    "micro-11",
    "chat-03",
    "chat-05",
    "work-02",
    "work-03",
    "email-03",
    "social-05",
    "support-04",
    "support-05-stutter-01",
    "context-03",
    "context-09",
    "context-11",
    "context-17",
    "prompt-02-noise-01",
    "code-01",
    "code-03",
    "code-05",
    "natural-long-02",
    "natural-long-05",
    "natural-long-06",
    "natural-long-09-asr-dirty-segments-1",
    "natural-long-10-asr-dirty-segments-2",
]
STRESS_BOUNDARY_IDS = {
    "natural-long-09-asr-dirty-segments-1",
    "natural-long-10-asr-dirty-segments-2",
}

INPUT_KEYS = {
    "test_input_id",
    "source_case_id",
    "input_kind",
    "acceptance_tier",
    "title",
    "writing_scene",
    "spoken_input",
    "segment_texts",
    "context_type",
    "context_fixture",
    "requires_transformation",
    "semantic_contract",
}
CONTRACT_KEYS = {
    "primary_boundary",
    "final_intent",
    "must_preserve",
    "must_resolve",
    "must_not_add",
    "acceptable_variations",
    "major_error_if",
}
FORBIDDEN_ANSWER_KEYS = {
    "reference_output",
    "automatic_checks",
    "factor_assertions",
    "required_substrings",
    "required_claim_groups",
    "required_fact_groups",
    "forbidden_substrings",
    "forbidden_context_substrings",
}


def fail(message: str) -> None:
    raise SystemExit(f"FAIL：{message}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        fail(f"文件不存在、非普通文件或是符号链接：{path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"无法解析 JSON {path}：{error}")
    if not isinstance(value, dict):
        fail(f"顶层必须是 JSON 对象：{path}")
    return value


def assert_nonempty_strings(value: Any, label: str) -> None:
    if not isinstance(value, list) or not value:
        fail(f"{label} 必须是非空数组")
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item.strip():
            fail(f"{label}[{index}] 必须是非空字符串")


def main() -> None:
    source = load_json(SOURCE)
    core = load_json(CORE)

    if core.get("schema_version") != EXPECTED_SCHEMA_VERSION:
        fail("核心集 schema_version 不正确")
    if core.get("name") != EXPECTED_NAME:
        fail("核心集 name 不正确")
    if core.get("source_dataset") != SOURCE.name:
        fail("核心集未指向冻结母集")
    if core.get("source_dataset_sha256") != sha256(SOURCE):
        fail("核心集记录的母集 SHA-256 与当前母集不一致")

    rules = core.get("rules")
    if not isinstance(rules, dict):
        fail("缺少盲测规则")
    for key in (
        "reference_output_is_not_a_unique_answer",
        "writer_must_not_receive_semantic_contract",
        "blind_review_hides_model_identity",
    ):
        if rules.get(key) is not True:
            fail(f"盲测规则 {key} 必须为 true")
    if rules.get("primary_case_count") != 23:
        fail("日常主验收样本必须固定为 23 条")
    if rules.get("stress_boundary_case_count") != 2:
        fail("压力边界样本必须固定为 2 条")
    if rules.get("primary_long_text_target_chars") != "700-1500":
        fail("日常长文本目标必须固定为 700-1500 字")

    inputs = core.get("inputs")
    if not isinstance(inputs, list):
        fail("inputs 必须是数组")
    if core.get("case_count") != len(EXPECTED_IDS) or len(inputs) != len(EXPECTED_IDS):
        fail(f"核心集必须为 {len(EXPECTED_IDS)} 条")
    actual_ids = [row.get("test_input_id") for row in inputs if isinstance(row, dict)]
    if actual_ids != EXPECTED_IDS:
        fail("核心集 ID 或顺序已变更")
    if len(set(actual_ids)) != len(actual_ids):
        fail("核心集存在重复 ID")

    source_rows = source.get("cases", []) + source.get("stress_variants", [])
    source_by_id = {row["id"]: row for row in source_rows}
    base_by_id = {row["id"]: row for row in source.get("cases", [])}

    for index, row in enumerate(inputs):
        if not isinstance(row, dict):
            fail(f"inputs[{index}] 必须是对象")
        test_id = row["test_input_id"]
        if set(row) != INPUT_KEYS:
            fail(f"{test_id} 字段与冻结 schema 不一致")
        forbidden = set(row) & FORBIDDEN_ANSWER_KEYS
        if forbidden:
            fail(f"{test_id} 泄漏参考答案字段：{sorted(forbidden)}")

        source_row = source_by_id.get(test_id)
        if source_row is None:
            fail(f"母集中缺少 {test_id}")
        base_case_id = source_row.get("base_case_id", test_id)
        base = base_by_id.get(base_case_id)
        if base is None:
            fail(f"母集中缺少 {test_id} 的基础样本 {base_case_id}")

        expected_values = {
            "source_case_id": base_case_id,
            "input_kind": "stress" if "base_case_id" in source_row else "base",
            "acceptance_tier": (
                "stress_boundary" if test_id in STRESS_BOUNDARY_IDS else "primary"
            ),
            "writing_scene": source_row.get("writing_scene", base["writing_scene"]),
            "spoken_input": source_row["spoken_input"],
            "segment_texts": source_row.get("segment_texts", base["segment_texts"]),
            "context_type": source_row.get(
                "context_type", base.get("context_type", "none")
            ),
            "context_fixture": source_row.get(
                "context_fixture", base.get("context_fixture")
            ),
            "requires_transformation": source_row.get(
                "requires_transformation", base.get("requires_transformation", True)
            ),
        }
        for key, expected in expected_values.items():
            if row.get(key) != expected:
                fail(f"{test_id}.{key} 与冻结母集不一致")
        if not isinstance(row.get("title"), str) or not row["title"].strip():
            fail(f"{test_id}.title 必须非空")
        if not isinstance(row["spoken_input"], str) or not row["spoken_input"].strip():
            fail(f"{test_id}.spoken_input 必须非空")
        if not isinstance(row["segment_texts"], list) or not row["segment_texts"]:
            fail(f"{test_id}.segment_texts 必须是非空数组")
        if any(not isinstance(text, str) or not text for text in row["segment_texts"]):
            fail(f"{test_id}.segment_texts 含空或非文本分段")

        semantic_contract = row.get("semantic_contract")
        if not isinstance(semantic_contract, dict):
            fail(f"{test_id}.semantic_contract 必须是对象")
        if set(semantic_contract) != CONTRACT_KEYS:
            fail(f"{test_id}.semantic_contract 字段与冻结 schema 不一致")
        if not isinstance(semantic_contract["primary_boundary"], str) or not semantic_contract[
            "primary_boundary"
        ].strip():
            fail(f"{test_id}.semantic_contract.primary_boundary 必须非空")
        for key in CONTRACT_KEYS - {"primary_boundary"}:
            assert_nonempty_strings(
                semantic_contract[key], f"{test_id}.semantic_contract.{key}"
            )

    long_lengths = sorted(
        len(row["spoken_input"])
        for row in inputs
        if len(row["spoken_input"]) >= 300
    )
    if len(long_lengths) < 5 or long_lengths[-1] < 7_500 or long_lengths[-2] < 5_500:
        fail("核心集未同时覆盖自然长文、6K 和近 8K 上边界")
    context_cases = [row for row in inputs if row["context_type"] != "none"]
    if len(context_cases) < 7:
        fail("核心集上下文样本少于 7 条")
    required_context_types = {
        "nearby_safe",
        "selected_safe",
        "recent_safe",
        "conflicting_safe",
        "secure_blocked",
        "unknown_blocked",
    }
    actual_context_types = {row["context_type"] for row in context_cases}
    if not required_context_types <= actual_context_types:
        fail("核心集上下文类型不完整")
    if sum(row["input_kind"] == "stress" for row in inputs) < 4:
        fail("核心集压力变体少于 4 条")

    print(f"PASS：核心语义测试集 {len(inputs)} 条校验通过")
    print(f"core_dataset_sha256={sha256(CORE)}")
    print(f"source_dataset_sha256={sha256(SOURCE)}")


if __name__ == "__main__":
    main()
