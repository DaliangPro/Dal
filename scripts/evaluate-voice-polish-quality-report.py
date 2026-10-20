#!/usr/bin/env python3
"""对正式 Voice Polish 跑测报告执行可重复的硬性验收。"""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import plistlib
import re
import secrets
import subprocess
import unicodedata
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

from voice_polish_quality_checks import fact_group_is_preserved, relation_blocks


QUALITY_DATASET_SCHEMA_VERSION = 7
QUALITY_DATASET_NAME = "Dal 语音润色多维产品质量测试集 V3.2"
QUALITY_DATASET_CASE_COUNT = 89
QUALITY_DATASET_STRESS_VARIANT_COUNT = 41
QUALITY_DATASET_TOTAL_INPUT_COUNT = 130


def normalized(text: str) -> str:
    normalized_text = unicodedata.normalize("NFKC", text).replace("\r\n", "\n").replace("\r", "\n")
    return re.sub(r"[\t\f\v ]+", " ", normalized_text).strip()


def paragraph_count(text: str) -> int:
    return len([part for part in re.split(r"\n\s*\n", text.strip()) if part.strip()])


def list_item_count(text: str) -> int:
    pattern = re.compile(r"(?m)^\s*(?:\d{1,3}[.)、）]|[一二三四五六七八九十]{1,3}[、.)）]|[-*•])\s*")
    return len(pattern.findall(text))


ALLOWED_FACTOR_ASSERTION_KEYS = {
    "requires_transformation", "required_substrings", "forbidden_substrings",
    "required_order", "maximum_occurrences", "minimum_sentence_count",
    "minimum_list_item_count", "minimum_reference_length_ratio",
    "requires_terminal_punctuation", "maximum_input_segment_count",
    "minimum_internal_chunk_count",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_hex(value: str, length: int, label: str) -> str:
    normalized_value = value.strip().lower()
    if not re.fullmatch(rf"[0-9a-f]{{{length}}}", normalized_value):
        raise ValueError(f"{label} 必须是 {length} 位小写十六进制")
    return normalized_value


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def validated_quality_dataset(path: Path, expected_dataset_sha256: str) -> tuple[bytes, dict, str]:
    """把评分母集绑定到独立冻结值，并拒绝缩减或替换 130 条结构。"""
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"质量母测试集不存在、不是常规文件或是符号链接：{path}")
    expected_dataset_sha256 = validate_hex(
        expected_dataset_sha256, 64, "expected dataset SHA-256"
    )
    try:
        dataset_bytes = path.read_bytes()
    except OSError as error:
        raise ValueError(f"质量母测试集无法读取：{error}") from error
    actual_dataset_sha256 = hashlib.sha256(dataset_bytes).hexdigest()
    if actual_dataset_sha256 != expected_dataset_sha256:
        raise ValueError("质量母测试集 SHA-256 与外部冻结值不一致")
    try:
        document = json.loads(dataset_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"质量母测试集无法解析：{error}") from error
    if not isinstance(document, dict):
        raise ValueError("质量母测试集必须是 JSON 对象")
    if document.get("schema_version") != QUALITY_DATASET_SCHEMA_VERSION:
        raise ValueError(
            "质量母测试集 schema_version 不一致："
            f"{document.get('schema_version')!r}"
        )
    if document.get("name") != QUALITY_DATASET_NAME:
        raise ValueError(f"质量母测试集名称不一致：{document.get('name')!r}")
    cases = document.get("cases")
    variants = document.get("stress_variants")
    if not isinstance(cases, list) or not isinstance(variants, list):
        raise ValueError("质量母测试集缺少 cases 或 stress_variants 数组")
    actual_counts = (len(cases), len(variants), len(cases) + len(variants))
    expected_counts = (
        QUALITY_DATASET_CASE_COUNT,
        QUALITY_DATASET_STRESS_VARIANT_COUNT,
        QUALITY_DATASET_TOTAL_INPUT_COUNT,
    )
    declared_counts = (
        document.get("case_count"),
        document.get("stress_variant_count"),
        document.get("total_input_count"),
    )
    if actual_counts != expected_counts or declared_counts != expected_counts:
        raise ValueError(
            "质量母测试集必须固定为 89 条基准 + 41 条变体 = 130 次输入；"
            f"声明={declared_counts!r}，实际={actual_counts!r}"
        )
    return dataset_bytes, document, actual_dataset_sha256


def provider_request_binding_sha256(
    run_nonce: str,
    test_input_id: str,
    request_ordinal: int,
    request_body_sha256: str,
) -> str:
    """与网络层相同的无歧义字段绑定，独立验证每条请求属于本次样本。"""
    components = [
        run_nonce,
        test_input_id,
        str(request_ordinal),
        request_body_sha256,
    ]
    encoded = "|".join(
        f"{len(value.encode('utf-8'))}:{value}" for value in components
    )
    return sha256_text(f"muse-provider-audit-v2|{encoded}")


def validated_provider_endpoint(value: str) -> str:
    parsed = urlsplit(value)
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path.rstrip("/") != parsed.path
        or not parsed.path.endswith("/chat/completions")
    ):
        raise ValueError("expected Provider Endpoint 必须是最终 HTTPS /chat/completions 地址")
    hostname = parsed.hostname.lower()
    if hostname == "localhost":
        raise ValueError("真实 Provider 验收不允许 localhost Endpoint")
    try:
        endpoint_address = ipaddress.ip_address(hostname)
    except ValueError:
        endpoint_address = None
    if endpoint_address is not None and endpoint_address.is_loopback:
        raise ValueError("真实 Provider 验收不允许回环 Endpoint")
    return value


