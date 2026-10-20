#!/usr/bin/env python3
"""从 25 条核心语义母集派生不含答案的正式 Runner 输入。"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DATASET = ROOT / "docs/2026-08-17-Dal-Voice-Polish-Core-Semantic-Test-Set.json"
FORBIDDEN_INPUT_FIELDS = {
    "acceptable_variations",
    "automatic_checks",
    "major_error_if",
    "must_not_add",
    "must_preserve",
    "must_resolve",
    "reference_output",
    "requires_transformation",
    "semantic_contract",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_dataset(path: Path) -> tuple[dict[str, Any], bytes]:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"核心母集不存在、不是常规文件或是符号链接：{path}")
    raw = path.read_bytes()
    value = json.loads(raw)
    if value.get("schema_version") != 2 or value.get("case_count") != 25:
        raise ValueError("核心母集身份错误，必须是 schema 2、25 条输入")
    inputs = value.get("inputs")
    if not isinstance(inputs, list) or len(inputs) != 25:
        raise ValueError("核心母集 inputs 数量不等于 25")
    return value, raw


def build_run_input(dataset: dict[str, Any], dataset_raw: bytes) -> dict[str, Any]:
    result: list[dict[str, Any]] = []
    seen: set[str] = set()
    for source in dataset["inputs"]:
        test_id = str(source["test_input_id"])
        if test_id in seen:
            raise ValueError(f"核心母集存在重复 ID：{test_id}")
        seen.add(test_id)
        item = {
            "test_input_id": test_id,
            "base_case_id": str(source["source_case_id"]),
            "input_kind": str(source["input_kind"]),
            "writing_scene": str(source["writing_scene"]),
            "spoken_input": str(source["spoken_input"]),
            "preconditions": [],
            "context_type": str(source["context_type"]),
            "segment_texts": list(source["segment_texts"]),
            "context_fixture": source.get("context_fixture"),
        }
        if FORBIDDEN_INPUT_FIELDS.intersection(item):
            raise AssertionError("派生输入意外包含评分契约")
        result.append(item)
    return {
        "schema_version": 1,
        "name": "Dal 语音润色核心语义 Runner 输入 V1",
        "source_dataset_sha256": sha256(dataset_raw),
        "requested_input_count": len(result),
        "inputs": result,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    dataset_path = arguments.dataset.resolve()
    output_path = arguments.output.resolve()
    dataset, dataset_raw = load_dataset(dataset_path)
    run_input = build_run_input(dataset, dataset_raw)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(
        run_input,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    ).encode("utf-8") + b"\n"
    output_path.write_bytes(encoded)
    output_path.chmod(0o600)
    print(
        f"PASS：已派生 {len(run_input['inputs'])} 条无答案 Runner 输入，"
        f"SHA-256={sha256(encoded)}"
    )


if __name__ == "__main__":
    main()