def validated_build_manifest(
    path: Path,
    *,
    expected_manifest_sha256: str,
    expected_source_commit: str,
    expected_source_tree: str,
    expected_executable_sha256: str,
    expected_dataset_sha256: str,
    expected_designated_requirement_sha256: str,
) -> dict:
    """只在 manifest 及其关键字段同时命中外部 expected 值时建立信任。"""
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"质量构建 manifest 不存在、不是常规文件或是符号链接：{path}")
    expected_manifest_sha256 = validate_hex(
        expected_manifest_sha256, 64, "expected manifest SHA-256"
    )
    expected_source_commit = validate_hex(expected_source_commit, 40, "expected source commit")
    expected_source_tree = validate_hex(expected_source_tree, 40, "expected source tree")
    expected_executable_sha256 = validate_hex(
        expected_executable_sha256, 64, "expected executable SHA-256"
    )
    expected_dataset_sha256 = validate_hex(
        expected_dataset_sha256, 64, "expected dataset SHA-256"
    )
    expected_designated_requirement_sha256 = validate_hex(
        expected_designated_requirement_sha256,
        64,
        "expected designated requirement SHA-256",
    )
    try:
        manifest_bytes = path.read_bytes()
        if hashlib.sha256(manifest_bytes).hexdigest() != expected_manifest_sha256:
            raise ValueError("质量构建 manifest SHA-256 与外部冻结值不一致")
        document = json.loads(manifest_bytes.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"质量构建 manifest 无法解析：{error}") from error
    if not isinstance(document, dict):
        raise ValueError("质量构建 manifest 必须是 JSON 对象")
    if document.get("schema_version") != 1:
        raise ValueError("质量构建 manifest schema_version 不是 1")
    if document.get("artifact_kind") != "dal_voice_polish_quality_candidate":
        raise ValueError("质量构建 manifest artifact_kind 无效")
    if document.get("package_mode") != "production":
        raise ValueError("质量验收只接受 production 打包阶段冻结的 manifest")
    if document.get("bundle_id") != "pro.daliang.muse":
        raise ValueError("质量构建 manifest Bundle ID 无效")
    expected_pairs = {
        "source_commit": expected_source_commit,
        "source_tree": expected_source_tree,
        "executable_sha256": expected_executable_sha256,
        "dataset_sha256": expected_dataset_sha256,
        "designated_requirement_sha256": expected_designated_requirement_sha256,
    }
    for field, expected_value in expected_pairs.items():
        if document.get(field) != expected_value:
            raise ValueError(f"质量构建 manifest 的 {field} 与外部冻结值不一致")
    requirement = document.get("designated_requirement")
    if not isinstance(requirement, str) or not requirement.strip():
        raise ValueError("质量构建 manifest 缺少 designated requirement")
    if sha256_text(requirement) != expected_designated_requirement_sha256:
        raise ValueError("manifest 内 designated requirement 的文本与其 SHA-256 不一致")
    return document


def designated_requirement(app_path: Path) -> str:
    result = subprocess.run(
        ["/usr/bin/codesign", "-dr", "-", str(app_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise ValueError(f"无法读取候选应用 designated requirement：{result.stdout.strip()}")
    for line in result.stdout.splitlines():
        if line.startswith("designated => ") or line.startswith("# designated => "):
            requirement = re.sub(r"^(?:# )?designated => ", "", line).strip()
            if requirement:
                return requirement
    raise ValueError("候选应用没有 designated requirement")


def candidate_app_evidence(app_path: Path) -> dict:
    """读取候选制品实际证据；其值只能与外部 manifest 比对，不能自证。"""
    if app_path.is_symlink() or not app_path.is_dir():
        raise ValueError(f"候选应用不存在、不是目录或是符号链接：{app_path}")
    info_path = app_path / "Contents" / "Info.plist"
    if not info_path.is_file() or info_path.is_symlink():
        raise ValueError(f"候选应用缺少可信 Info.plist：{info_path}")
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != "pro.daliang.muse":
        raise ValueError("候选应用 Bundle ID 不是 pro.daliang.muse")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or Path(executable_name).name != executable_name:
        raise ValueError("候选应用 CFBundleExecutable 无效")
    executable_path = app_path / "Contents" / "MacOS" / executable_name
    if not executable_path.is_file() or executable_path.is_symlink():
        raise ValueError(f"候选应用二进制不存在或是符号链接：{executable_path}")
    source_commit = info.get("DalSourceCommit")
    if not isinstance(source_commit, str) or not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise ValueError("候选应用缺少 40 位 DalSourceCommit")
    return {
        "executable_path": executable_path,
        "executable_sha256": sha256_file(executable_path),
        "source_commit": source_commit,
        "bundle_id": info["CFBundleIdentifier"],
        "designated_requirement": designated_requirement(app_path),
    }


def launch_candidate_run(
    executable_path: Path,
    run_input_path: Path,
    report_path: Path,
    provider_audit_path: Path,
    timeout_seconds: int,
) -> tuple[dict, str, int, datetime, datetime]:
    """由 evaluator 亲自启动候选进程，拒绝读取调用方预制报告。"""
    if report_path.exists() or report_path.is_symlink():
        raise ValueError(f"报告路径已存在，必须使用新的空路径：{report_path}")
    if provider_audit_path.exists() or provider_audit_path.is_symlink():
        raise ValueError(f"Provider 审计路径已存在，必须使用新的空路径：{provider_audit_path}")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    provider_audit_path.parent.mkdir(parents=True, exist_ok=True)
    with provider_audit_path.open("xb"):
        pass
    provider_audit_path.chmod(0o600)
    audit_stat = provider_audit_path.stat()
    audit_identity = (audit_stat.st_dev, audit_stat.st_ino)
    run_nonce = secrets.token_hex(32)
    started_at = datetime.now(timezone.utc)
    process = subprocess.Popen([
        str(executable_path),
        "--voice-polish-quality-run",
        "--run-input", str(run_input_path),
        "--report", str(report_path),
        "--provider-audit", str(provider_audit_path),
        "--run-nonce", run_nonce,
    ])
    try:
        return_code = process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired as error:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        raise ValueError(f"候选质量跑测超过 {timeout_seconds} 秒") from error
    finished_at = datetime.now(timezone.utc)
    if return_code != 0:
        raise ValueError(f"候选质量进程退出码为 {return_code}")
    if provider_audit_path.is_symlink() or not provider_audit_path.is_file():
        raise ValueError("候选进程替换或移除了 Evaluator 预建的 Provider 审计文件")
    final_audit_stat = provider_audit_path.stat()
    if (final_audit_stat.st_dev, final_audit_stat.st_ino) != audit_identity:
        raise ValueError("候选进程替换了 Evaluator 预建的 Provider 审计文件")
    if not report_path.is_file() or report_path.is_symlink():
        raise ValueError("候选进程没有生成常规报告文件")
    report_mtime = datetime.fromtimestamp(report_path.stat().st_mtime, timezone.utc)
    if report_mtime < started_at:
        raise ValueError("报告修改时间早于本次候选进程启动")
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"候选报告无法解析：{error}") from error
    return report, run_nonce, process.pid, started_at, finished_at


def semantic_length(text: str) -> int:
    return sum(character.isalnum() for character in unicodedata.normalize("NFKC", text))


def sentence_count(text: str) -> int:
    return max(1, len([
        part for part in re.split(r"[。！？!?；;]+", text)
        if part.strip()
    ]))


def contains_in_order(text: str, tokens: list[str]) -> bool:
    cursor = 0
    for token in tokens:
        location = text.find(token, cursor)
        if location < 0:
            return False
        cursor = location + len(token)
    return True


def canonical_input(fixture: dict) -> str:
    text = fixture["spoken_input"]
    for precondition in fixture.get("preconditions", []):
        if "→" not in precondition:
            continue
        alias, canonical = precondition.split("→", 1)
        if "已确认 " in alias:
            alias = alias.rsplit("已确认 ", 1)[1]
        alias = alias.strip()
        canonical = canonical.strip()
        if alias and canonical:
            text = text.replace(alias, canonical)
    return text


def flatten_dataset(document: dict) -> list[dict]:
    base_by_id = {item["id"]: item for item in document["cases"]}
    rows = []
    for item in document["cases"]:
        rows.append({
            **item,
            "base_case_id": item["id"],
            "input_kind": "base",
            "input_factors": [],
            "stutter_form": None,
        })
    for item in document["stress_variants"]:
        base = base_by_id[item["base_case_id"]]
        rows.append({
            **item,
            "writing_scene": base["writing_scene"],
            "reference_output": base["reference_output"],
            "must_preserve": base["must_preserve"],
            "must_remove": base["must_remove"],
            "must_not_invent": base["must_not_invent"],
            "preconditions": base.get("preconditions", []) + item.get("preconditions", []),
            "input_kind": "stress_variant",
        })
    return rows


RUNNER_FORBIDDEN_ANSWER_FIELDS = {
    "automatic_checks",
    "factor_assertions",
    "must_not_invent",
    "must_preserve",
    "must_remove",
    "quality_dimensions",
    "reference_output",
    "requires_transformation",
}


def build_runner_input_document(document: dict) -> dict:
    """只把生成请求必需的数据交给 Runner；答案与评分规则留在 evaluator。"""
    inputs = []
    for fixture in flatten_dataset(document):
        inputs.append({
            "test_input_id": fixture["id"],
            "base_case_id": fixture["base_case_id"],
            "input_kind": fixture["input_kind"],
            "writing_scene": fixture["writing_scene"],
            "spoken_input": fixture["spoken_input"],
            "preconditions": fixture.get("preconditions", []),
            "context_type": fixture["context_type"],
            "segment_texts": fixture["segment_texts"],
            "context_fixture": fixture.get("context_fixture"),
        })
    return {
        "schema_version": document["schema_version"],
        "name": document["name"],
        "inputs": inputs,
    }


def encoded_runner_input(document: dict) -> bytes:
    return (
        json.dumps(
            build_runner_input_document(document),
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")


def write_runner_input(document: dict, path: Path) -> tuple[Path, str]:
    """独占创建并保留运行输入，既防预置替换，也让独立 Agent 可复核。"""
    if path.exists() or path.is_symlink():
        raise ValueError(f"Runner 输入路径已存在，必须使用新的空路径：{path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    data = encoded_runner_input(document)
    with path.open("xb") as handle:
        handle.write(data)
    return path, hashlib.sha256(data).hexdigest()


def runtime_evidence_failures(result: dict) -> list[str]:
    """只返回运行链路硬失败；诊断码保留在报告中但不阻断质量验收。"""
    failures = []
    internal_chunk_count = result.get("internal_chunk_count")
    if (
        not isinstance(internal_chunk_count, int)
        or isinstance(internal_chunk_count, bool)
        or internal_chunk_count < 1
    ):
        failures.append(f"内部切片数无效：{internal_chunk_count!r}")

    llm_call_count = result.get("llm_call_count")
    if (
        not isinstance(llm_call_count, int)
        or isinstance(llm_call_count, bool)
        or llm_call_count < 1
    ):
        failures.append(f"没有真实 LLM 调用计数：{llm_call_count!r}")
    elif isinstance(internal_chunk_count, int) and not isinstance(internal_chunk_count, bool):
        if internal_chunk_count > 0 and llm_call_count < internal_chunk_count:
            failures.append(
                f"LLM 调用数 {llm_call_count} 少于内部切片数 {internal_chunk_count}"
            )

    llm_attempt_count = result.get("llm_attempt_count")
    if (
        not isinstance(llm_attempt_count, int)
        or isinstance(llm_attempt_count, bool)
        or llm_attempt_count < 1
    ):
        failures.append(f"没有有效 LLM 预算尝试计数：{llm_attempt_count!r}")
    elif isinstance(llm_call_count, int) and not isinstance(llm_call_count, bool):
        if llm_attempt_count < llm_call_count:
            failures.append(
                f"LLM 预算尝试数 {llm_attempt_count} 少于成功调用数 {llm_call_count}"
            )

    latency = result.get("latency_milliseconds")
    if not isinstance(latency, int) or isinstance(latency, bool) or latency < 1:
        failures.append(f"没有有效模型耗时：{latency!r}")

    hard_codes = result.get("hard_validation_codes")
    if not isinstance(hard_codes, list) or any(not isinstance(code, str) for code in hard_codes):
        failures.append(f"hard_validation_codes 不是字符串数组：{hard_codes!r}")
    elif hard_codes:
        failures.append(f"存在硬校验错误 {hard_codes}")

    diagnostic_codes = result.get("diagnostic_codes")
    if (
        not isinstance(diagnostic_codes, list)
        or any(not isinstance(code, str) for code in diagnostic_codes)
    ):
        failures.append(f"diagnostic_codes 不是字符串数组：{diagnostic_codes!r}")

    if "validation_codes" in result:
        failures.append("报告仍使用未区分硬失败与诊断项的 validation_codes")
    return failures


def read_provider_audit(path: Path) -> list[dict]:
    if path.is_symlink() or not path.is_file():
        raise ValueError("Provider 审计回执不存在、不是常规文件或是符号链接")
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as error:
        raise ValueError(f"Provider 审计回执无法读取：{error}") from error
    if not lines:
        raise ValueError("Provider 审计回执为空，没有任何可证明的真实请求")
    receipts = []
    for index, line in enumerate(lines, start=1):
        if not line.strip():
            raise ValueError(f"Provider 审计回执第 {index} 行为空")
        try:
            receipt = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"Provider 审计回执第 {index} 行无法解析：{error}") from error
        if not isinstance(receipt, dict):
            raise ValueError(f"Provider 审计回执第 {index} 行不是 JSON 对象")
        receipts.append(receipt)
    return receipts


def provider_audit_failures(
    receipts: list[dict],
    *,
    expected_run_nonce: str,
    expected_provider: str,
    expected_model: str,
    expected_endpoint_url: str,
    expected_test_ids: set[str],
    actual_by_id: dict[str, dict],
    run_started_at: datetime,
    run_finished_at: datetime,
) -> list[str]:
    failures: list[str] = []
    receipts_by_test_id: dict[str, list[dict]] = {}
    response_ids = set()
    allowed_tasks = {
        "voicePolishFast",
        "voicePolishStructured",
        "voicePolishAnalyze",
        "voicePolishRender",
        "voicePolishRepair",
    }

    for index, receipt in enumerate(receipts, start=1):
        prefix = f"Provider 回执第 {index} 条"
        test_id = receipt.get("test_input_id")
        if not isinstance(test_id, str) or test_id not in expected_test_ids:
            failures.append(f"{prefix}的 test_input_id 不属于本次冻结输入：{test_id!r}")
        else:
            receipts_by_test_id.setdefault(test_id, []).append(receipt)
        if receipt.get("schema_version") != 2:
            failures.append(f"{prefix}的 schema_version 不是 2")
        if receipt.get("run_nonce") != expected_run_nonce:
            failures.append(f"{prefix}的 run_nonce 与 Evaluator 本次启动值不一致")
        if receipt.get("provider") != expected_provider:
            failures.append(f"{prefix}的 Provider 不一致：{receipt.get('provider')!r}")
        if receipt.get("configured_model") != expected_model:
            failures.append(f"{prefix}的配置模型不一致：{receipt.get('configured_model')!r}")
        if receipt.get("response_model") != expected_model:
            failures.append(f"{prefix}的 Provider 响应模型不一致：{receipt.get('response_model')!r}")
        if receipt.get("endpoint_url") != expected_endpoint_url:
            failures.append(f"{prefix}的实际 Endpoint 不一致：{receipt.get('endpoint_url')!r}")
        if receipt.get("http_status") != 200:
            failures.append(f"{prefix}没有记录 HTTP 200：{receipt.get('http_status')!r}")
        if receipt.get("transport") not in {"stream", "nonstream"}:
            failures.append(f"{prefix}的 transport 无效：{receipt.get('transport')!r}")
        if receipt.get("llm_task") not in allowed_tasks:
            failures.append(f"{prefix}的 llm_task 不是 Voice Polish 任务：{receipt.get('llm_task')!r}")
        for field in ("request_body_sha256", "response_text_sha256"):
            if not isinstance(receipt.get(field), str) or not re.fullmatch(
                r"[0-9a-f]{64}", receipt[field]
            ):
                failures.append(f"{prefix}的 {field} 不是 64 位 SHA-256")
        request_ordinal = receipt.get("request_ordinal")
        if (
            not isinstance(request_ordinal, int)
            or isinstance(request_ordinal, bool)
            or request_ordinal < 1
        ):
            failures.append(f"{prefix}的 request_ordinal 不是正整数")
        request_binding = receipt.get("request_binding_sha256")
        if not isinstance(request_binding, str) or not re.fullmatch(
            r"[0-9a-f]{64}", request_binding
        ):
            failures.append(f"{prefix}的 request_binding_sha256 不是 64 位 SHA-256")
        elif (
            isinstance(test_id, str)
            and isinstance(request_ordinal, int)
            and not isinstance(request_ordinal, bool)
            and request_ordinal >= 1
            and isinstance(receipt.get("request_body_sha256"), str)
            and re.fullmatch(r"[0-9a-f]{64}", receipt["request_body_sha256"])
            and request_binding
            != provider_request_binding_sha256(
                expected_run_nonce,
                test_id,
                request_ordinal,
                receipt["request_body_sha256"],
            )
        ):
            failures.append(
                f"{prefix}的 request_binding_sha256 未绑定本次 nonce、样本、序号和请求体"
            )
        response_id = receipt.get("provider_response_id")
        if not isinstance(response_id, str) or not (1 <= len(response_id.encode("utf-8")) <= 512):
            failures.append(f"{prefix}缺少有效 Provider response ID")
        elif response_id in response_ids:
            failures.append(f"{prefix}复用了 Provider response ID：{response_id!r}")
        else:
            response_ids.add(response_id)
        try:
            recorded_at = datetime.fromisoformat(receipt["recorded_at"].replace("Z", "+00:00"))
            if recorded_at.tzinfo is None:
                recorded_at = recorded_at.replace(tzinfo=timezone.utc)
            if not (
                run_started_at.timestamp() - 2
                <= recorded_at.timestamp()
                <= run_finished_at.timestamp() + 2
            ):
                failures.append(f"{prefix}的 recorded_at 不在本次候选进程窗口内")
        except (KeyError, TypeError, ValueError, AttributeError):
            failures.append(f"{prefix}的 recorded_at 缺失或不是 ISO-8601 时间")

    for test_id in sorted(expected_test_ids):
        case_receipts = receipts_by_test_id.get(test_id, [])
        ordinals = [receipt.get("request_ordinal") for receipt in case_receipts]
        if ordinals != list(range(1, len(case_receipts) + 1)):
            failures.append(f"{test_id}: Provider 回执 request_ordinal 不是从 1 开始的连续序列：{ordinals!r}")
        reported_calls = actual_by_id.get(test_id, {}).get("llm_call_count")
        if not isinstance(reported_calls, int) or isinstance(reported_calls, bool):
            continue
        if len(case_receipts) != reported_calls:
            failures.append(
                f"{test_id}: 网络层 Provider 回执 {len(case_receipts)} 条，"
                f"与报告 llm_call_count={reported_calls} 不一致"
            )
    return failures


def add_failure(failures: list[str], test_id: str, message: str) -> None:
    failures.append(f"{test_id}: {message}")


def expected_context_fixture(fixture: dict) -> dict:
    """还原 Runner 写入报告的完整上下文夹具，包括显式 null。"""
    source = fixture.get("context_fixture") or {}
    return {
        "type": source.get("type", fixture["context_type"]),
        "level": source.get("level", "metadataOnly"),
        "safety": source.get("safety", "unknown"),
        "selected_text": source.get("selected_text"),
        "text_before_cursor": source.get("text_before_cursor"),
        "text_after_cursor": source.get("text_after_cursor"),
        "recent_muse_inputs": source.get("recent_muse_inputs", []),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--expected-provider", required=True)
    parser.add_argument("--expected-model", required=True)
    parser.add_argument("--expected-endpoint-url", required=True)
    parser.add_argument("--candidate-app", required=True, type=Path)
    parser.add_argument("--build-manifest", required=True, type=Path)
    parser.add_argument("--expected-build-manifest-sha256", required=True)
    parser.add_argument("--expected-source-commit", required=True)
    parser.add_argument("--expected-source-tree", required=True)
    parser.add_argument("--expected-executable-sha256", required=True)
    parser.add_argument("--expected-dataset-sha256", required=True)
    parser.add_argument("--expected-designated-requirement-sha256", required=True)
    parser.add_argument("--expected-prompt-version", required=True, type=int)
    parser.add_argument("--run-timeout-seconds", type=int, default=21_600)
    args = parser.parse_args()

    if args.run_timeout_seconds < 60:
        raise SystemExit("FAIL：--run-timeout-seconds 不能少于 60")
    try:
        validated_provider_endpoint(args.expected_endpoint_url)
    except ValueError as error:
        raise SystemExit(f"FAIL：{error}") from error

    failures: list[str] = []

    try:
        dataset_bytes, dataset, expected_dataset_sha256 = validated_quality_dataset(
            args.dataset,
            args.expected_dataset_sha256,
        )
        expected = flatten_dataset(dataset)
        build_manifest = validated_build_manifest(
            args.build_manifest,
            expected_manifest_sha256=args.expected_build_manifest_sha256,
            expected_source_commit=args.expected_source_commit,
            expected_source_tree=args.expected_source_tree,
            expected_executable_sha256=args.expected_executable_sha256,
            expected_dataset_sha256=expected_dataset_sha256,
            expected_designated_requirement_sha256=(
                args.expected_designated_requirement_sha256
            ),
        )
        candidate = candidate_app_evidence(args.candidate_app)
        expected_executable_sha256 = build_manifest["executable_sha256"]
        expected_commit = build_manifest["source_commit"]
        if candidate["executable_sha256"] != expected_executable_sha256:
            raise ValueError("候选二进制 SHA-256 与外部冻结值不一致")
        if candidate["source_commit"] != expected_commit:
            raise ValueError("候选 Info.plist 提交号与外部冻结值不一致")
        if candidate["bundle_id"] != build_manifest["bundle_id"]:
            raise ValueError("候选 Bundle ID 与外部冻结值不一致")
        if candidate["designated_requirement"] != build_manifest["designated_requirement"]:
            raise ValueError("候选 designated requirement 与外部冻结值不一致")
        if sha256_text(candidate["designated_requirement"]) != build_manifest[
            "designated_requirement_sha256"
        ]:
            raise ValueError("候选 designated requirement SHA-256 与外部冻结值不一致")
        signature = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=4", str(args.candidate_app)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if signature.returncode != 0:
            raise ValueError(f"候选应用严格签名验证失败：{signature.stdout.strip()}")
        runner_input_path = args.report.with_name(
            f"{args.report.stem}.runner-input.json"
        ).resolve(strict=False)
        runner_input_path, expected_run_input_sha256 = write_runner_input(
            dataset,
            runner_input_path,
        )
        provider_audit_path = args.report.with_name(
            f"{args.report.stem}.provider-audit.jsonl"
        ).resolve(strict=False)
        report, expected_run_nonce, expected_process_id, run_started_at, run_finished_at = (
            launch_candidate_run(
                executable_path=candidate["executable_path"],
                run_input_path=runner_input_path,
                report_path=args.report.resolve(strict=False),
                provider_audit_path=provider_audit_path,
                timeout_seconds=args.run_timeout_seconds,
            )
        )
        if sha256_file(candidate["executable_path"]) != expected_executable_sha256:
            raise ValueError("候选二进制在跑测期间发生变化")
        if sha256_file(args.build_manifest) != validate_hex(
            args.expected_build_manifest_sha256, 64, "expected manifest SHA-256"
        ):
            raise ValueError("外部构建 manifest 在跑测期间发生变化")
        if args.dataset.is_symlink() or not args.dataset.is_file():
            raise ValueError("质量母测试集在跑测期间被替换或移除")
        if sha256_file(args.dataset) != expected_dataset_sha256:
            raise ValueError("质量母测试集在跑测期间发生变化")
        provider_receipts = read_provider_audit(provider_audit_path)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise SystemExit(f"FAIL：候选应用真实跑测未完成：{error}") from error

    actual = report.get("cases", [])

    if report.get("schema_version") != 4:
        failures.append(f"报告 schema_version 不是 4：{report.get('schema_version')!r}")
    if report.get("run_nonce") != expected_run_nonce:
        failures.append("报告的一次性运行标识与 evaluator 启动值不一致")
    if report.get("process_id") != expected_process_id:
        failures.append("报告进程 ID 与 evaluator 实际启动进程不一致")
    try:
        report_run_at = datetime.fromisoformat(report["run_at"].replace("Z", "+00:00"))
        if report_run_at.tzinfo is None:
            report_run_at = report_run_at.replace(tzinfo=timezone.utc)
        if not (
            run_started_at.timestamp() - 2
            <= report_run_at.timestamp()
            <= run_finished_at.timestamp() + 2
        ):
            failures.append("报告 run_at 不在本次候选进程运行窗口内")
    except (KeyError, TypeError, ValueError, AttributeError):
        failures.append("报告 run_at 缺失或不是 ISO-8601 时间")
    if report.get("status") != "complete":
        failures.append(f"报告状态不是 complete：{report.get('status')}")
    if report.get("quality_mode") != "automatic":
        failures.append(f"跑测未使用唯一 automatic 模式：{report.get('quality_mode')}")
    if report.get("run_input_name") != dataset.get("name"):
        failures.append("报告与本次无答案运行输入名称不一致")
    if report.get("run_input_schema_version") != dataset.get("schema_version"):
        failures.append("报告与本次无答案运行输入 schema_version 不一致")
    if report.get("run_input_sha256") != expected_run_input_sha256:
        failures.append("报告中的运行输入 SHA-256 与 evaluator 派生文件不一致")
    if report.get("executable_sha256") != expected_executable_sha256:
        failures.append("报告中的候选二进制 SHA-256 与独立计算结果不一致")
    if report.get("commit") != expected_commit:
        failures.append(f"候选 commit 不一致：{report.get('commit')!r}")
    if report.get("provider") != args.expected_provider:
        failures.append(f"Provider 不一致：{report.get('provider')!r}")
    if report.get("model") != args.expected_model:
        failures.append(f"模型不一致：{report.get('model')!r}")
    if report.get("endpoint_url") != args.expected_endpoint_url:
        failures.append(f"Provider Endpoint URL 不一致：{report.get('endpoint_url')!r}")
    if report.get("prompt_version") != args.expected_prompt_version:
        failures.append(f"Prompt 版本不一致：{report.get('prompt_version')!r}")
    if report.get("requested_input_count") != len(expected):
        failures.append("requested_input_count 与测试集不一致")
    if report.get("completed_input_count") != len(expected):
        failures.append("completed_input_count 与测试集不一致")
    if len(actual) != len(expected):
        failures.append(f"报告只有 {len(actual)} 条结果，应为 {len(expected)} 条")

    actual_by_id = {item.get("test_input_id"): item for item in actual}
    if len(actual_by_id) != len(actual):
        failures.append("报告包含空 ID 或重复 ID")

    expected_ids = {item["id"] for item in expected}
    failures.extend(provider_audit_failures(
        provider_receipts,
        expected_run_nonce=expected_run_nonce,
        expected_provider=args.expected_provider,
        expected_model=args.expected_model,
        expected_endpoint_url=args.expected_endpoint_url,
        expected_test_ids=expected_ids,
        actual_by_id=actual_by_id,
        run_started_at=run_started_at,
        run_finished_at=run_finished_at,
    ))

    for fixture in expected:
        test_id = fixture["id"]
        result = actual_by_id.get(test_id)
        if result is None:
            add_failure(failures, test_id, "缺少跑测结果")
            continue
        if result.get("base_case_id") != fixture["base_case_id"]:
            add_failure(failures, test_id, "base_case_id 不一致")
        if result.get("input_kind") != fixture["input_kind"]:
            add_failure(failures, test_id, "input_kind 不一致")
        if result.get("writing_scene") != fixture["writing_scene"]:
            add_failure(failures, test_id, "writing_scene 不一致")
        if result.get("spoken_input") != fixture["spoken_input"]:
            add_failure(failures, test_id, "spoken_input 不一致")
        if result.get("canonical_input") != canonical_input(fixture):
            add_failure(failures, test_id, "canonical_input 不一致")
        if result.get("segment_count") != len(fixture["segment_texts"]):
            add_failure(failures, test_id, "segment_count 不一致")
        if result.get("segment_texts") != fixture["segment_texts"]:
            add_failure(failures, test_id, "segment_texts 与冻结测试输入不一致")
        if result.get("context_fixture") != expected_context_fixture(fixture):
            add_failure(failures, test_id, "context_fixture 与实际冻结夹具不一致")
        if result.get("executed_route") != "fast":
            add_failure(failures, test_id, f"唯一模式未执行 Fast 路径：{result.get('executed_route')!r}")
        if result.get("detected_route") not in {"fast", "structured", "deep"}:
            add_failure(failures, test_id, f"detected_route 无效：{result.get('detected_route')!r}")
        for runtime_failure in runtime_evidence_failures(result):
            add_failure(failures, test_id, runtime_failure)
        leaked_answer_fields = sorted(RUNNER_FORBIDDEN_ANSWER_FIELDS.intersection(result))
        if leaked_answer_fields:
            add_failure(
                failures,
                test_id,
                f"Runner 报告泄漏答案字段 {leaked_answer_fields!r}",
            )

        output = result.get("model_output", "")
        canonical = result.get("canonical_input", "")
        if not output.strip():
            add_failure(failures, test_id, "模型输出为空")
            continue
        if result.get("fallback_used"):
            add_failure(failures, test_id, "触发原文回退")
        if result.get("failure_reason") is not None:
            add_failure(failures, test_id, f"存在失败原因 {result['failure_reason']}")
        if fixture["requires_transformation"] and normalized(output) == normalized(canonical):
            add_failure(failures, test_id, "需要整理但成稿与输入等价")

        for factor, assertion in fixture.get("factor_assertions", {}).items():
            unknown_assertions = set(assertion) - ALLOWED_FACTOR_ASSERTION_KEYS
            if unknown_assertions:
                add_failure(
                    failures,
                    test_id,
                    f"因素 {factor} 含 evaluator 未实现的断言 {sorted(unknown_assertions)!r}",
                )
            for token in assertion.get("required_substrings", []):
                if token not in output:
                    add_failure(failures, test_id, f"因素 {factor} 缺少必含文本 {token!r}")
            for token in assertion.get("forbidden_substrings", []):
                if token in output:
                    add_failure(failures, test_id, f"因素 {factor} 未清理 {token!r}")
            if order := assertion.get("required_order"):
                if not contains_in_order(output, order):
                    add_failure(failures, test_id, f"因素 {factor} 未保持逻辑顺序 {order!r}")
            for token, maximum in assertion.get("maximum_occurrences", {}).items():
                if output.count(token) > maximum:
                    add_failure(failures, test_id, f"因素 {factor} 中 {token!r} 出现超过 {maximum} 次")
            minimum_sentences = assertion.get("minimum_sentence_count")
            if minimum_sentences and sentence_count(output) < minimum_sentences:
                add_failure(failures, test_id, f"因素 {factor} 的句界少于 {minimum_sentences}")
            if assertion.get("requires_terminal_punctuation") and not re.search(
                r"[。！？!?]\s*$", output
            ):
                add_failure(failures, test_id, f"因素 {factor} 缺少完整句末标点")
            maximum_segments = assertion.get("maximum_input_segment_count")
            if maximum_segments and result.get("segment_count", 10**9) > maximum_segments:
                add_failure(
                    failures,
                    test_id,
                    f"因素 {factor} 的输入分段超过 {maximum_segments}",
                )
            minimum_chunks = assertion.get("minimum_internal_chunk_count")
            if minimum_chunks and result.get("internal_chunk_count", 0) < minimum_chunks:
                add_failure(
                    failures,
                    test_id,
                    f"因素 {factor} 未真实进入至少 {minimum_chunks} 个内部切片",
                )
            minimum_items = assertion.get("minimum_list_item_count")
            if minimum_items and list_item_count(output) < minimum_items:
                add_failure(failures, test_id, f"因素 {factor} 的列表项少于 {minimum_items}")
            minimum_factor_ratio = assertion.get("minimum_reference_length_ratio")
            reference_length = semantic_length(fixture["reference_output"])
            if minimum_factor_ratio and reference_length:
                actual_ratio = semantic_length(output) / reference_length
                if actual_ratio < minimum_factor_ratio:
                    add_failure(
                        failures,
                        test_id,
                        f"因素 {factor} 的完整度 {actual_ratio:.3f} 低于 {minimum_factor_ratio:.3f}",
                    )

        checks = fixture["automatic_checks"]
        for token in checks["required_substrings"]:
            if token not in output:
                add_failure(failures, test_id, f"缺少必含文本 {token!r}")
        for group in checks.get("required_substring_groups", []):
            if not any(token in output for token in group):
                add_failure(failures, test_id, f"必含候选均未命中 {group!r}")
        blocks = relation_blocks(output)
        fact_groups = checks.get("required_fact_groups", [])
        for group in fact_groups:
            if not fact_group_is_preserved(group, fact_groups, blocks):
                add_failure(failures, test_id, f"同一语义块未保留事实关系 {group!r}")
        for claim in checks.get("required_claim_groups", []):
            matched = any(token in output for token in claim["alternatives"])
            if claim["disposition"] == "required" and not matched:
                add_failure(
                    failures,
                    test_id,
                    f"遗漏来源段 {claim['source_segment_index']} 的独立信息 {claim['alternatives']!r}",
                )
            if claim["disposition"] == "superseded" and matched:
                add_failure(
                    failures,
                    test_id,
                    f"保留了来源段 {claim['source_segment_index']} 的废弃信息 {claim['alternatives']!r}",
                )
        for token in checks["forbidden_substrings"]:
            if token in output:
                add_failure(failures, test_id, f"保留了禁含文本 {token!r}")
        for token in checks["forbidden_context_substrings"]:
            if token in output:
                add_failure(failures, test_id, f"泄漏上下文文本 {token!r}")
        minimum_paragraphs = checks.get("minimum_paragraph_count")
        if minimum_paragraphs and paragraph_count(output) < minimum_paragraphs:
            add_failure(failures, test_id, f"段落数少于 {minimum_paragraphs}")
        minimum_items = checks.get("minimum_list_item_count")
        if minimum_items and list_item_count(output) < minimum_items:
            add_failure(failures, test_id, f"列表项少于 {minimum_items}")
        minimum_ratio = checks.get("minimum_reference_length_ratio")
        reference_length = semantic_length(fixture["reference_output"])
        if minimum_ratio and reference_length:
            actual_ratio = semantic_length(output) / reference_length
            if actual_ratio < minimum_ratio:
                add_failure(
                    failures,
                    test_id,
                    f"成稿完整度 {actual_ratio:.3f} 低于参考成稿下限 {minimum_ratio:.3f}",
                )
        minimum_source_ratio = checks.get("minimum_source_length_ratio")
        source_length = semantic_length(canonical)
        if minimum_source_ratio and source_length:
            actual_ratio = semantic_length(output) / source_length
            if actual_ratio < minimum_source_ratio:
                add_failure(
                    failures,
                    test_id,
                    f"成稿相对来源完整度 {actual_ratio:.3f} 低于下限 {minimum_source_ratio:.3f}",
                )

    unexpected_ids = set(actual_by_id) - expected_ids
    if unexpected_ids:
        failures.append(f"报告包含测试集之外的 ID：{sorted(unexpected_ids)}")
    total_llm_calls = sum(
        item.get("llm_call_count", 0)
        for item in actual
        if isinstance(item.get("llm_call_count"), int)
        and not isinstance(item.get("llm_call_count"), bool)
    )
    if total_llm_calls < len(expected):
        failures.append(f"报告总 LLM 调用只有 {total_llm_calls}，少于 {len(expected)} 条输入")
    total_internal_chunks = sum(
        item.get("internal_chunk_count", 0)
        for item in actual
        if isinstance(item.get("internal_chunk_count"), int)
        and not isinstance(item.get("internal_chunk_count"), bool)
    )
    if total_llm_calls < total_internal_chunks:
        failures.append(
            f"报告总 LLM 调用 {total_llm_calls} 少于内部切片总数 {total_internal_chunks}"
        )

    if failures:
        print(f"FAIL：{len(failures)} 项硬性检查未通过")
        for failure in failures[:100]:
            print(f"- {failure}")
        if len(failures) > 100:
            print(f"- 其余 {len(failures) - 100} 项已省略")
        raise SystemExit(1)

    buckets = Counter(item["length_bucket"] for item in expected)
    contexts = Counter(item["context_type"] for item in expected)
    print(f"PASS：{len(expected)} 次输入全部通过硬性检查，未发生回退、空输出或必要改写缺失。")
    print(f"长度覆盖：{dict(sorted(buckets.items()))}")
    print(f"上下文覆盖：{dict(sorted(contexts.items()))}")
    print(f"母集 SHA-256：{expected_dataset_sha256}")
    print(f"无答案运行输入：{runner_input_path}（SHA-256 {expected_run_input_sha256}）")
    print(f"外部构建 manifest：{args.build_manifest}（SHA-256 {sha256_file(args.build_manifest)}）")
    print(f"Provider 网络回执：{provider_audit_path}（{len(provider_receipts)} 条，SHA-256 {sha256_file(provider_audit_path)}）")
    print("提示：自然度、个人口吻与是否敢直接发送仍须由独立 Agent 复核，机器检查不能代替。")


if __name__ == "__main__":
    main()
