#!/usr/bin/env python3
"""亲启冻结候选并校验三档原始证据；语义质量始终留给独立评审。"""

from __future__ import annotations

import argparse
from collections import Counter
import ctypes
from datetime import datetime, timezone
import hashlib
import importlib.util
from functools import lru_cache
import json
import math
import os
from pathlib import Path
import pwd
import re
import secrets
import statistics
import subprocess
import sys
import unicodedata

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
_spec = importlib.util.spec_from_file_location(
    "legacy_voice_polish_evaluator", ROOT / "scripts/evaluate-voice-polish-quality-report.py"
)
legacy = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(legacy)

MODES = ("direct", "light", "standard")
INPUT_FIELDS = {
    "test_input_id", "base_case_id", "input_kind", "writing_scene", "spoken_input",
    "preconditions", "context_type", "segment_texts", "context_fixture",
}


def object_sha(value: object) -> str:
    data = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(data).hexdigest()


def frozen_json(path: Path, expected_sha256: str) -> dict:
    expected = legacy.validate_hex(expected_sha256, 64, "外部冻结 SHA-256")
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"冻结文件必须是常规非符号链接文件：{path}")
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f"冻结文件 SHA-256 不一致：{path.name}")
    value = json.loads(data)
    if not isinstance(value, dict):
        raise ValueError("冻结文件不是 JSON 对象")
    return value


def validate_inputs(inputs: list[dict]) -> None:
    if not isinstance(inputs, list) or not inputs:
        raise ValueError("输入集合不能为空")
    seen = set()
    for item in inputs:
        if not isinstance(item, dict) or set(item) != INPUT_FIELDS:
            raise ValueError("Runner 输入字段必须严格白名单，禁止携带答案或评分契约")
        test_id = item["test_input_id"]
        if not isinstance(test_id, str) or not test_id or test_id in seen:
            raise ValueError("输入 ID 缺失或重复")
        seen.add(test_id)
        text, segments = item["spoken_input"], item["segment_texts"]
        if not isinstance(text, str) or not 0 < len(text) <= 1000:
            raise ValueError(f"{test_id}: 正文必须为 1–1000 字，不截断")
        if (not isinstance(segments, list) or not segments
                or any(not isinstance(s, str) or not s for s in segments)
                or not 0 < len("".join(segments)) <= 1000):
            raise ValueError(f"{test_id}: 原始分段必须非空且总长不超过1000字")
        if not isinstance(item["preconditions"], list) or any(
            not isinstance(p, str) for p in item["preconditions"]
        ):
            raise ValueError(f"{test_id}: preconditions 必须是字符串数组")


def validated_dataset(path: Path, expected_sha: str, contract_path: Path, contract_sha: str) -> dict:
    document = frozen_json(path, expected_sha)
    if document.get("schema_version") != 1 or document.get("modes") != list(MODES):
        raise ValueError("三档数据集版本或模式不匹配")
    inputs = document.get("inputs")
    validate_inputs(inputs)
    if document.get("input_count") != len(inputs) or document.get("maximum_input_characters") != 1000:
        raise ValueError("数据集输入数量或上限声明不一致")
    origins = document.get("input_provenance", [])
    if len(origins) != len(inputs) or {x.get("test_input_id") for x in origins} != {
        x["test_input_id"] for x in inputs
    }:
        raise ValueError("输入来源记录不完整或重复")
    by_id = {x["test_input_id"]: x for x in inputs}
    for origin in origins:
        if origin.get("input_sha256") != object_sha(by_id[origin["test_input_id"]]):
            raise ValueError("输入与其逐条冻结哈希不一致")
    if dict(Counter(x["suite"] for x in origins)) != document.get("suite_counts"):
        raise ValueError("分组覆盖数量与来源不一致")
    contract = frozen_json(contract_path, contract_sha)
    cases = contract.get("cases", [])
    if (contract.get("schema_version") != 1 or contract.get("dataset_sha256") != expected_sha
            or contract.get("input_count") != len(inputs) or len(cases) != len(inputs)
            or {x.get("test_input_id") for x in cases} != set(by_id)):
        raise ValueError("评分契约与冻结数据集未一一绑定")
    for item in cases:
        if item.get("input_sha256") != object_sha(by_id[item["test_input_id"]]):
            raise ValueError("评分契约绑定了另一条输入")
    return document


def selected_inputs(document: dict, test_ids: list[str] | None) -> list[dict]:
    if test_ids is None:
        return document["inputs"]
    if not test_ids or len(test_ids) != len(set(test_ids)):
        raise ValueError("诊断 ID 不能为空或重复")
    by_id = {x["test_input_id"]: x for x in document["inputs"]}
    if not set(test_ids) <= set(by_id):
        raise ValueError("诊断 ID 不属于冻结数据集")
    return [by_id[test_id] for test_id in test_ids]


def write_exclusive(path: Path, value: object) -> None:
    data = (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())


def validated_manifest(args) -> dict:
    manifest = legacy.validated_build_manifest(
        args.build_manifest, expected_manifest_sha256=args.expected_build_manifest_sha256,
        expected_source_commit=args.expected_source_commit, expected_source_tree=args.expected_source_tree,
        expected_executable_sha256=args.expected_executable_sha256,
        expected_dataset_sha256=args.expected_dataset_sha256,
        expected_designated_requirement_sha256=args.expected_designated_requirement_sha256,
    )
    if (manifest.get("quality_profile") != "three_mode"
            or manifest.get("supported_modes") != list(MODES)
            or manifest.get("scoring_contract_sha256") != args.expected_contract_sha256):
        raise ValueError("构建清单未冻结三档数据集、模式和独立评分契约")
    return manifest


def candidate_evidence(args) -> dict:
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(args.candidate_app)],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    candidate = legacy.candidate_app_evidence(args.candidate_app)
    for key, expected in [
        ("source_commit", args.expected_source_commit),
        ("executable_sha256", args.expected_executable_sha256),
    ]:
        if candidate[key] != expected:
            raise ValueError(f"候选 {key} 与外部冻结值不一致")
    if legacy.sha256_text(candidate["designated_requirement"]) != args.expected_designated_requirement_sha256:
        raise ValueError("候选签名身份与外部冻结值不一致")
    return candidate


def sandbox_policy() -> str:
    # 使用当前 uid 的真实主目录，不接受 HOME 重定向冒充已隔离用户数据。
    support = str(Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Application Support/Muse")
    return ('(version 1)\n(allow default)\n'
            f'(deny file-read* file-write* (subpath {json.dumps(support)}))\n'
            '(deny device-microphone)\n(deny appleevent-send)\n')


def validate_run_root(path: Path) -> None:
    support = Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Application Support/Muse"
    resolved = path.resolve()
    if support.resolve() == resolved or support.resolve() in resolved.parents:
        raise ValueError("run-root 不得指向真实 Dal 用户数据目录")
    if not path.is_absolute() or path.exists() or path.is_symlink():
        raise ValueError("run-root 必须是不存在的独占绝对目录")


def launch_command(executable: Path, run_input: Path, report: Path, audit: Path,
                   sandbox: Path, mode: str, nonce: str) -> list[str]:
    if mode not in MODES:
        raise ValueError("实际启动必须显式指定三档之一")
    return ["/usr/bin/sandbox-exec", "-f", str(sandbox), "/usr/bin/nice", "-n", "15",
            str(executable), "--voice-polish-quality-run", "--mode", mode,
            "--run-input", str(run_input), "--report", str(report),
            "--provider-audit", str(audit), "--run-nonce", nonce]


def launch_run(executable: Path, run_input: Path, directory: Path, mode: str, timeout: int) -> tuple:
    directory.mkdir(mode=0o700)
    report_path, audit_path = directory / "report.json", directory / "provider-audit.jsonl"
    with audit_path.open("xb"):
        pass
    audit_path.chmod(0o600)
    audit_identity = (audit_path.stat().st_dev, audit_path.stat().st_ino)
    sandbox = directory / "protect-user-data.sb"
    with sandbox.open("x", encoding="utf-8") as handle:
        handle.write(sandbox_policy())
    nonce = secrets.token_hex(32)
    command = launch_command(executable, run_input, report_path, audit_path, sandbox, mode, nonce)
    started = datetime.now(timezone.utc)
    with (directory / "process.log").open("xb") as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT)
        write_exclusive(directory / "launch-evidence.json", {
            "mode": mode, "command": command, "run_nonce": nonce, "process_id": process.pid,
            "started_at": started.isoformat(), "input_sha256": legacy.sha256_file(run_input),
            "sandbox_sha256": legacy.sha256_file(sandbox), "nice_level": 15,
        })
        try:
            return_code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise ValueError(f"{mode} 候选超时；保留原始日志，不启动授权窗口") from error
    finished = datetime.now(timezone.utc)
    write_exclusive(directory / "process-evidence.json", {
        "process_id": process.pid, "run_nonce": nonce, "return_code": return_code,
        "started_at": started.isoformat(), "finished_at": finished.isoformat(),
    })
    if return_code != 0:
        raise ValueError(f"{mode} 候选退出码 {return_code}，详见该档 process.log")
    if (audit_path.is_symlink() or not audit_path.is_file()
            or (audit_path.stat().st_dev, audit_path.stat().st_ino) != audit_identity):
        raise ValueError("Provider 审计文件被替换")
    if report_path.is_symlink() or not report_path.is_file() or report_path.stat().st_mtime < started.timestamp():
        raise ValueError("候选没有新生成常规报告")
    data = audit_path.read_bytes()
    if data and not data.endswith(b"\n"):
        raise ValueError("Provider 回执末行不完整")
    receipts = [json.loads(line) for line in data.splitlines()]
    report = json.loads(report_path.read_bytes())
    return report, receipts, nonce, process.pid, started, finished


def valid_integer(value, minimum=0) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def audit_time(value, started: datetime, finished: datetime, label: str, failures: list[str]):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None or not started.timestamp() - 2 <= parsed.timestamp() <= finished.timestamp() + 2:
            raise ValueError()
        return parsed
    except (AttributeError, TypeError, ValueError):
        failures.append(f"{label}: 起止时间缺失或超出本次进程窗口")
        return None


def available_context_evidence(item: dict) -> list[str]:
    fixture = legacy.expected_context_fixture(item)
    if fixture["safety"] != "safe":
        return []
    result = []
    if fixture["safety"] == "safe" and fixture["level"] != "metadataOnly":
        result += [fixture["selected_text"]] if fixture["selected_text"] is not None else []
        if fixture["level"] == "nearbyText":
            result += [fixture[key] for key in ("text_before_cursor", "text_after_cursor") if fixture[key] is not None]
    return result + [x.strip() for x in fixture["recent_muse_inputs"] if x.strip()]


def sanitized_fallback(text: str) -> str:
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    def allowed(char):
        value = ord(char)
        return value in (9, 10) or not (
            value <= 31 or 127 <= value <= 159 or 0xFDD0 <= value <= 0xFDEF
            or value & 0xFFFF in (0xFFFE, 0xFFFF)
        )
    return "".join(c for c in text if allowed(c)).strip()


class _CFRange(ctypes.Structure):
    _fields_ = [("location", ctypes.c_long), ("length", ctypes.c_long)]


@lru_cache(maxsize=1)
def _core_foundation():
    # 跑测宿主本来就是 macOS。只读取给定字符串的组合字符边界，不访问应用或配置。
    library = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    library.CFStringCreateWithBytes.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32, ctypes.c_bool]
    library.CFStringCreateWithBytes.restype = ctypes.c_void_p
    library.CFStringGetLength.argtypes = [ctypes.c_void_p]
    library.CFStringGetLength.restype = ctypes.c_long
    library.CFStringGetRangeOfComposedCharactersAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
    library.CFStringGetRangeOfComposedCharactersAtIndex.restype = _CFRange
    library.CFRelease.argtypes = [ctypes.c_void_p]
    return library


@lru_cache(maxsize=1024)
def composed_characters(text: str) -> tuple[str, ...]:
    if text.isascii() and "\r\n" not in text:
        return tuple(text)
    try:
        library = _core_foundation()
        encoded = text.encode("utf-8")
        value = library.CFStringCreateWithBytes(None, encoded, len(encoded), 0x08000100, False)
        if not value:
            raise ValueError("无法构造原文的 Unicode 字符边界")
        try:
            units = text.encode("utf-16-le")
            length, offset, result = library.CFStringGetLength(value), 0, []
            while offset < length:
                span = library.CFStringGetRangeOfComposedCharactersAtIndex(value, offset)
                if span.location != offset or span.length <= 0 or offset + span.length > length:
                    raise ValueError("原文 Unicode 字符边界不连续")
                result.append(units[2 * offset:2 * (offset + span.length)].decode("utf-16-le"))
                offset += span.length
            # CoreFoundation 的组合序列接口将 CR/LF 分开；Swift Character 按 GB3 合并。
            combined = []
            for character in result:
                if character == "\n" and combined and combined[-1] == "\r":
                    combined[-1] = "\r\n"
                else:
                    combined.append(character)
            return tuple(combined)
        finally:
            library.CFRelease(value)
    except (OSError, UnicodeError) as error:
        raise ValueError("无法可靠复现 macOS 原文分段字符边界") from error


def terminology_units(text: str) -> list[tuple[str, int, int]]:
    units, offset = [], 0
    for character in composed_characters(text):
        end = offset + len(character)
        for folded in composed_characters(unicodedata.normalize("NFKC", character).lower()):
            if (folded.isspace() and "\n" not in folded and "\r" not in folded) or folded in "-‐‑‒–—﹘﹣－":
                continue
            units.append((folded, offset, end))
        offset = end
    return units


def terminology_key(text: str) -> str:
    return "".join(unit[0] for unit in terminology_units(text))


def terminology_matches(alias: str, text: str) -> list[tuple[int, int, int]]:
    needle, haystack = [u[0] for u in terminology_units(alias)], terminology_units(text)
    if len(needle) < 2:
        return []
    result = []
    for index in range(len(haystack) - len(needle) + 1):
        candidate = haystack[index:index + len(needle)]
        if [unit[0] for unit in candidate] != needle:
            continue
        start, end = candidate[0][1], candidate[-1][2]
        ascii_word = lambda char: len(char) == 1 and char.isascii() and char.isalnum()
        if ((ascii_word(needle[0]) and start > 0 and ascii_word(composed_characters(text[:start])[-1]))
                or (ascii_word(needle[-1]) and end < len(text) and ascii_word(composed_characters(text[end:])[0]))):
            continue
        result.append((start, end, len(needle)))
    return result


def select_terminology_matches(matches: list[tuple[int, int, int, str]], text: str,
                               prefer_normalized_length: bool) -> list[tuple[int, int, int, str]]:
    grouped = {}
    for match in matches:
        grouped.setdefault(match[:2], []).append(match)
    unambiguous = []
    for group in grouped.values():
        if prefer_normalized_length:
            best_length = max(match[2] for match in group)
            group = [match for match in group if match[2] == best_length]
        if len({terminology_key(match[3]) for match in group}) != 1:
            continue
        if len({match[3] for match in group}) != 1:
            raise ValueError("冻结术语规则存在同优先级大小写竞争，不能推定确定结果")
        unambiguous.append(group[0])
    selected = []
    for match in sorted(unambiguous, key=lambda m: (-len(text[m[0]:m[1]].encode("utf-16-le")), m[0])):
        if not any(match[0] < old[1] and match[1] > old[0] for old in selected):
            selected.append(match)
    return selected


def applying_fixture_terminology(text: str, preconditions: list[str]) -> str:
    """只复现冻结夹具的已确认规则；不推断上下文实体或读取个人词库。"""
    rules = {}
    for precondition in preconditions:
        if "→" not in precondition:
            continue
        alias, canonical = precondition.split("→", 1)
        alias, canonical = alias.rsplit("已确认 ", 1)[-1].strip(), canonical.strip()
        if alias and canonical:
            rules[alias] = canonical
    if not rules:
        return text
    matches = [(start, end, width, canonical) for alias, canonical in rules.items()
               for start, end, width in terminology_matches(alias, text)]
    first = select_terminology_matches(matches, text, True)
    # applyingKnownCorrections 先选唯一命中，再由 applying 在同一不可变原文定位替换。
    operations = [(start, end, width, match[3]) for match in first
                  for start, end, width in terminology_matches(text[match[0]:match[1]], text)]
    output = text
    for start, end, _, canonical in sorted(select_terminology_matches(operations, text, False), reverse=True):
        output = output[:start] + canonical + output[end:]
    return output


def frozen_input_envelope(item: dict) -> tuple[str, list[dict]]:
    """从冻结输入复现 Runner.makeEnvelope / VoiceInputEnvelope 的确定性来源分段。"""
    raw = item["spoken_input"].strip()
    canonical = applying_fixture_terminology(item["spoken_input"], item.get("preconditions", [])).strip()
    raw_segments = [segment for segment in item["segment_texts"] if segment.strip()]
    if not raw or not canonical:
        raise ValueError("冻结完整正文为空")
    if not raw_segments or "".join(raw_segments).strip() != raw:
        raw_segments = [raw]
    preferred = [applying_fixture_terminology(segment, item.get("preconditions", [])) for segment in item["segment_texts"]]
    if "".join(raw_segments) == canonical:
        texts = raw_segments
    elif len(preferred) == len(raw_segments) and "".join(preferred).strip() == canonical:
        texts = preferred
    elif len(raw_segments) == 1:
        texts = [canonical]
    else:
        characters = composed_characters(canonical)
        raw_lengths = [len(composed_characters(segment)) for segment in raw_segments]
        total = max(1, sum(raw_lengths))
        nonempty = len(characters) >= len(raw_lengths)
        previous, cumulative, texts = 0, 0, []
        for index, length in enumerate(raw_lengths):
            cumulative += length
            remaining = len(raw_lengths) - index - 1
            if remaining == 0:
                boundary = len(characters)
            else:
                ratio = cumulative / total * len(characters)
                proportional = math.floor(ratio) + int(ratio - math.floor(ratio) >= 0.5)
                minimum = previous + int(nonempty)
                maximum = len(characters) - (remaining if nonempty else 0)
                boundary = min(max(proportional, minimum), max(minimum, maximum))
            texts.append("".join(characters[previous:boundary]))
            previous = boundary
    return canonical, [{"id": f"s{index}", "text": text} for index, text in enumerate(texts, 1)]


def explained_by_mappings(source: str, target: str, mappings: list[tuple[str, str]]) -> bool:
    """仅重放已记录的局部字面映射；不复制 Swift 的音近推断、候选排名或语义判断。"""
    if len(source) > 8192 or len(target) > 8192:
        return False
    mappings = list(set(mappings))
    reachable = [set() for _ in range(len(source) + 1)]
    reachable[0].add(0)
    for index in range(len(source)):
        matches = [(before, after) for before, after in mappings if source.startswith(before, index)]
        for destination in reachable[index]:
            if destination < len(target) and source[index] == target[destination]:
                reachable[index + 1].add(destination + 1)
            for before, after in matches:
                if target.startswith(after, destination):
                    reachable[index + len(before)].add(destination + len(after))
    return len(target) in reachable[-1]


def resolved_entity_evidence(item: dict, row: dict, prepared_source: str | None = None) -> tuple[list[str], list[str]]:
    failures, mappings = [], []
    tid = item["test_input_id"]
    entities = row.get("resolved_entities")
    segments = row.get("canonical_segments")
    prepared = row.get("pre_resolution_canonical_input")
    expected_prepared = sanitized_fallback(legacy.canonical_input(item) if prepared_source is None else prepared_source)
    if prepared != expected_prepared:
        failures.append(f"{tid}: 实体解析前正文不对应完整原文及夹具明确术语")
    if not isinstance(entities, list) or any(not isinstance(x, dict) for x in entities):
        return [], failures + [f"{tid}: 缺少完整 resolved_entities 派生证据"]
    if not isinstance(segments, list) or not segments or any(
        not isinstance(x, dict) or not isinstance(x.get("id"), str) or not isinstance(x.get("text"), str)
        for x in segments
    ):
        return [], failures + [f"{tid}: 缺少 canonical 段及其ID"]
    by_id = {x["id"]: x["text"] for x in segments}
    if len(by_id) != len(segments) or sanitized_fallback("".join(x["text"] for x in segments)) != prepared:
        failures.append(f"{tid}: canonical 分段未无损对应解析前正文")
    bodies = available_context_evidence(item)
    for entity in entities:
        if set(entity) != {"surface_text", "canonical", "source_segment_ids", "candidate_source", "confidence"}:
            failures.append(f"{tid}: 实体映射结构不完整")
            continue
        surface, canonical = entity["surface_text"], entity["canonical"]
        source_ids, confidence = entity["source_segment_ids"], entity["confidence"]
        if (not isinstance(surface, str) or not surface or not isinstance(canonical, str) or not canonical
                or not isinstance(source_ids, list) or not source_ids or any(not isinstance(x, str) for x in source_ids)):
            failures.append(f"{tid}: 实体映射文本或引用段无效")
            continue
        if surface not in expected_prepared or any(surface not in by_id.get(segment_id, "") for segment_id in source_ids):
            failures.append(f"{tid}: 实体surface没有出现在完整来源和其引用段内")
        # Runner 的个人词库、片段与热词固定为空。产品已确认别名也只能在
        # 安全夹具明确出现 canonical 时由 Resolver 启用，不放行任意名称。
        if entity["candidate_source"] != "authorizedContext" or not any(canonical in body for body in bodies):
            failures.append(f"{tid}: 实体canonical没有冻结安全夹具来源")
        if (not isinstance(confidence, (int, float)) or isinstance(confidence, bool)
                or not math.isfinite(confidence) or not 0.88 <= confidence <= 1):
            failures.append(f"{tid}: 实体置信度缺失或不满足已确认阈值")
        mappings.append((surface, canonical))
    actual = row.get("canonical_input")
    if not isinstance(actual, str) or not explained_by_mappings(expected_prepared, actual, mappings):
        failures.append(f"{tid}: 最终canonical含有已记录局部实体映射无法解释的改动")
    return [f"{before} → {after}" for before, after in mappings], failures


def actual_modifications(before: str, after: str, anchor: int) -> list[tuple[int, int, str]]:
    """与 Swift 使用同一 Unicode 标量对齐、共同首尾裁剪和 LCS 平局规则。"""
    prefix = 0
    while prefix < min(len(before), len(after)) and before[prefix] == after[prefix]:
        prefix += 1
    before_end, after_end = len(before), len(after)
    while before_end > prefix and after_end > prefix and before[before_end - 1] == after[after_end - 1]:
        before_end -= 1
        after_end -= 1
    old_count, new_count = before_end - prefix, after_end - prefix
    removals, insertions = set(), set()
    if old_count * new_count > 1_000_000:
        removals.update(range(prefix, before_end))
        insertions.update(range(prefix, after_end))
    else:
        columns = new_count + 1
        lengths = [0] * ((old_count + 1) * columns)
        for old in range(old_count - 1, -1, -1):
            for new in range(new_count - 1, -1, -1):
                lengths[old * columns + new] = (
                    1 + lengths[(old + 1) * columns + new + 1]
                    if before[prefix + old] == after[prefix + new]
                    else max(lengths[(old + 1) * columns + new], lengths[old * columns + new + 1])
                )
        old, new = 0, 0
        while old < old_count or new < new_count:
            if old < old_count and new < new_count and before[prefix + old] == after[prefix + new]:
                old += 1
                new += 1
            elif old < old_count and (new == new_count or lengths[(old + 1) * columns + new] >= lengths[old * columns + new + 1]):
                removals.add(prefix + old)
                old += 1
            else:
                insertions.add(prefix + new)
                new += 1
    old, new, changes = 0, 0, []
    while old < len(before) or new < len(after):
        start, new_start = old, new
        while old < len(before) and old in removals:
            old += 1
        while new < len(after) and new in insertions:
            new += 1
        if old != start or new != new_start:
            changes.append((anchor + start, anchor + old, after[new_start:new]))
        if old < len(before) and new < len(after):
            old += 1
            new += 1
        elif old == start and new == new_start:
            break
    return changes


def modification_conflict(first: tuple[int, int, str], second: tuple[int, int, str]) -> bool:
    start, end, _ = first
    other_start, other_end, _ = second
    if start == end and other_start == other_end:
        return start == other_start
    if start == end:
        return other_start < start < other_end
    if other_start == other_end:
        return start < other_start < end
    return start < other_end and end > other_start


def lexical_characters(text: str) -> str:
    technical = set("-_/\\`@#%")
    result = []
    for index, character in enumerate(text):
        embedded_mark = (character in ".:" and 0 < index < len(text) - 1
                         and all(c.isascii() and c.isalnum() for c in (text[index - 1], text[index + 1])))
        if character in technical or embedded_mark or not (
            character.isspace() or unicodedata.category(character).startswith("P")
        ):
            result.append(character)
    return "".join(result)


def is_subsequence(candidate: str, source: str) -> bool:
    remaining = iter(source)
    return all(character in remaining for character in candidate)


def punctuation_preserves_technical_tokens(before: str, after: str) -> bool:
    technical = set("-_/\\`@#%")
    embedded = r"[A-Za-z0-9]+(?:[.:][A-Za-z0-9]+)+"
    return (lexical_characters(before) == lexical_characters(after)
            and [c for c in before if c in technical] == [c for c in after if c in technical]
            and re.findall(embedded, before) == re.findall(embedded, after))


def adjacent_repetition_removal(before: str, after: str) -> bool:
    if not after or len(after) >= len(before):
        return False
    pending, seen = [(0, 0)], set()
    while pending:
        old, new = pending.pop()
        if (old, new) in seen:
            continue
        seen.add((old, new))
        if old == len(before) or new == len(after):
            if old == len(before) and new == len(after):
                return True
            continue
        if before[old] == after[new]:
            pending.append((old + 1, new + 1))
        for width in range(1, min((len(before) - old) // 2, len(after) - new) + 1):
            unit = after[new:new + width]
            if before[old:old + width] != unit:
                continue
            end = old + width
            while end + width <= len(before) and before[end:end + width] == unit:
                end += width
                pending.append((end, new + width))
    return False


NEWLINE_PATTERN = r"\r\n|[\n\r\v\f\x85\u2028\u2029]"


def lexical_units(text: str) -> tuple[list[str], list[int]]:
    characters = list(composed_characters(text))
    indices = []
    for i, c in enumerate(characters):
        embedded = c in ".:" and 0 < i < len(characters) - 1 and all(
            x.isascii() and x.isalnum() for x in (characters[i - 1], characters[i + 1]))
        if c in set("-_/\\`@#%") or embedded or not (c.isspace() or unicodedata.category(c[0]).startswith("P")):
            indices.append(i)
    return characters, indices


def v4_punctuation_preserves_tokens(before: str, after: str) -> bool:
    return (punctuation_preserves_technical_tokens(unicodedata.normalize("NFC", before), unicodedata.normalize("NFC", after))
            and re.findall(r"[A-Za-z0-9_]+", before) == re.findall(r"[A-Za-z0-9_]+", after)
            and re.findall(r"(?<![A-Za-z0-9_])\.[A-Za-z0-9_][A-Za-z0-9_.-]*", before)
                == re.findall(r"(?<![A-Za-z0-9_])\.[A-Za-z0-9_][A-Za-z0-9_.-]*", after))


def mechanical_paragraph(before: str, after: str, fillers: int, permissions: list[bool], allow_reviewed_changes: bool) -> tuple[str, int] | None:
    characters, indices = lexical_units(before)
    old = [unicodedata.normalize("NFC", characters[i]) for i in indices]
    new_chars, new_indices = lexical_units(after)
    new = [unicodedata.normalize("NFC", new_chars[i]) for i in new_indices]
    filler_positions = [i for i, c in enumerate(characters) if c in set("嗯呃额啊唔")]
    allowed_fillers = {i for i, permitted in zip(filler_positions, permissions) if permitted}
    pending, seen = [(0, 0, fillers, [])], set()
    while pending:
        i, j, used, kept = pending.pop()
        if (i, j, used) in seen:
            continue
        seen.add((i, j, used))
        if i == len(old) and j == len(new):
            retained = {indices[k] for k in kept}
            lexical = set(indices)
            return "".join(c for k, c in enumerate(characters) if k not in lexical or k in retained), used
        maximum = min((len(old) - i) // 2, len(new) - j)
        if allow_reviewed_changes and len(characters) <= 96:
            # 反向入栈，保持 Swift 的相等、填充声、从短到长口吃的确定性优先级。
            alternatives = []
            for width in range(1, maximum + 1):
                unit = old[i:i + width]
                if (unit != new[j:j + width] or not all(
                    not c.isascii() and unicodedata.category(c[0]).startswith("L")
                    and c not in "零〇一二三四五六七八九十百千万亿两" for c in unit)):
                    continue
                end = i + width
                while end + width <= len(old) and old[end:end + width] == unit:
                    end += width
                    if any(unicodedata.category(c[0]).startswith("P") for c in characters[indices[i]:indices[end - 1] + 1]):
                        break
                    alternatives.append((end, j + width, used, kept + list(range(i, i + width))))
            pending.extend(reversed(alternatives))
        # 唔、呃只参与待核对形状证明，不能作为停顿声免于语义复核。
        if (i < len(old) and used < 6 and old[i] in set("嗯呃额啊唔") and indices[i] in allowed_fillers
                and (allow_reviewed_changes or old[i] not in set("唔呃"))):
            pending.append((i + 1, j, used + 1, kept))
        if i < len(old) and j < len(new) and old[i] == new[j]:
            pending.append((i + 1, j + 1, used, kept + [i]))
    return None


def filler_permissions(context: str, start: int, end: int) -> list[bool]:
    characters = list(composed_characters(context))
    result, position = [], 0
    def boundary(c):
        return c.isspace() or unicodedata.category(c[0]).startswith("P")
    for i, c in enumerate(characters):
        if c in set("嗯呃额啊唔") and start <= position < end:
            left, right = i, i + 1
            while left > 0 and characters[left - 1] in set("嗯呃额啊唔"):
                left -= 1
            while right < len(characters) and characters[right] in set("嗯呃额啊唔"):
                right += 1
            left_boundary = left == 0 or boundary(characters[left - 1])
            right_boundary = right == len(characters) or boundary(characters[right])
            result.append(left_boundary and ("额" not in characters[left:right] or right_boundary))
        position += len(c)
    return result


def is_v4_mechanical_edit(edit: dict, draft: str | None = None, *, allow_reviewed_changes: bool = False) -> bool:
    return v4_mechanical_projection(edit, draft, allow_reviewed_changes=allow_reviewed_changes) is not None


def v4_mechanical_projection(edit: dict, draft: str | None = None, *, allow_reviewed_changes: bool = False) -> str | None:
    before, after = edit.get("before"), edit.get("after")
    if not isinstance(before, str) or not before or not isinstance(after, str):
        return None
    context = before if draft is None else draft
    start = context.find(before)
    if start < 0 or context.find(before, start + 1) >= 0:
        return None
    permissions = filler_permissions(context, start, start + len(before))
    if (re.findall(NEWLINE_PATTERN, before) != re.findall(NEWLINE_PATTERN, after)
            or any(re.search(NEWLINE_PATTERN, before[start:end] + inserted)
                   for start, end, inserted in actual_modifications(before, after, 0))):
        return None
    projected = before
    for spoken, symbol in [("双横线", "--"), ("短横线", "-"), ("反斜杠", "\\"), ("斜杠", "/"), ("下划线", "_")]:
        projected = projected.replace(spoken, symbol)
    projected = re.sub(r"(?<=[A-Za-z0-9_])点(?=[A-Za-z0-9_])", ".", projected)
    for candidate in (before, projected):
        old_parts, new_parts = re.split(NEWLINE_PATTERN, candidate), re.split(NEWLINE_PATTERN, after)
        if len(old_parts) != len(new_parts):
            continue
        used, offset, projections = 0, 0, []
        for old, new, raw in zip(old_parts, new_parts, re.split(NEWLINE_PATTERN, before)):
            count = sum(c in set("嗯呃额啊唔") for c in composed_characters(raw))
            result = mechanical_paragraph(old, new, used, permissions[offset:offset + count], allow_reviewed_changes)
            if result is None or not v4_punctuation_preserves_tokens(result[0], new):
                break
            used = result[1]
            offset += count
            projections.append(result[0])
        else:
            separators = re.findall(NEWLINE_PATTERN, candidate)
            projection = "".join(p + (separators[i] if i < len(separators) else "") for i, p in enumerate(projections))
            expected = context[:start] + projection + context[start + len(before):]
            actual = context[:start] + after + context[start + len(before):]
            if v4_punctuation_preserves_tokens(expected, actual):
                return projection
    return None


def v4_requires_semantic_review(edits: list[dict], draft: str | None = None) -> bool:
    if any(edit.get("kind") == "content" or not is_v4_mechanical_edit(edit, draft) for edit in edits):
        return True
    if draft is None:
        return False
    projected = [{**edit, "after": v4_mechanical_projection(edit, draft)} for edit in edits]
    try:
        expected = apply_recorded_edits(draft, json.dumps({"edits": projected}))
        actual = apply_recorded_edits(draft, json.dumps({"edits": edits}))
        return not v4_punctuation_preserves_tokens(expected, actual)
    except ValueError:
        return True


def source_contains_punctuation_equivalent_anchor(anchor: str, source: str) -> bool:
    if anchor in source:
        return True
    characters, indices = lexical_units(source)
    words = [unicodedata.normalize("NFC", characters[i]) for i in indices]
    chars, positions = lexical_units(anchor)
    wanted = [unicodedata.normalize("NFC", chars[i]) for i in positions]
    if not wanted:
        return False
    for start in range(len(words) - len(wanted) + 1):
        if words[start:start + len(wanted)] != wanted:
            continue
        candidate = "".join(characters[indices[start]:indices[start + len(wanted) - 1] + 1])
        if (re.findall(NEWLINE_PATTERN, candidate) == re.findall(NEWLINE_PATTERN, anchor)
                and v4_punctuation_preserves_tokens(candidate, anchor)):
            return True
    return False


def validate_v4_light_edit(edit: dict, source: str, allows_reviewed_directives: bool, draft: str | None = None) -> None:
    before, after, kind = edit["before"], edit["after"], edit.get("kind")
    if kind not in {"punctuation", "filler", "stutter", "symbol", "word", "correction", "directive"}:
        raise ValueError("v4 轻度类型无权限")
    changes = actual_modifications(before, after, 0)
    if (re.findall(NEWLINE_PATTERN, before) != re.findall(NEWLINE_PATTERN, after)
            or any(re.search(NEWLINE_PATTERN, before[start:end] + inserted) for start, end, inserted in changes)):
        raise ValueError("v4 轻度不得改变原有换行")
    if is_v4_mechanical_edit(edit, draft, allow_reviewed_changes=True):
        return
    if kind not in {"punctuation", "directive"} and len(composed_characters(before)) > 96:
        raise ValueError("v4 实质修改锚点超界")
    old, new = lexical_characters(before), lexical_characters(after)
    pairs = list(zip([lexical_characters(p) for p in re.split(NEWLINE_PATTERN, before)],
                     [lexical_characters(p) for p in re.split(NEWLINE_PATTERN, after)]))
    if kind in {"punctuation", "symbol"}:
        raise ValueError("v4 完整实际变化不能由机械规则解释")
    if kind == "stutter":
        if not adjacent_repetition_removal(old, new) or not all(a == b or adjacent_repetition_removal(a, b) for a, b in pairs):
            raise ValueError("v4 非相邻口吃删除")
    elif kind == "word":
        blocks = actual_modifications(old, new, 0)
        if (len(blocks) != 1 or blocks[0][1] - blocks[0][0] > 8 or not 1 <= len(blocks[0][2]) <= 8
                or sum(a != b for a, b in pairs) != 1
                or [c for c in before if c in "-_/\\`@#%"] != [c for c in after if c in "-_/\\`@#%"]):
            raise ValueError("v4 字词修改超出轻度局部权限")
    elif kind == "filler":
        removed = "".join(before[a:b] for a, b, _ in changes)
        if any(c for _, _, c in changes) or not removed or len(composed_characters(removed)) > 6 or not set(removed) <= set("嗯呃额啊唔"):
            raise ValueError("v4 填充声删除夹带其他内容")
    elif kind == "directive":
        if allows_reviewed_directives:
            if (len(changes) != 1 or changes[0][2] or changes[0][0] == changes[0][1]
                    or len(composed_characters(before[changes[0][0]:changes[0][1]])) > 32):
                raise ValueError("v4 已核对编辑要求只能连续短删除")
        elif (len(composed_characters(before)) > 32 or after or before[-1] not in "：:，,。."
              or not source.startswith(before) or before == source):
            raise ValueError("v4 无标点或内嵌编辑要求未获显式核对权限")
    elif kind == "correction":
        # v4 允许首轮标点变化后的锚点，证据本身仍须逐字来自完整 source。
        validate_recorded_light_edit(edit, source, 4, _checking_correction=True)


def validate_recorded_light_edit(edit: dict, source: str, editing_prompt_version: int,
                                 allows_reviewed_directives: bool = False, _checking_correction: bool = False,
                                 draft: str | None = None) -> None:
    if editing_prompt_version == 4 and not _checking_correction:
        return validate_v4_light_edit(edit, source, allows_reviewed_directives, draft)
    before, after = edit["before"], edit["after"]
    old_words, new_words = lexical_characters(before), lexical_characters(after)
    newline_pattern = r"\r\n|[\n\r\v\f\x85\u2028\u2029]"
    paragraph_pairs = list(zip(
        [lexical_characters(part) for part in re.split(newline_pattern, before)],
        [lexical_characters(part) for part in re.split(newline_pattern, after)]
    ))
    changed_paragraphs = sum(old != new for old, new in paragraph_pairs)
    kind = edit.get("kind")
    if editing_prompt_version in (3, 4):
        changes = actual_modifications(before, after, 0)
        if (re.findall(newline_pattern, before) != re.findall(newline_pattern, after)
                or any(re.search(newline_pattern, before[start:end] + inserted) for start, end, inserted in changes)):
            raise ValueError("v3 轻度不得新增、删除或移动原有换行")
        if kind == "punctuation" and (changed_paragraphs or not punctuation_preserves_technical_tokens(before, after)):
            raise ValueError("v3 标点编辑不能改变技术 token 或把正文搬过原段落边界")
        if kind == "word" and changed_paragraphs != 1:
            raise ValueError("v3 字词编辑只能改变一个原段落")
        if kind == "stutter" and not all(old == new or adjacent_repetition_removal(old, new) for old, new in paragraph_pairs):
            raise ValueError("v3 口吃删除必须在每个原段落内独立成立")
        if kind == "symbol":
            projected = before
            for spoken, symbol in [("双横线", "--"), ("短横线", "-"), ("反斜杠", "\\"), ("斜杠", "/"), ("下划线", "_")]:
                projected = projected.replace(spoken, symbol)
            projected = re.sub(r"(?<=[A-Za-z0-9_])点(?=[A-Za-z0-9_])", ".", projected)
            if (projected == before or not punctuation_preserves_technical_tokens(projected, after)
                    or [lexical_characters(p) for p in re.split(newline_pattern, projected)] != [lexical_characters(p) for p in re.split(newline_pattern, after)]):
                raise ValueError("v3 符号恢复后的正文必须保持在同一原段落")
    if kind != "correction":
        return
    cues = ["不对", "说错", "改成", "改为", "应该是", "我改一下", "不用写", "不要写", "actually", "i mean", "scratch that"]
    if editing_prompt_version in (3, 4):
        cues.append("改由")
    if len(before) > 96 or after.count("\n") > before.count("\n"):
        raise ValueError("改口锚点超界或新增段落")
    if (any(cue in before.lower() for cue in cues) and is_subsequence(new_words, old_words)
            and (editing_prompt_version not in (3, 4) or all(is_subsequence(new, old) for old, new in paragraph_pairs))):
        return
    evidence = edit.get("evidence")
    anchor_exists = source_contains_punctuation_equivalent_anchor(before, source) if editing_prompt_version == 4 else before in source
    if (editing_prompt_version not in (3, 4) or not isinstance(evidence, str) or not evidence or len(evidence) > 192
            or evidence not in source or not anchor_exists or not any(cue in evidence.lower() for cue in cues)
            or changed_paragraphs != 1
            or "".join(c for c in old_words if unicodedata.category(c)[0] not in "LN")
                != "".join(c for c in new_words if unicodedata.category(c)[0] not in "LN")):
        raise ValueError("远处改口缺少 v3 已核对权限或完整原文证据，或改变技术字符")
    changes = actual_modifications(old_words, new_words, 0)
    if len(changes) != 1:
        raise ValueError("远处改口必须只有一个实质字词修改块")
    start, end, inserted = changes[0]
    if end - start > 32 or len(inserted) > 8 or (inserted and inserted not in evidence):
        raise ValueError("远处改口字词超界或新增内容不能由连续证据解释")


def swift_character_is_whitespace(character: str) -> bool:
    whitespace = set("\t\n\v\f\r \u0085\u00a0\u1680\u2028\u2029\u202f\u205f\u3000") | set(chr(c) for c in range(0x2000, 0x200B))
    return bool(character) and character[0] in whitespace


def v7_unsafe_characters(text: str) -> bool:
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    return any(ord(c) not in (9, 10) and (ord(c) <= 31 or 127 <= ord(c) <= 159
               or 0xFDD0 <= ord(c) <= 0xFDEF or ord(c) & 0xFFFF in (0xFFFE, 0xFFFF)) for c in normalized)


def v7_lexical_characters(text: str) -> str:
    characters = composed_characters(text)
    return "".join(c for i, c in enumerate(characters) if c in set("-_/\\`@#%")
        or (c in ".:" and 0 < i < len(characters) - 1
            and all(x.isascii() and x.isalnum() for x in (characters[i - 1], characters[i + 1])))
        or not (swift_character_is_whitespace(c) or unicodedata.category(c[0]).startswith("P")))


@lru_cache(maxsize=1)
def v7_icu_han_script():
    # 与 NSRegularExpression 的 \p{Han} 使用同一 macOS ICU，不依赖近似的汉字范围表。
    library = ctypes.CDLL("/usr/lib/libicucore.A.dylib")
    library.u_getIntPropertyValue.argtypes = [ctypes.c_int32, ctypes.c_int32]
    library.u_getIntPropertyValue.restype = ctypes.c_int32
    library.u_getPropertyValueEnum.argtypes = [ctypes.c_int32, ctypes.c_char_p]
    library.u_getPropertyValueEnum.restype = ctypes.c_int32
    han = library.u_getPropertyValueEnum(0x100A, b"Han")  # SDK uchar.h: UCHAR_SCRIPT = 0x100A。
    if han < 0: raise ValueError("无法确定生产 ICU 的 Han 脚本属性")
    return library, han


def v7_removes_complete_clocks(before: str, after: str, draft: str) -> bool:
    library, han = v7_icu_han_script()
    def boundary(c):
        return (swift_character_is_whitespace(c) or c in "，。！？；、（）“”‘’(),;!?'\""
                or (len(c) == 1 and library.u_getIntPropertyValue(ord(c), 0x100A) == han))
    def parts(text):
        characters = composed_characters(text)
        offsets, offset = {}, 0
        for index, c in enumerate(characters):
            offsets[offset] = index
            offset += len(c)
        offsets[offset] = len(characters)
        matches = []
        for match in re.finditer(r"(?:[01]?[0-9]|2[0-3]):[0-5][0-9]", text):
            start, end = offsets.get(match.start()), offsets.get(match.end())
            if (start is not None and end is not None
                    and (start == 0 or boundary(characters[start - 1]))
                    and (end == len(characters) or boundary(characters[end]))):
                matches.append(match)
        remainder = text
        for match in reversed(matches): remainder = remainder[:match.start()] + remainder[match.end():]
        return [match[0] for match in matches], v7_lexical_characters(remainder)
    start = draft.find(before)
    if start < 0 or draft.find(before, start + 1) >= 0: return False
    old, old_rest = parts(draft)
    new, new_rest = parts(draft[:start] + after + draft[start + len(before):])
    technical = lambda text: "".join(c for c in text if unicodedata.category(c)[0] not in "LN")
    normalize = lambda text: tuple(unicodedata.normalize("NFC", c) for c in composed_characters(text))
    return (bool(new) and len(new) < len(old) and is_subsequence(new, old)
            and is_subsequence(normalize(new_rest), normalize(old_rest)) and technical(old_rest) == technical(new_rest))


def validate_v7_local_edit(edit: dict, source: str, allows_reviewed_directives: bool,
                           allows_reviewed_source_corrections: bool, draft: str) -> None:
    """只在 v7 收紧近邻改口；v1–v6 的权限回放保持原样。"""
    before, after, kind = edit["before"], edit["after"], edit.get("kind")
    if v7_unsafe_characters(after):
        raise ValueError("v7 编辑含不安全字符")
    if kind != "correction":
        return validate_v4_light_edit(edit, source, allows_reviewed_directives, draft)
    changes = actual_modifications(before, after, 0)
    if (re.findall(NEWLINE_PATTERN, before) != re.findall(NEWLINE_PATTERN, after)
            or any(re.search(NEWLINE_PATTERN, before[a:b] + inserted) for a, b, inserted in changes)):
        raise ValueError("v7 局部改口不得改变原段落")
    if is_v4_mechanical_edit(edit, draft, allow_reviewed_changes=True):
        return
    if len(composed_characters(before)) > 96:
        raise ValueError("v7 实质修改锚点超界")
    old, new = v7_lexical_characters(before), v7_lexical_characters(after)
    changes = actual_modifications(old, new, 0)
    technical = lambda text: "".join(c for c in text if unicodedata.category(c)[0] not in "LN")
    if sum(b - a for a, b, _ in changes) > 32 or sum(len(s) for _, _, s in changes) > 8:
        raise ValueError("v7 改口实质修改累计超出 32/8")
    preserves_technical = technical(old) == technical(new)
    pairs = list(zip([v7_lexical_characters(p) for p in re.split(NEWLINE_PATTERN, before)],
                     [v7_lexical_characters(p) for p in re.split(NEWLINE_PATTERN, after)]))
    cues = ["不对", "说错", "改成", "改为", "改由", "应该是", "我改一下", "不用写", "不要写", "actually", "i mean", "scratch that"]
    # Swift 近邻子序列按 Character 规范等价比较，预算仍按真实标量差异计数。
    subsequence = lambda a, b: is_subsequence(tuple(unicodedata.normalize("NFC", c) for c in composed_characters(a)),
                                              tuple(unicodedata.normalize("NFC", c) for c in composed_characters(b)))
    if any(cue in before.lower() for cue in cues) and subsequence(new, old) and all(subsequence(b, a) for a, b in pairs):
        if not preserves_technical and not v7_removes_complete_clocks(before, after, draft):
            raise ValueError("v7 近邻改口损坏技术字符且不能由完整旧钟面删除解释")
        return
    evidence = edit.get("evidence")
    if (not preserves_technical or not allows_reviewed_source_corrections or not isinstance(evidence, str) or not evidence or len(evidence) > 192
            or evidence not in source or not source_contains_punctuation_equivalent_anchor(before, source)
            or not any(cue in evidence.lower() for cue in cues) or len(before) > 96
            or sum(unicodedata.normalize("NFC", a) != unicodedata.normalize("NFC", b) for a, b in pairs) != 1
            or len(changes) != 1 or (changes[0][2] and changes[0][2] not in evidence)):
        raise ValueError("v7 远处改口未满足来源、显式权限或单块连续证据限制")


def apply_recorded_edits(source: str, response: str, *, editing_prompt_version: int | None = None,
                         allows_reviewed_directives: bool = False, original_source: str | None = None,
                         allows_reviewed_source_corrections: bool = False,
                         allows_directive_edits: bool = True) -> str:
    # v5 改复核响应、v6 加优先差异；局部补丁权限均完整沿用 v4。
    if editing_prompt_version in (5, 6):
        editing_prompt_version = 4
    # v8及后续标准局部权限沿用v7；新轻度在入口单独禁止代写删除。
    if editing_prompt_version in (8, 9, 10, 11):
        editing_prompt_version = 7
    document = decode_v7_initial(response) if editing_prompt_version == 7 else json.loads(response)
    if (not isinstance(document, dict) or set(document) != {"edits"}
            or not isinstance(document["edits"], list) or len(document["edits"]) > 128):
        raise ValueError("编辑响应不是独立 edits 对象")
    if not allows_directive_edits and any(
        isinstance(edit, dict) and edit.get("kind") in {"directive", "content"} for edit in document["edits"]
    ):
        raise V7ContractError("v9 轻度不授予代写指令删除或正文重写权限")
    located, projected_edits = [], []
    for edit in document["edits"]:
        if not isinstance(edit, dict):
            raise ValueError("编辑项不是对象")
        before, after = edit.get("before"), edit.get("after")
        if not isinstance(before, str) or not before or not isinstance(after, str):
            raise ValueError("编辑锚点缺失或重复")
        if editing_prompt_version == 7:
            validate_v7_local_edit(edit, original_source if original_source is not None else source,
                                   allows_reviewed_directives, allows_reviewed_source_corrections, source)
        elif editing_prompt_version is not None:
            validate_recorded_light_edit(edit, original_source if original_source is not None else source,
                                         editing_prompt_version, allows_reviewed_directives, draft=source)
        if editing_prompt_version in (4, 7):
            projected = v4_mechanical_projection(edit, source, allow_reviewed_changes=True)
            projected_edits.append({**edit, "after": after if projected is None else projected})
        start = source.find(before)
        if start < 0 or source.find(before, start + 1) >= 0:
            raise ValueError("编辑锚点缺失或重复")
        for change in actual_modifications(before, after, start):
            if change[0] == change[1] and change in located:
                continue
            if any(modification_conflict(change, prior) for prior in located):
                raise ValueError("实际修改范围冲突")
            located.append(change)
    output = source
    for start, end, after in sorted(located, key=lambda x: (x[0], x[1] - x[0]), reverse=True):
        output = output[:start] + after + output[end:]
    if editing_prompt_version in (4, 7):
        expected = apply_recorded_edits(source, json.dumps({"edits": projected_edits}))
        if not v4_punctuation_preserves_tokens(expected, output):
            raise ValueError("v4 合批修改破坏技术 token 边界")
    if editing_prompt_version in (4, 7) and any(edit.get("kind") == "directive" for edit in document["edits"]) and not lexical_characters(output):
        raise ValueError("v4 编辑要求删除不能清空全文实质内容")
    return output


def complete_change_evidence(source: str, draft: str, changes: object) -> bool:
    """证明有序差异完整重建实际稿；不假定 Swift Character.diff 的唯一平局切分。"""
    import unicodedata
    if not isinstance(changes, list) or len(changes) > len(source) + len(draft):
        return False
    # Swift Character 比较接受规范等价；实际 draft 字节仍由 Provider 补丁回放绑定。
    source, draft = (unicodedata.normalize("NFC", text) for text in (source, draft))
    positions = {(0, 0)}
    for change in changes:
        if (not isinstance(change, dict) or set(change) != {"removed", "inserted"}
                or not all(isinstance(change[k], str) for k in ("removed", "inserted"))
                or not (change["removed"] or change["inserted"])):
            return False
        removed, inserted = (unicodedata.normalize("NFC", change[k]) for k in ("removed", "inserted"))
        following = set()
        for old, new in positions:
            while True:
                if source.startswith(removed, old) and draft.startswith(inserted, new):
                    following.add((old + len(removed), new + len(inserted)))
                if old >= len(source) or new >= len(draft) or source[old] != draft[new]:
                    break
                old += 1
                new += 1
        if not following:
            return False
        positions = following
    return any(source[old:] == draft[new:] for old, new in positions)


def v6_content_character_count(text: str) -> int:
    # Swift Character 按首标量的 Unicode White_Space 判断；不能用 str.isspace 或全标量判断。
    whitespace = set("\t\n\v\f\r \u0085\u00a0\u1680\u2028\u2029\u202f\u205f\u3000") | set(chr(c) for c in range(0x2000, 0x200B))
    return sum(character not in set("，。！？；：、") and character[0] not in whitespace
               for character in composed_characters(text))


def complete_v6_review_focus(source: str, draft: str, payload: dict) -> bool:
    """校验优先差异及其共同完整对齐路径；不另造 diff，也不从重点引用推断编辑权限。"""
    source_raw, draft_raw = composed_characters(source), composed_characters(draft)
    old = tuple(unicodedata.normalize("NFC", c) for c in source_raw)
    new = tuple(unicodedata.normalize("NFC", c) for c in draft_raw)
    changes, focus, total = (payload.get(k) for k in ("changes", "review_focus", "review_focus_total"))
    if (not isinstance(changes, list) or len(changes) > len(old) + len(new)
            or not isinstance(focus, list) or len(focus) > 16 or not valid_integer(total)):
        return False
    normalized, priorities = [], []
    for index, change in enumerate(changes):
        if (not isinstance(change, dict) or set(change) != {"removed", "inserted"}
                or not all(isinstance(change[k], str) for k in ("removed", "inserted"))
                or not (change["removed"] or change["inserted"])):
            return False
        removed, inserted = (tuple(unicodedata.normalize("NFC", c) for c in composed_characters(change[k]))
                             for k in ("removed", "inserted"))
        normalized.append((removed, inserted))
        removed_count, inserted_count = (v6_content_character_count(change[k]) for k in ("removed", "inserted"))
        if removed_count or inserted_count:
            priorities.append((0 if removed_count else 1, -removed_count - inserted_count, index))
    expected_indices = [key[2] for key in sorted(priorities)[:16]]
    if total != len(priorities) or len(focus) != len(expected_indices):
        return False
    bounds = {}
    for item, index in zip(focus, expected_indices):
        if (not isinstance(item, dict) or set(item) != {
                "change_index", "source_start", "source_end", "draft_start", "draft_end", "source_context", "draft_context"}
                or any(not valid_integer(item[k]) for k in ("change_index", "source_start", "source_end", "draft_start", "draft_end"))
                or item["change_index"] != index):
            return False
        a, b, c, d = (item[k] for k in ("source_start", "source_end", "draft_start", "draft_end"))
        removed, inserted = normalized[index]
        if (not a <= b <= len(old) or not c <= d <= len(new)
                or old[a:b] != removed or new[c:d] != inserted
                or item["source_context"] != "".join(source_raw[max(0, a - 20):min(len(old), b + 20)])
                or item["draft_context"] != "".join(draft_raw[max(0, c - 20):min(len(new), d + 20)])):
            return False
        bounds[index] = (a, b, c, d)
    positions = {(0, 0)}
    for index, (removed, inserted) in enumerate(normalized):
        following, scanned = set(), set()
        for a, c in positions:
            if index in bounds:
                start, end, draft_start, draft_end = bounds[index]
                if (start >= a and draft_start >= c and old[a:start] == new[c:draft_start]):
                    following.add((end, draft_end))
                continue
            # 未入选块也必须按原顺序解释全部差异，不能借 cap 掩盖删改。
            while True:
                # 重复文本的多条前缀路径可能在同一坐标汇合；后续搜索只做一次。
                if (a, c) in scanned:
                    break
                scanned.add((a, c))
                if old[a:a + len(removed)] == removed and new[c:c + len(inserted)] == inserted:
                    following.add((a + len(removed), c + len(inserted)))
                if a >= len(old) or c >= len(new) or old[a] != new[c]:
                    break
                a += 1
                c += 1
        if not following:
            return False
        positions = following
    return any(old[a:] == new[c:] for a, c in positions)


def v4_role_comparison(text: str) -> str:
    return unicodedata.normalize("NFC", "".join(c for c in composed_characters(text)
        if not c.isspace() and not unicodedata.category(c[0]).startswith("P")))


def v4_source_review_risk(source: str) -> bool:
    cues = ["帮我", "替我", "你帮", "整理成", "润色", "改写", "提示词", "prompt", "我补", "等一下",
            "不对", "说错", "改成", "改为", "改由", "我改一下", "不用写", "不要写", "别写", "先别",
            "只整理", "actually", "i mean", "scratch that"]
    lowered = source.lower()
    return any(cue in lowered for cue in cues) or re.search(r"(?:给|跟)[^。！？\n]{0,16}(?:回|说)(?:一下|一条|一声)", lowered) is not None


def v9_light_source_review_risk(source: str) -> bool:
    # 只决定是否核对自我纠错；任务字眼不再自动增加轻度调用。
    cues = ["我补", "等一下", "不对", "说错", "改成", "改为", "改由", "我改一下",
            "actually", "i mean", "scratch that"]
    return any(cue in source.lower() for cue in cues)


def decode_v4_edits(value: object) -> list[dict]:
    if not isinstance(value, list) or len(value) > 128:
        raise ValueError("v4 edits 结构错误")
    for edit in value:
        if (not isinstance(edit, dict) or not isinstance(edit.get("before"), str)
                or not isinstance(edit.get("after"), str)
                or edit.get("kind") not in {"punctuation", "stutter", "word", "symbol", "correction", "filler", "directive", "content"}
                or (edit.get("evidence") is not None and not isinstance(edit["evidence"], str))):
            raise ValueError("v4 编辑项字段错误")
    return value


def decode_v4_review(raw: str, source: str) -> dict:
    if len(raw.encode()) > 1_048_576:
        raise ValueError("v4 复核响应超界")
    value = json.loads(raw)
    if not isinstance(value, dict) or set(value) != {"source_roles", "edits"}:
        raise ValueError("v4 复核必须同时包含 source_roles 和 edits")
    roles = value["source_roles"]
    if not isinstance(roles, list) or len(roles) > 64:
        raise ValueError("v4 原文角色结构错误")
    seen = set()
    for item in roles:
        if not isinstance(item, dict) or set(item) != {"quote", "role", "target_evidence"}:
            raise ValueError("v4 原文角色字段错误")
        quote, evidence = item["quote"], item["target_evidence"]
        if (not isinstance(quote, str) or not quote or len(composed_characters(quote)) > 192
                or not isinstance(evidence, str) or not evidence or len(composed_characters(evidence)) > 192
                or not v4_role_comparison(quote) or quote not in source
                or source.find(quote, source.find(quote) + 1) >= 0 or quote in seen
                or evidence not in source or item["role"] not in {"current_editor", "recipient_content", "uncertain"}):
            raise ValueError("v4 原文角色缺少唯一原文及目标对象依据")
        seen.add(quote)
    decode_v4_edits(value["edits"])
    return value


class InvalidV5Review(ValueError):
    """v5 复核结构或引用错误，对应生产 invalidStructuredResponse。"""


def decode_v5_review(raw: str, source: str) -> dict:
    try:
        if len(raw.encode()) > 1_048_576:
            raise ValueError("v5 复核响应超界")
        value = json.loads(raw)
        if not isinstance(value, dict) or set(value) != {"delivery", "editor_spans", "edits"}:
            raise ValueError("v5 复核只能包含 delivery、editor_spans 和 edits")
        if value["delivery"] not in ("direct_reply", "ai_prompt", "delegated_task", "other_or_uncertain"):
            raise ValueError("v5 delivery 无效")
        spans = value["editor_spans"]
        if not isinstance(spans, list) or len(spans) > 64:
            raise ValueError("v5 editor_spans 必须是至多 64 项的字符串数组")
        seen = set()
        for span in spans:
            if (not isinstance(span, str) or not span or len(composed_characters(span)) > 192
                    or not v4_role_comparison(span) or span not in source
                    or source.find(span, source.find(span) + 1) >= 0):
                raise ValueError("v5 编辑引用必须是含正文的唯一连续原文且不超过 192 字符")
            # Swift String 的相等与 Set 同时接受 Unicode 规范等价。
            key = unicodedata.normalize("NFC", span)
            if key in seen:
                raise ValueError("v5 编辑引用重复")
            seen.add(key)
        decode_v4_edits(value["edits"])
        return value
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        raise InvalidV5Review(str(error)) from error


def decode_versioned_review(raw: str, source: str, version: int) -> dict:
    return decode_v5_review(raw, source) if version in (5, 6) else decode_v4_review(raw, source)


def v4_contains_editor_instruction(assessment: dict, draft: str, version: int = 4) -> bool:
    text = v4_role_comparison(draft)
    if version in (5, 6):
        return any(v4_role_comparison(span) in text for span in assessment["editor_spans"])
    return any(item["role"] == "current_editor" and v4_role_comparison(item["quote"]) in text
               for item in assessment["source_roles"])


def v4_plain_text(response: str, source: str) -> str:
    if len(response.encode()) > 1_048_576:
        raise ValueError("标准首稿超界")
    text = re.sub(r"<think>[\s\S]*?</think>", "", response)
    text = re.sub(r"<think>[\s\S]*$", "", text).replace("\r\n", "\n").replace("\r", "\n").strip()
    for prefix in ["最终文本：", "最终文本:", "润色后：", "润色后:", "Final text:", "Polished text:"]:
        if text.startswith(prefix) and not source.startswith(prefix):
            text = text[len(prefix):].strip()
            break
    blocks = [part.strip() for part in text.split("\n\n") if part.strip()]
    for width in range(1, len(blocks) // 2 + 1):
        if len(blocks) % width or blocks != blocks[:width] * (len(blocks) // width):
            continue
        unit = "\n\n".join(blocks[:width])
        comparable = v4_role_comparison(unit).lower()
        if (len(composed_characters(unit)) >= 40 and comparable
                and v4_role_comparison(source).lower().count(comparable) < len(blocks) // width):
            return unit
    return text


class V7ContractError(ValueError):
    def __init__(self, message: str, code: str = "planIntegrityFailure"):
        super().__init__(message)
        self.code = code


def v7_structure_segments(draft: str) -> list[dict]:
    """镜像生产 Character 句末切分，保留片段中的原始字节及全部尾部。"""
    text = composed_characters(draft)
    if (not text or len(draft.encode()) > 1_048_576 or all(swift_character_is_whitespace(c) for c in text)
            or v7_unsafe_characters(draft)):
        raise V7ContractError("v7 结构来源无效")
    brackets_by_open = {"(": ")", "[": "]", "{": "}", "（": "）", "【": "】", "《": "》", "〈": "〉"}
    quotes = {"“": "”", "‘": "’", "「": "」", "『": "』", '"': '"', "'": "'"}
    brackets, quote, code, code_count = [], None, None, 0
    indented, parts, start, index = False, [], 0, 0

    def escaped(i):
        cursor = i
        while cursor > 0 and text[cursor - 1] == "\\": cursor -= 1
        return (i - cursor) % 2 == 1

    def sentence_end(i):
        character = text[i]
        if character in "。！？": return True
        if (character not in ".!?" or i == 0 or swift_character_is_whitespace(text[i - 1])
                or (i + 1 < len(text) and not swift_character_is_whitespace(text[i + 1]))):
            return False
        token_start = i
        while token_start > 0 and not swift_character_is_whitespace(text[token_start - 1]): token_start -= 1
        token = "".join(text[token_start:i])
        if any(c in ".:/\\_=@#<>|&*+{}[]" for c in token): return False
        if character == "." and (i - token_start == 1 or token.lower() in {"mr", "mrs", "ms", "dr", "prof", "sr", "jr", "vs", "etc", "st", "no"}):
            return False
        if character != "." and i + 1 < len(text):
            following = i + 1
            while following < len(text) and swift_character_is_whitespace(text[following]): following += 1
            if following < len(text) and text[following].isascii() and text[following].islower(): return False
        return True

    while index < len(text) and len(parts) < 127:
        character = text[index]
        if index == 0 or text[index - 1][0] in "\r\n\v\f\x85\u2028\u2029":
            cursor, spaces, has_tab = index, 0, False
            while cursor < len(text) and text[cursor] in (" ", "\t"):
                spaces += text[cursor] == " "
                has_tab |= text[cursor] == "\t"
                cursor += 1
            indented = has_tab or spaces >= 4
        if character in ("`", "~"):
            end = index + 1
            while end < len(text) and text[end] == character: end += 1
            count = end - index
            if code is not None:
                if code == character and (count >= code_count if code_count >= 3 else count == code_count):
                    code, code_count = None, 0
            elif character == "`" or count >= 3:
                code, code_count = character, count
            index = end
            continue
        if code is not None or indented:
            index += 1
            continue
        if quote is not None:
            if character == quote and not escaped(index): quote = None
            index += 1
            continue
        if (character in quotes and not escaped(index)
                and not (character == "'" and 0 < index < len(text) - 1
                         and all(unicodedata.category(c[0]).startswith("L") for c in (text[index - 1], text[index + 1])))):
            quote = quotes[character]
            index += 1
            continue
        if brackets and character == brackets[-1]: brackets.pop()
        elif character in brackets_by_open: brackets.append(brackets_by_open[character])
        if not brackets and sentence_end(index):
            end = index + 1
            while end < len(text) and text[end] in "。！？!?": end += 1
            parts.append("".join(text[start:end]))
            start, index = end, end
        else:
            index += 1
    if start < len(text):
        tail = "".join(text[start:])
        if parts and all(swift_character_is_whitespace(c) for c in text[start:]): parts[-1] += tail
        else: parts.append(tail)
    return [{"id": f"c{i + 1}", "text": part} for i, part in enumerate(parts)]


def v7_validate_segments(segments: object) -> None:
    if (not isinstance(segments, list) or not 1 <= len(segments) <= 128
            or any(not isinstance(s, dict) or set(s) != {"id", "text"} or s.get("id") != f"c{i + 1}"
                   or not isinstance(s.get("text"), str) or not s["text"] for i, s in enumerate(segments))):
        raise V7ContractError("v7 结构片段无效")
    # 只验证生产 validateSegments 的输入约束，不把调用方片段重新切一遍。
    if (sum(len(s["text"].encode()) for s in segments) > 1_048_576
            or any(v7_unsafe_characters(s["text"]) for s in segments)
            or not any(not swift_character_is_whitespace(c) for s in segments for c in composed_characters(s["text"]))):
        raise V7ContractError("v7 结构片段正文无效")


def v7_code_block(text: str) -> bool:
    for line in re.split(NEWLINE_PATTERN, text):
        leading = re.match(r"[ \t]*", line)[0]
        if "\t" in leading or len(leading) >= 4 or line[len(leading):].startswith(("```", "~~~")):
            return True
    return False


def v7_validate_layout(layout: object, segments: list[dict]) -> list[dict]:
    v7_validate_segments(segments)
    if not isinstance(layout, list) or not 1 <= len(layout) <= 128:
        raise V7ContractError("v7 布局必须为 1–128 个完整分组")
    known, seen = {s["id"] for s in segments}, set()
    by_id = {s["id"]: s["text"] for s in segments}
    for block in layout:
        if (not isinstance(block, dict) or set(block) != {"style", "segment_ids"}
                or block["style"] not in ("paragraph", "bullet", "numbered")
                or not isinstance(block["segment_ids"], list) or not 1 <= len(block["segment_ids"]) <= 128):
            raise V7ContractError("v7 布局字段或分组无效")
        for sid in block["segment_ids"]:
            if not isinstance(sid, str) or sid not in known or sid in seen:
                raise V7ContractError("v7 布局包含未知或重复片段")
            if (block["style"] != "paragraph" or len(block["segment_ids"]) != 1) and v7_code_block(by_id[sid]):
                raise V7ContractError("v7 围栏或缩进代码片段必须独占 paragraph 分组")
            seen.add(sid)
    if seen != known: raise V7ContractError("v7 布局遗漏实际片段")
    return layout


def v7_render_layout(layout: object, segments: list[dict]) -> str:
    blocks = v7_validate_layout(layout, segments)
    by_id, output, number, previous = {s["id"]: s["text"] for s in segments}, "", 0, None
    for block in blocks:
        body = "".join(by_id[sid] for sid in block["segment_ids"])
        characters = composed_characters(body)
        leading_count = 0
        while leading_count < len(characters) and swift_character_is_whitespace(characters[leading_count]): leading_count += 1
        leading = "".join(characters[:leading_count])
        if previous is not None:
            prior = composed_characters(previous)
            trailing_start = len(prior)
            while trailing_start > 0 and swift_character_is_whitespace(prior[trailing_start - 1]): trailing_start -= 1
            trailing = "".join(prior[trailing_start:])
            for count in range(3):
                separator = "\n" * count
                # 先组合再遍历 Character；CR+LF 可跨边界组成单个 CRLF，中间有空格则不会。
                if sum(c[0] in "\r\n\v\f\x85\u2028\u2029" for c in composed_characters(trailing + separator + leading)) >= 2:
                    break
            output += separator
        if block["style"] == "numbered":
            number += 1
            marker = f"{number}. "
        else:
            number = 0
            marker = "- " if block["style"] == "bullet" else ""
        output += leading + marker + "".join(characters[leading_count:])
        previous = body
    if len(output.encode()) > 1_048_576: raise V7ContractError("v7 结构输出超界")
    return output


def decode_v7_initial(raw: str) -> dict:
    try:
        if len(raw.encode()) > 1_048_576: raise ValueError("v7 首轮响应超界")
        value = json.loads(raw)
        if not isinstance(value, dict) or set(value) != {"edits"}: raise ValueError("v7 首轮只能包含 edits")
    except (ValueError, TypeError) as error:
        raise V7ContractError(str(error)) from error
    try:
        # Swift Codable 类型错误属于 DecodingError，而合法数组过长是 TextEditError。
        if isinstance(value["edits"], list) and len(value["edits"]) > 128:
            raise V7ContractError("v7 补丁数量超界")
        decode_v4_edits(value["edits"])
    except V7ContractError:
        raise
    except ValueError as error:
        raise V7ContractError(str(error), "invalidStructuredResponse") from error
    return value


def decode_v7_review(raw: str, source: str, segments: list[dict] | None) -> dict:
    try:
        if segments is None: return decode_v5_review(raw, source)
        if len(raw.encode()) > 1_048_576: raise ValueError("v7 复核响应超界")
        value = json.loads(raw)
        if not isinstance(value, dict) or set(value) != {"delivery", "editor_spans", "edits", "layout"}:
            raise ValueError("v7 标准复核必须且只能含四个协议字段")
        decode_v5_review(json.dumps({k: value[k] for k in ("delivery", "editor_spans", "edits")}, ensure_ascii=False), source)
        if value["edits"]:
            if value["layout"] != []: raise ValueError("v7 内容待修复时布局必须为空数组")
        else:
            v7_validate_layout(value["layout"], segments)
        return value
    except (ValueError, TypeError, KeyError, AttributeError) as error:
        raise V7ContractError(str(error), "invalidStructuredResponse") from error


def decode_v9_light_review(raw: str) -> dict:
    try:
        response = decode_v7_initial(raw)
        # 仅在审计内部适配公共流程；实际响应不允许角色或编辑摘录字段。
        return {"edits": response["edits"], "editor_spans": []}
    except (ValueError, TypeError, KeyError, AttributeError) as error:
        raise V7ContractError(str(error), "invalidStructuredResponse") from error


def decode_v10_light(raw: str, stage: str) -> dict:
    """v10 的明确拒绝和修后确认独立于局部编辑权限；语法失败不算修复。"""
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("v10 JSON 对象不允许重复字段")
            result[key] = value
        return result

    def validate_strings(value):
        # Python JSON 可保留未配对 surrogate；Swift String 解码会拒绝，须在协议层同样拒绝。
        if isinstance(value, str):
            value.encode("utf-8")
        elif isinstance(value, dict):
            for key, item in value.items():
                validate_strings(key)
                validate_strings(item)
        elif isinstance(value, list):
            for item in value:
                validate_strings(item)

    try:
        if len(raw.encode()) > 1_048_576:
            raise ValueError("v10 响应超界")
        value = json.loads(raw, object_pairs_hook=unique_object)
        validate_strings(value)
        fields = {"text", "edits"} if stage == "review" else {"approved"} if stage == "confirmation" else {"text"}
        if not isinstance(value, dict) or set(value) != fields:
            raise ValueError("v10 响应字段不符合当前阶段")
        if stage == "confirmation":
            if not isinstance(value["approved"], bool):
                raise ValueError("v10 approved 必须是真正布尔值")
        else:
            target = value["text"]
            if not (stage == "review" and target is None) and (not isinstance(target, str) or not target):
                raise ValueError("v10 text 必须是非空字符串或复核的明确 null 拒绝")
            if stage == "review":
                decode_v4_edits(value["edits"])
        return value
    except (ValueError, TypeError, KeyError, AttributeError) as error:
        raise V7ContractError(str(error), "invalidStructuredResponse") from error


def v10_strict_mechanical_candidate(source: str, target: str) -> str:
    """先证明整个变化无需语义审核，再应用；不能用宽权限 apply 成功替代证明。"""
    edits = [{"before": source, "after": target, "kind": "punctuation"}]
    if v4_requires_semantic_review(edits, source):
        raise V7ContractError("v10 候选仍有未声明、需要语义复核的实际变化")
    result = apply_recorded_edits(source, json.dumps({"edits": edits}, ensure_ascii=False),
        editing_prompt_version=10, allows_directive_edits=False)
    if result.encode() != target.encode():
        raise V7ContractError("v10 最终应用结果未逐字等于核对目标")
    return result


def v10_output_shape_check(source: str, output: str) -> None:
    # 仅复现可确定的输出形状门。事实语义另由真实独立评分负责，不能从通过来源审计推定。
    if not output.strip():
        raise V7ContractError("v10 不能把空白稿冒充成功", "emptyOutput")
    if v7_unsafe_characters(output):
        raise V7ContractError("v10 输出含不允许的控制字符", "unsafeCharacters")
    source_count = len(composed_characters(source))
    if (len(output.encode()) > 1_048_576
            or len(composed_characters(output)) > max(source_count * 2, source_count + 40)):
        raise V7ContractError("v10 输出超出实际长度门限", "abnormalLength")


def v10_light_stage_contract(row: dict, payloads: list) -> tuple[list[str], list[str]]:
    source, stages, fallback = row["canonical_input"], row["stage_responses"], row.get("fallback_used")
    allowed, failures, repairs, output = ["voicePolishFast"], [], 0, None

    def bind_draft(index: int, current: str) -> None:
        payload = payloads[index]
        if not isinstance(payload, dict) or payload.get("draft_text") != current:
            failures.append("v10 复核或确认未绑定实际候选全文")
        if not isinstance(payload, dict) or not complete_v6_review_focus(source, current, payload):
            failures.append("v10 复核或确认未绑定完整来源差异和实际上下文")

    for index, payload in enumerate(payloads):
        if not isinstance(payload, dict):
            failures.append("v10 请求载荷不可审计")
        else:
            failures.extend(v7_payload_field_failures(payload, "light", index))
    try:
        if stages and stages[0].get("status") == "succeeded":
            initial = decode_v10_light(stages[0]["response_text"], "initial")["text"]
            proposed = [{"before": source, "after": initial, "kind": "punctuation"}]
            requires = v9_light_source_review_risk(source) or v4_requires_semantic_review(proposed, source)
            if not requires:
                output = v10_strict_mechanical_candidate(source, initial)
                v10_output_shape_check(source, output)
            else:
                allowed.append("voicePolishAnalyze")
                if len(stages) >= 2:
                    bind_draft(1, initial)
                    if stages[1].get("status") == "succeeded":
                        assessment = decode_v10_light(stages[1]["response_text"], "review")
                        target = assessment["text"]
                        if target is None:
                            raise V7ContractError("v10 复核明确拒绝候选", "semanticDecisionUnverified")
                        repairs = int(target.encode() != initial.encode())
                        semantic_draft = apply_recorded_edits(source,
                            json.dumps({"edits": assessment["edits"]}, ensure_ascii=False),
                            editing_prompt_version=10, original_source=source,
                            allows_reviewed_source_corrections=True, allows_directive_edits=False)
                        output = v10_strict_mechanical_candidate(semantic_draft, target)
                        v10_output_shape_check(source, output)
                        if repairs:
                            allowed.append("voicePolishAnalyze")
                            if len(stages) >= 3:
                                bind_draft(2, output)
                                if stages[2].get("status") == "succeeded":
                                    final = decode_v10_light(stages[2]["response_text"], "confirmation")
                                    if not final["approved"]:
                                        raise V7ContractError("v10 修后稿未通过最终确认", "semanticDecisionUnverified")
            if not fallback and row.get("model_output") != output:
                raise V7ContractError("v10 交付不是经过权限证明及实际核对的完整候选")
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        if not fallback:
            failures.append(f"v10 阶段证据不成立：{error}")
        else:
            code = error.code if isinstance(error, V7ContractError) else "planIntegrityFailure"
            if code not in row.get("hard_validation_codes", []):
                failures.append(f"v10 失败未如实记录 {code}：{error}")
    if not valid_integer(row.get("repair_attempt_count")) or row["repair_attempt_count"] != repairs:
        failures.append("v10 修复次数不等于已解码核对稿对首稿的实际变更尝试")
    if fallback and row.get("model_output") != source:
        failures.append("v10 回退必须交付完整 canonical 原文，不能提交部分候选")
    return allowed, failures


def decode_v11_light_payload(raw: str, source: str) -> dict:
    """仅审计请求原文锚点；v11 不向模型发送上下文、补丁或复核指令。"""
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("v11 请求不允许重复字段")
            result[key] = value
        return result

    payload = json.loads(raw, object_pairs_hook=unique_object)
    if (not isinstance(payload, dict) or set(payload) != {"canonical_text"}
            or not isinstance(payload["canonical_text"], str)
            or payload["canonical_text"].encode("utf-8") != source.encode("utf-8")):
        raise ValueError("v11 请求必须且只能包含逐字相同的 canonical_text")
    return payload


def v11_foundation_whitespace_only(text: str) -> bool:
    """对应 Foundation whitespacesAndNewlines；不改变旧协议的 Character 判定。"""
    # 本机 Foundation 将 U+200B 计为空白，Character.isWhitespace 则不计入。
    return all(c == "\u200b" or swift_character_is_whitespace(c) for c in text)


def v11_light_stage_contract(row: dict, payloads: list) -> tuple[list[str], list[str]]:
    """单次原始正文的工程证据；不判断语义、长度比例或润色质量。"""
    source, stages, fallback = row["canonical_input"], row["stage_responses"], row.get("fallback_used")
    failures = []
    if not valid_integer(row.get("repair_attempt_count")) or row["repair_attempt_count"] != 0:
        failures.append("v11 单次轻度必须明确记录零次修复")
    if any(payload is None for payload in payloads):
        failures.append("v11 请求原文锚点不可审计")
    if any(not valid_integer(stage.get("attempt_ordinal")) for stage in stages):
        failures.append("v11 阶段序号必须是真正的整数")
    if fallback:
        if row.get("model_output") != source:
            failures.append("v11 回退必须交付完整 canonical 原文")
        expected_codes = {"validationFailed": {"emptyOutput", "unsafeCharacters", "abnormalLength"},
                          "timeout": {"emptyOutput"}, "requestFailed": {"emptyOutput"}}
        reason, codes = row.get("failure_reason"), row.get("hard_validation_codes")
        if (not isinstance(reason, str) or reason not in expected_codes or not isinstance(codes, list)
                or len(codes) != 1 or not isinstance(codes[0], str) or codes[0] not in expected_codes[reason]):
            failures.append("v11 回退原因与传输安全错误码不匹配")
    elif row.get("failure_reason") is not None or row.get("hard_validation_codes") != []:
        failures.append("v11 成功输出同时声称请求或传输安全失败")

    rejected = None
    if stages and stages[0].get("status") == "succeeded":
        raw = stages[0].get("response_text")
        try:
            raw_bytes = raw.encode("utf-8")
        except (AttributeError, UnicodeError):
            failures.append("v11 实际响应不是有效 UTF-8 正文")
        else:
            code = ("emptyOutput" if v11_foundation_whitespace_only(raw) else "unsafeCharacters" if v7_unsafe_characters(raw)
                    else "abnormalLength" if len(raw_bytes) > 1_048_576 else None)
            if code:
                rejected = raw
                if (not fallback or row.get("failure_reason") != "validationFailed"
                        or row.get("hard_validation_codes") != [code]):
                    failures.append(f"v11 实际响应未按 {code} 整篇回退")
            elif fallback and row.get("failure_reason") == "validationFailed":
                failures.append("v11 完整有效响应没有传输安全失败证据，不能冒充校验回退")
            elif not fallback and row.get("model_output") != raw:
                failures.append("v11 交付未逐字保留实际响应的完整 UTF-8 正文")
    if row.get("rejected_model_output") != rejected:
        failures.append("v11 被拒绝正文未绑定实际响应，或无正文失败伪造了被拒绝稿")
    return ["voicePolishRender"], failures


def decode_v12_standard_payload(raw: str, source: str, expected_requirements: str = "") -> dict:
    """结构请求的可选偏好必须来自独立预期，不能由请求自己声明授权来源。"""
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("v12 结构请求不允许重复字段")
            result[key] = value
        return result

    if not isinstance(expected_requirements, str):
        raise ValueError("v12 显式偏好来源必须是字符串")
    expected = {"canonical_text": source}
    if not v11_foundation_whitespace_only(expected_requirements):
        expected["additional_requirements"] = expected_requirements
    payload = json.loads(raw, object_pairs_hook=unique_object)
    if (not isinstance(payload, dict) or set(payload) != set(expected)
            or any(not isinstance(payload[key], str)
                   or payload[key].encode("utf-8") != value.encode("utf-8") for key, value in expected.items())):
        raise ValueError("v12 结构请求必须逐字绑定首稿及独立提供的显式偏好")
    return payload


def v12_standard_stage_contract(row: dict, payloads: list) -> tuple[list[str], list[str]]:
    """两次串行完整正文的证据契约；不恢复旧补丁、布局或语义门禁。"""
    source, stages, fallback = row["canonical_input"], row["stage_responses"], row.get("fallback_used")
    allowed, failures = ["voicePolishRender", "voicePolishStructured"], []
    if not valid_integer(row.get("repair_attempt_count")) or row["repair_attempt_count"] != 0:
        failures.append("v12 标准必须明确记录零次修复")
    if any(payload is None for payload in payloads):
        failures.append("v12 标准请求正文不可审计")
    if any(not valid_integer(stage.get("attempt_ordinal")) for stage in stages):
        failures.append("v12 标准阶段序号必须是真正的整数")
    if row.get("diagnostic_codes") != []:
        failures.append("v12 标准没有额外语义诊断阶段")

    reason, codes = row.get("failure_reason"), row.get("hard_validation_codes")
    if fallback:
        if row.get("model_output") != source:
            failures.append("v12 标准失败必须交付最初完整 canonical 原文，不能交付首稿")
        expected_codes = {"validationFailed": {"emptyOutput", "unsafeCharacters", "abnormalLength"},
                          "timeout": {"emptyOutput"}, "requestFailed": {"emptyOutput"}}
        if (not isinstance(reason, str) or reason not in expected_codes or not isinstance(codes, list)
                or len(codes) != 1 or not isinstance(codes[0], str) or codes[0] not in expected_codes[reason]):
            failures.append("v12 标准回退原因与传输安全错误码不匹配")
    elif reason is not None or codes != []:
        failures.append("v12 标准成功输出同时声称请求或传输安全失败")

    draft, stopped, returned_failure_code = None, False, None
    for index, stage in enumerate(stages):
        if stopped:
            failures.append("v12 标准在前一阶段失败后仍发起了下一请求")
        if index and stages[index - 1].get("status") != "succeeded":
            failures.append("v12 结构整理未等待校对正文成功返回")
        if index:
            try:
                previous_end = datetime.fromisoformat(stages[index - 1]["finished_at"].replace("Z", "+00:00"))
                current_start = datetime.fromisoformat(stage["started_at"].replace("Z", "+00:00"))
                if current_start < previous_end:
                    failures.append("v12 两阶段请求的时间记录发生重叠")
            except (KeyError, AttributeError, TypeError, ValueError):
                failures.append("v12 缺少可证明串行执行的阶段时间")
        if stage.get("status") != "succeeded":
            stopped = True
            continue
        raw = stage.get("response_text")
        try:
            raw_bytes = raw.encode("utf-8")
        except (AttributeError, UnicodeError):
            failures.append("v12 实际响应不是有效 UTF-8 正文")
            stopped = True
            continue
        draft = raw
        code = ("emptyOutput" if v11_foundation_whitespace_only(raw) else "unsafeCharacters" if v7_unsafe_characters(raw)
                else "abnormalLength" if len(raw_bytes) > 1_048_576 else None)
        if code:
            stopped = True
            returned_failure_code = code
            if not fallback or reason != "validationFailed" or codes != [code]:
                failures.append(f"v12 标准实际响应未按 {code} 整篇回退")

    if fallback:
        if reason == "validationFailed" and returned_failure_code is None:
            # 没有完整正文时，仅客户端的截断/超限异常会映射为 abnormalLength。
            if not stages or stages[-1].get("status") == "succeeded" or codes != ["abnormalLength"]:
                failures.append("v12 标准没有对应的不安全正文或截断请求，不能冒充校验回退")
        # 请求失败不产生新正文；第二请求失败时，Swift 保留第一实际稿供显式诊断。
        if row.get("rejected_model_output") != draft:
            failures.append("v12 标准被拒绝稿未绑定最近实际返回的完整正文")
    else:
        if row.get("rejected_model_output") is not None:
            failures.append("v12 标准成功结果伪造了被拒绝稿")
        if len(stages) != 2 or stopped or row.get("model_output") != draft:
            failures.append("v12 标准成功必须逐字交付第二次实际返回的完整正文")
    return allowed, failures


def v7_payload_field_failures(payload: dict, mode: str, stage_index: int, *,
                              separates_content_review: bool = False) -> list[str]:
    """按当前 Payload 构造闭合字段；本 Runner 的 nil 可选值必须省略。"""
    required = {"schema_version", "mode", "canonical_text", "source_segments", "writing_scene",
                "authorized_context", "user_preferences"}
    if stage_index:
        required |= {"draft_text", "changes", "review_focus", "review_focus_total"}
        if mode == "standard" and not (separates_content_review and stage_index == 1):
            required.add("layout_segments")
    optional = {"validation_codes"} if mode == "standard" and stage_index == 1 else set()
    fields = set(payload)
    failures = []
    if fields - required - optional:
        failures.append("v7 请求含当前阶段不会生成的额外字段：" + ", ".join(sorted(fields - required - optional)))
    if required - fields:
        failures.append("v7 请求缺少当前阶段必须生成的字段：" + ", ".join(sorted(required - fields)))
    if "validation_codes" in fields and "validation_codes" in optional:
        # contentCodes 的实际生成路径只有这五种，按 outputCodes 顺序后追加重复保护。
        # 其他 VoicePolishValidationCode 虽是合法枚举，也不属于本阶段可生成的提示。
        possible = ["emptyOutput", "unsafeCharacters", "abnormalLength", "planIntegrityFailure", "missingProtectedFact"]
        codes = payload["validation_codes"]
        if (not isinstance(codes, list) or not codes or any(not isinstance(c, str) or c not in possible for c in codes)
                or len(set(codes)) != len(codes) or codes != sorted(codes, key=possible.index)):
            failures.append("v7 validation_codes 不符合当前 contentCodes 的非空枚举数组与生成顺序")
    return failures


def v7_stage_contract(row: dict, payloads: list, mode: str, version: int = 7) -> tuple[list[str], list[str]]:
    """保留 v7/v8 历史协议；v9 轻度只纠错，标准继续先核内容再布局。"""
    if version == 10 and mode == "light":
        return v10_light_stage_contract(row, payloads)
    if version == 11 and mode == "light":
        return v11_light_stage_contract(row, payloads)
    source, stages, fallback = row["canonical_input"], row["stage_responses"], row.get("fallback_used")
    light_scope = version == 9 and mode == "light"
    separates_content_review = version in (8, 9, 10, 11) and mode == "standard" and v4_source_review_risk(source)
    allowed = ["voicePolishFast" if mode == "light" else "voicePolishRender"]
    failures, repairs, output = [], 0, None

    def bind_draft(index, draft):
        payload = payloads[index]
        if not isinstance(payload, dict) or payload.get("draft_text") != draft:
            failures.append("v7 复核请求未绑定实际内容稿")
        if not isinstance(payload, dict) or not complete_v6_review_focus(source, draft, payload):
            failures.append("v7 复核请求未绑定完整差异和实际上下文")
        includes_layout = mode == "standard" and not (separates_content_review and index == 1)
        segments = v7_structure_segments(draft) if includes_layout else None
        if includes_layout and (not isinstance(payload, dict) or payload.get("layout_segments") != segments):
            failures.append("v7 layout_segments 未逐字绑定程序从实际稿重建的全部片段")
        return segments

    for index, payload in enumerate(payloads):
        if not isinstance(payload, dict):
            failures.append("v7 请求载荷不可审计")
            continue
        failures.extend(v7_payload_field_failures(payload, mode, index,
            separates_content_review=separates_content_review))
        if index == 0 and any(k in payload for k in ("draft_text", "changes", "review_focus", "review_focus_total", "layout_segments")):
            failures.append("v7 首轮不得携带稿件、差异、焦点或结构片段")
        if mode == "light" and "layout_segments" in payload:
            failures.append("v7 轻度请求不得携带结构片段")
    try:
        if stages and stages[0].get("status") == "succeeded":
            initial = decode_v7_initial(stages[0]["response_text"])
            source_risk = v9_light_source_review_risk(source) if light_scope else v4_source_review_risk(source)
            requires = mode == "standard" or source_risk or v4_requires_semantic_review(initial["edits"], source)
            draft = apply_recorded_edits(source, stages[0]["response_text"], editing_prompt_version=version,
                allows_reviewed_directives=requires, allows_reviewed_source_corrections=requires,
                allows_directive_edits=not light_scope)
            output = draft
            # 生产标准在生成复核请求前验证实际片段；失败不得伪报二次请求。
            if mode == "standard": v7_structure_segments(draft)
            if requires: allowed.append("voicePolishAnalyze")
            if requires and len(stages) >= 2:
                segments = bind_draft(1, draft)
                if stages[1].get("status") == "succeeded":
                    assessment = (decode_v9_light_review(stages[1]["response_text"]) if light_scope
                                  else decode_v7_review(stages[1]["response_text"], source, segments))
                    if assessment["edits"] or separates_content_review:
                        if assessment["edits"]:
                            repairs = 1
                            draft = apply_recorded_edits(draft, json.dumps({"edits": assessment["edits"]}, ensure_ascii=False),
                                editing_prompt_version=version, allows_reviewed_directives=True,
                                allows_reviewed_source_corrections=True, original_source=source,
                                allows_directive_edits=not light_scope)
                        if v4_contains_editor_instruction(assessment, draft, 5):
                            raise V7ContractError("v7 当前编辑要求仍留在修复稿")
                        if mode == "standard": v7_structure_segments(draft)
                        output = draft
                        allowed.append("voicePolishAnalyze")
                        if len(stages) >= 3:
                            segments = bind_draft(2, draft)
                            if stages[2].get("status") == "succeeded":
                                final = (decode_v9_light_review(stages[2]["response_text"]) if light_scope
                                         else decode_v7_review(stages[2]["response_text"], source, segments))
                                if final["edits"] or v4_contains_editor_instruction(final, draft, 5):
                                    raise V7ContractError("v7 第三轮未空补丁确认实际稿")
                                output = v7_render_layout(final["layout"], segments) if mode == "standard" else draft
                    else:
                        if v4_contains_editor_instruction(assessment, draft, 5):
                            raise V7ContractError("v7 当前编辑要求残留却空补丁放行")
                        output = v7_render_layout(assessment["layout"], segments) if mode == "standard" else draft
            if not fallback and row.get("model_output") != output:
                raise V7ContractError("v7 最终输出不等于真实局部补丁及完整布局逐字拼装结果")
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        if not fallback:
            failures.append(f"v7 阶段证据不成立：{error}")
        else:
            code = error.code if isinstance(error, V7ContractError) else "planIntegrityFailure"
            if code not in row.get("hard_validation_codes", []):
                failures.append(f"v7 失败未如实记录 {code}：{error}")
    if not valid_integer(row.get("repair_attempt_count")) or row["repair_attempt_count"] != repairs:
        failures.append("v7 repair_attempt_count 未如实记录成功或失败的本地修复尝试")
    if fallback and row.get("model_output") != source:
        failures.append("v7 回退必须交付完整 canonical 原文")
    return allowed, failures


def v4_stage_contract(row: dict, payloads: list, mode: str, version: int = 4) -> tuple[list[str], list[str]]:
    """回放候选真实请求链；模型质量失败保留为 fallback，不伪造为来源证据成功。"""
    source, stages = row["canonical_input"], row["stage_responses"]
    fallback = row.get("fallback_used")
    allowed = ["voicePolishFast" if mode == "light" else "voicePolishRender"]
    failures, repairs = [], 0
    draft = None

    def bind_draft(index: int, current: str) -> None:
        payload = payloads[index]
        if not isinstance(payload, dict) or payload.get("draft_text") != current:
            failures.append("v4 复核请求未绑定实际稿")
        if not isinstance(payload, dict) or not complete_change_evidence(source, current, payload.get("changes")):
            failures.append("v4 复核请求未完整绑定原文与实际稿差异")
        if version == 6 and (not isinstance(payload, dict) or not complete_v6_review_focus(source, current, payload)):
            failures.append("v6 优先差异未绑定完整有序变化、实质排序、范围或逐字上下文")

    try:
        if stages and stages[0].get("status") == "succeeded":
            if payloads[0] is None or any(payloads[0].get(k) is not None for k in ("draft_text", "changes")):
                failures.append("v4 首轮请求伪装成复核稿")
            if mode == "light":
                initial = json.loads(stages[0]["response_text"])
                if not isinstance(initial, dict) or set(initial) != {"edits"}:
                    raise ValueError("初轮 light 必须为独立 edits 对象")
                edits = decode_v4_edits(initial["edits"])
                requires = v4_source_review_risk(source) or v4_requires_semantic_review(edits, source)
                draft = apply_recorded_edits(source, stages[0]["response_text"], editing_prompt_version=version,
                                              allows_reviewed_directives=requires)
            else:
                requires = True
                draft = v4_plain_text(stages[0]["response_text"], source)
            if requires:
                allowed.append("voicePolishAnalyze")
            if len(stages) >= 2 and requires:
                bind_draft(1, draft)
                if stages[1].get("status") == "succeeded":
                    assessment = decode_versioned_review(stages[1]["response_text"], source, version)
                    if assessment["edits"]:
                        repairs = 1
                        response = json.dumps({"edits": assessment["edits"]}, ensure_ascii=False)
                        if mode == "standard":
                            if any(edit["kind"] != "content" or not edit.get("evidence")
                                   or edit["evidence"] not in source for edit in assessment["edits"]):
                                raise ValueError("标准修复缺少 content 及原文 evidence")
                        draft = apply_recorded_edits(draft, response,
                            editing_prompt_version=version if mode == "light" else None,
                            allows_reviewed_directives=True, original_source=source)
                        if v4_contains_editor_instruction(assessment, draft, version):
                            raise ValueError("已识别当前编辑要求仍留在修复稿")
                        allowed.append("voicePolishAnalyze")
                        if len(stages) >= 3:
                            bind_draft(2, draft)
                            if stages[2].get("status") == "succeeded":
                                confirmation = decode_versioned_review(stages[2]["response_text"], source, version)
                                if confirmation["edits"] or v4_contains_editor_instruction(confirmation, draft, version):
                                    raise ValueError("第三轮未确认空补丁或仍留当前编辑要求")
                    elif v4_contains_editor_instruction(assessment, draft, version):
                        raise ValueError("当前编辑要求未处理却空编辑通过")
            if not fallback and row.get("model_output") != draft:
                raise ValueError("最终输出不等于实际补丁逐级应用结果")
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        if not fallback:
            failures.append(f"v{version} 实际稿/复核/修复证据不成立：{error}")
        elif isinstance(error, InvalidV5Review) and "invalidStructuredResponse" not in row.get("hard_validation_codes", []):
            failures.append("v5 复核解析失败未如实记录 invalidStructuredResponse")
    if row.get("repair_attempt_count") != repairs or not valid_integer(row.get("repair_attempt_count")):
        failures.append("v4 repair_attempt_count 未如实记录成功或失败的本地修复尝试")
    if fallback and row.get("model_output") != source:
        failures.append("v4 回退交付了未经确认的局部稿")
    return allowed, failures


def validate_report(report: dict, receipts: list[dict], inputs: list[dict], *, mode: str,
                    expected: dict, nonce: str, process_id: int,
                    started: datetime, finished: datetime) -> tuple[list[str], list[str]]:
    """证据失败与质量失败分开；这里不自动授予 direct_send 或发布通过。"""
    failures, quality = [], []
    is_v12 = expected["editing_prompt_version"] == 12
    is_v13 = expected["editing_prompt_version"] == 13
    full_text_protocol = is_v12 or is_v13
    plain_text_protocol = full_text_protocol or (expected["editing_prompt_version"] == 11 and mode == "light")
    pairs = {
        "schema_version": 5, "status": "complete", "mode": mode, "quality_mode": mode,
        "run_nonce": nonce, "process_id": process_id, "run_input_sha256": expected["run_input_sha256"],
        "executable_sha256": expected["executable_sha256"], "commit": expected["source_commit"],
        "requested_input_count": len(inputs), "completed_input_count": len(inputs),
        "prompt_version": expected["prompt_version"],
        "latency_measurement_scope": "asr_final_fixture_to_output",
        "provider": "none" if mode == "direct" else expected["provider"],
    }
    if mode != "direct":
        pairs.update(model=expected["model"], endpoint_url=expected["endpoint_url"],
                     editing_prompt_version=expected["editing_prompt_version"])
    for key, value in pairs.items():
        if report.get(key) != value:
            failures.append(f"顶层 {key} 与冻结预期不一致")
    if report.get("error") is not None:
        failures.append("候选报告包含运行错误；不计为通过")
    if mode == "direct" and any(report.get(key) is not None for key in ("model", "endpoint_url", "editing_prompt_version")):
        failures.append("直出冒充模型或编辑协议调用")
    audit_time(report.get("run_at"), started, finished, "报告开始", failures)
    audit_time(report.get("finished_at"), started, finished, "报告结束", failures)
    cases = report.get("cases", [])
    if not isinstance(cases, list) or any(not isinstance(x, dict) for x in cases):
        return failures + ["cases 不是对象数组"], quality
    actual = {x.get("test_input_id"): x for x in cases}
    ids = {x["test_input_id"] for x in inputs}
    if len(cases) != len(actual) or set(actual) != ids:
        failures.append("结果 ID 集合缺失、重复或被替换")
    for item in inputs:
        tid = item["test_input_id"]
        row = actual.get(tid, {})
        for key in ("base_case_id", "input_kind", "writing_scene", "spoken_input", "segment_texts"):
            if row.get(key) != item[key]:
                failures.append(f"{tid}: 原始 {key} 被改变")
        if row.get("context_fixture") != legacy.expected_context_fixture(item):
            failures.append(f"{tid}: 上下文夹具被改变")
        route = {"direct": "direct", "light": "fast", "standard": "structured"}[mode]
        if row.get("mode") != mode or row.get("executed_route") != route or row.get("detected_route") != route:
            failures.append(f"{tid}: 选择模式与实际路径错配")
        if row.get("segment_count") != len(item["segment_texts"]):
            failures.append(f"{tid}: 原始分段数错配")
        for field in ("llm_call_count", "llm_attempt_count", "latency_milliseconds", "internal_chunk_count"):
            if not valid_integer(row.get(field)):
                failures.append(f"{tid}: {field} 无有效非负整数证据")
        begin = audit_time(row.get("started_at"), started, finished, tid, failures)
        end = audit_time(row.get("finished_at"), started, finished, tid, failures)
        if begin and end and end < begin:
            failures.append(f"{tid}: 结束早于开始")
        if not isinstance(row.get("model_output"), str):
            failures.append(f"{tid}: 缺少实际输出")
        if not isinstance(row.get("fallback_used"), bool):
            failures.append(f"{tid}: 缺少明确回退状态")
        for field in ("hard_validation_codes", "diagnostic_codes"):
            if not isinstance(row.get(field), list) or any(not isinstance(x, str) for x in row[field]):
                failures.append(f"{tid}: {field} 类型不正确")
        if row.get("fallback_used") or row.get("hard_validation_codes") or row.get("failure_reason"):
            quality.append(f"{tid}: 回退、硬校验失败或处理失败，不能算润色成功")
        stages = row.get("stage_responses")
        if not isinstance(stages, list) or any(not isinstance(s, dict) for s in stages):
            failures.append(f"{tid}: 缺少阶段审计数组")
            continue
        if mode == "direct":
            if (full_text_protocol or expected["editing_prompt_version"] in (4, 5, 6, 7, 8, 9, 10, 11)) and (
                not valid_integer(row.get("repair_attempt_count")) or row["repair_attempt_count"] != 0
            ):
                failures.append(f"{tid}: v4 直出必须明确记录整数零次修复尝试")
            if stages or any(row.get(k) != 0 for k in ("llm_call_count", "llm_attempt_count", "internal_chunk_count")):
                failures.append(f"{tid}: 直出必须为零调用、零尝试、零模型切片")
            canonical = legacy.canonical_input(item)
            if row.get("canonical_input") != canonical or row.get("model_output") != canonical.strip():
                failures.append(f"{tid}: 直出偏离既有术语纠正及首尾清理基线")
            if row.get("resolved_entities") != [] or row.get("canonical_segments") != []:
                failures.append(f"{tid}: 直出不得伪造上下文实体解析")
            if row.get("pre_resolution_canonical_input") != canonical:
                failures.append(f"{tid}: 直出canonical来源证据不完整")
            continue
        prepared_source, frozen_segments = None, None
        if full_text_protocol or expected["editing_prompt_version"] in (3, 4, 5, 6, 7, 8, 9, 10, 11):
            try:
                prepared_source, frozen_segments = frozen_input_envelope(item)
            except (ValueError, KeyError, TypeError) as error:
                failures.append(f"{tid}: 冻结输入不能可靠重建生产分段：{error}")
        expected_mappings, mapping_failures = resolved_entity_evidence(item, row, prepared_source=prepared_source)
        failures += mapping_failures
        canonical_segments = row.get("canonical_segments")
        reported_segments = ([{"id": segment.get("id"), "text": segment.get("text")}
                              for segment in canonical_segments]
                             if isinstance(canonical_segments, list)
                             and all(isinstance(segment, dict) for segment in canonical_segments) else None)
        if full_text_protocol or expected["editing_prompt_version"] in (3, 4, 5, 6, 7, 8, 9, 10, 11):
            if frozen_segments is None or reported_segments != frozen_segments:
                failures.append(f"{tid}: canonical 分段的 ID、边界或正文不符合冻结输入的确定性构造")
            expected_segments = frozen_segments
        else:
            expected_segments = reported_segments
        if (not valid_integer(row.get("llm_attempt_count")) or row["llm_attempt_count"] < len(stages)
                or (not row.get("fallback_used") and row["llm_attempt_count"] != len(stages))):
            failures.append(f"{tid}: 尝试数与阶段记录不一致")
        if row.get("internal_chunk_count") != 1:
            failures.append(f"{tid}: 新润色协议必须记录一次整段输入，不冒充旧分片")
        if valid_integer(row.get("llm_attempt_count")) and valid_integer(row.get("llm_call_count")):
            if row["llm_call_count"] > row["llm_attempt_count"]:
                failures.append(f"{tid}: 成功调用多于尝试")
        successful, payloads = [], []
        for ordinal, stage in enumerate(stages, 1):
            if stage.get("attempt_ordinal") != ordinal or stage.get("status") not in {"succeeded", "failed", "running"}:
                failures.append(f"{tid}: 阶段序号或状态不正确")
            audit_time(stage.get("started_at"), started, finished, f"{tid} 阶段开始", failures)
            if stage.get("status") != "running":
                audit_time(stage.get("finished_at"), started, finished, f"{tid} 阶段结束", failures)
            if not valid_integer(stage.get("latency_milliseconds")):
                failures.append(f"{tid}: 阶段失败或成功耗时缺失")
            if stage.get("status") == "succeeded":
                successful.append(stage)
                if stage.get("failure_reason") is not None:
                    failures.append(f"{tid}: 成功阶段同时声称失败")
            elif stage.get("response_text") != "" or (stage.get("status") == "failed" and not stage.get("failure_reason")):
                failures.append(f"{tid}: 失败阶段伪造正文或缺少失败原因")
            try:
                if plain_text_protocol:
                    # v12 标准第二请求只绑定第一实际正文；不能再次绑定原稿或塞入旧复核字段。
                    body_source = (stages[ordinal - 2].get("response_text")
                                   if is_v12 and mode == "standard" and ordinal > 1 else row["canonical_input"])
                    if is_v12 and mode == "standard" and ordinal > 1:
                        # 当前冻结 Runner 明确构造空偏好；不能从 payload 反推 expected_requirements。
                        payloads.append(decode_v12_standard_payload(stage["request_payload"], body_source,
                                                                   expected_requirements=""))
                    else:
                        payloads.append(decode_v11_light_payload(stage["request_payload"], body_source))
                    continue
                payload = json.loads(stage["request_payload"])
                if payload.get("mode") != mode or payload.get("canonical_text") != row.get("canonical_input"):
                    failures.append(f"{tid}: 阶段请求模式或 canonical_text 不匹配")
                if (payload.get("schema_version") != expected["editing_prompt_version"]
                        or payload.get("writing_scene") != item["writing_scene"]
                        or payload.get("authorized_context") != expected_mappings
                        or payload.get("user_preferences") != "" or payload.get("style_profile") is not None):
                    failures.append(f"{tid}: 阶段请求带入非冻结上下文、个人偏好或错误协议")
                if expected["editing_prompt_version"] in (3, 4, 5, 6, 7, 8, 9, 10, 11) and (
                    expected_segments is None or payload.get("source_segments") != expected_segments
                ):
                    failures.append(f"{tid}: v3 阶段 source_segments 未逐项保留 canonical 段的 ID、正文和顺序")
                if expected["editing_prompt_version"] in (6, 7, 8, 9, 10, 11) and ordinal == 1 and any(
                    payload.get(k) is not None for k in ("review_focus", "review_focus_total")
                ):
                    failures.append(f"{tid}: v6 首轮请求不得携带复核优先差异")
                payloads.append(payload)
            except (KeyError, TypeError, ValueError, AttributeError):
                payloads.append(None)
                failures.append(f"{tid}: 阶段请求不是可审计三档 JSON")
        tasks = [s.get("task") for s in stages]
        requires_light_review = False
        if mode == "light" and expected["editing_prompt_version"] in (2, 3):
            if row.get("fallback_used") and row.get("model_output") != row.get("canonical_input"):
                failures.append(f"{tid}: 轻度回退却交付了未通过核对的局部稿")
            if stages and stages[0].get("status") == "succeeded":
                try:
                    initial = json.loads(stages[0]["response_text"])
                    if (not isinstance(initial, dict) or set(initial) != {"edits"}
                            or not isinstance(initial["edits"], list)
                            or any(not isinstance(edit, dict) for edit in initial["edits"])):
                        raise ValueError("初轮编辑结构错误")
                    requires_light_review = any(edit.get("kind") in {"word", "correction", "directive"}
                                                for edit in initial["edits"])
                except (KeyError, TypeError, ValueError):
                    if not row.get("fallback_used"):
                        failures.append(f"{tid}: 无法由首轮真实补丁确定轻度核对要求")
            if payloads and payloads[0] is not None and any(payloads[0].get(k) is not None for k in ("draft_text", "changes")):
                failures.append(f"{tid}: 轻度初轮请求伪装成复核稿")
            if len(stages) >= 2:
                try:
                    preview = apply_recorded_edits(row["canonical_input"], stages[0]["response_text"],
                                                   editing_prompt_version=expected["editing_prompt_version"])
                    review_payload = payloads[1]
                    if review_payload.get("draft_text") != preview:
                        failures.append(f"{tid}: 轻度核对未读取首轮补丁的实际局部稿")
                    if not complete_change_evidence(row["canonical_input"], preview, review_payload.get("changes")):
                        failures.append(f"{tid}: 轻度核对缺少与完整来源及实际稿对应的全部差异")
                    if not row.get("fallback_used") and json.loads(stages[1]["response_text"]) != {"edits": []}:
                        failures.append(f"{tid}: 轻度核对未空编辑确认却交付，或擅自执行核对修复")
                except (KeyError, TypeError, ValueError, AttributeError):
                    failures.append(f"{tid}: 轻度核对无法绑定原文、局部稿、差异和实际响应")
        if is_v13:
            allowed, stage_failures = v11_light_stage_contract(row, payloads)
            allowed = ["voicePolishRender" if mode == "light" else "voicePolishStructured"]
            failures.extend(f"{tid}: {failure.replace('v11', 'v13')}" for failure in stage_failures)
            if row.get("diagnostic_codes") != []:
                failures.append(f"{tid}: v13 没有额外语义诊断阶段")
            if valid_integer(row.get("llm_attempt_count")) and row["llm_attempt_count"] > 1:
                failures.append(f"{tid}: v13 自动润色最多调用一次")
        elif is_v12:
            allowed, stage_failures = (v11_light_stage_contract(row, payloads) if mode == "light"
                                       else v12_standard_stage_contract(row, payloads))
            failures.extend(f"{tid}: {failure}" for failure in stage_failures)
            if valid_integer(row.get("llm_attempt_count")) and row["llm_attempt_count"] > len(allowed):
                failures.append(f"{tid}: v12 尝试数超出模式的固定调用预算")
        elif expected["editing_prompt_version"] in (4, 5, 6, 7, 8, 9, 10, 11):
            allowed, stage_failures = (v7_stage_contract(row, payloads, mode, expected["editing_prompt_version"]) if expected["editing_prompt_version"] in (7, 8, 9, 10, 11)
                                       else v4_stage_contract(row, payloads, mode, expected["editing_prompt_version"]))
            failures.extend(f"{tid}: {failure}" for failure in stage_failures)
            if valid_integer(row.get("llm_attempt_count")) and row["llm_attempt_count"] > len(allowed):
                failures.append(f"{tid}: v4 尝试数超出真实补丁和原文风险允许的调用预算")
        elif mode == "light":
            allowed = ["voicePolishFast"] + (["voicePolishAnalyze"] if requires_light_review else [])
            if expected["editing_prompt_version"] not in (1, 2, 3):
                failures.append(f"{tid}: 尚未定义该轻度协议版本的阶段契约")
            if valid_integer(row.get("llm_attempt_count")) and row["llm_attempt_count"] > len(allowed):
                failures.append(f"{tid}: 轻度尝试数超出该补丁风险允许的调用预算")
        else:
            allowed = ["voicePolishRender", "voicePolishAnalyze", "voicePolishAnalyze"]
        if tasks != allowed[:len(tasks)] or len(tasks) > len(allowed):
            failures.append(f"{tid}: 阶段任务顺序与模式不对应")
        minimum_stages = len(allowed) if full_text_protocol or mode == "light" or expected["editing_prompt_version"] in (4, 5, 6, 7, 8, 9, 10, 11) else 2
        if not row.get("fallback_used") and (len(tasks) < minimum_stages or any(s.get("status") != "succeeded" for s in stages)):
            failures.append(f"{tid}: 成功输出缺少完整模式链路")
        if row.get("llm_call_count") != len(successful):
            failures.append(f"{tid}: 成功阶段数与调用数不一致")
        case_receipts = [r for r in receipts if r.get("test_input_id") == tid]
        if len(case_receipts) != len(successful):
            failures.append(f"{tid}: 成功阶段缺少一一对应 Provider 回执")
        for stage, receipt in zip(successful, case_receipts):
            if plain_text_protocol:
                try:
                    legacy.sha256_text(stage.get("response_text", ""))
                except (AttributeError, UnicodeError):
                    failures.append(f"{tid}: 正文响应不能绑定有效 UTF-8 哈希")
                    continue
            if (receipt.get("llm_task") != stage.get("task")
                    or receipt.get("response_text_sha256") != legacy.sha256_text(stage.get("response_text", ""))):
                failures.append(f"{tid}: Provider 回执任务或响应哈希与阶段不匹配")
        if not full_text_protocol and not row.get("fallback_used") and successful and expected["editing_prompt_version"] not in (4, 5, 6, 7, 8, 9, 10, 11):
            try:
                if mode == "light":
                    if apply_recorded_edits(row["canonical_input"], successful[0]["response_text"],
                                            editing_prompt_version=expected["editing_prompt_version"]) != row["model_output"]:
                        failures.append(f"{tid}: 最终轻度输出不是实际Provider补丁的应用结果")
                else:
                    last = successful[-1]
                    if (json.loads(last["request_payload"]).get("draft_text") != row["model_output"]
                            or json.loads(last["response_text"]) != {"edits": []}):
                        failures.append(f"{tid}: 标准最终稿未被最后冷复核确认")
            except (ValueError, KeyError, TypeError, AttributeError):
                failures.append(f"{tid}: 不能将实际阶段响应对应到最终输出")
    if mode == "direct":
        if receipts:
            failures.append("直出必须没有 Provider 回执")
    else:
        failures += legacy.provider_audit_failures(
            receipts, expected_run_nonce=nonce, expected_provider=expected["provider"],
            expected_model=expected["model"], expected_endpoint_url=expected["endpoint_url"],
            expected_test_ids=ids, actual_by_id=actual, run_started_at=started, run_finished_at=finished,
        )
    return failures, quality


def performance_summary(report: dict, document: dict) -> dict:
    origins = {x["test_input_id"]: x["suite"] for x in document["input_provenance"]}
    groups = {}
    for row in report.get("cases", []):
        group = f"{origins.get(row.get('test_input_id'), 'unknown')}/{row.get('input_kind')}"
        groups.setdefault(group, []).append(row)
    result = {}
    for group, rows in groups.items():
        latencies = sorted(x["latency_milliseconds"] for x in rows if valid_integer(x.get("latency_milliseconds")))
        result[group] = {
            "input_count": len(rows), "unique_spoken_texts": len({x.get("spoken_input") for x in rows}),
            "unique_input_fixtures": len({object_sha({k: x.get(k) for k in ('spoken_input', 'segment_texts', 'context_fixture')}) for x in rows}),
            "p50_milliseconds": statistics.median(latencies) if latencies else None,
            "p95_milliseconds": latencies[max(0, (95 * len(latencies) + 99) // 100 - 1)] if latencies else None,
            "llm_calls": sum(x.get("llm_call_count", 0) for x in rows if valid_integer(x.get("llm_call_count"))),
            "llm_attempts": sum(x.get("llm_attempt_count", 0) for x in rows if valid_integer(x.get("llm_attempt_count"))),
            "fallback_count": sum(x.get("fallback_used") is True for x in rows),
            "semantic_quality_status": "待独立逐条评审",
        }
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("dataset", "contracts", "candidate-app", "build-manifest", "run-root"):
        parser.add_argument("--" + flag, type=Path, required=True)
    for flag in ("build-manifest-sha256", "source-commit", "source-tree", "executable-sha256", "dataset-sha256", "contract-sha256", "designated-requirement-sha256"):
        parser.add_argument("--expected-" + flag, required=True)
    parser.add_argument("--expected-provider")
    parser.add_argument("--expected-model")
    parser.add_argument("--expected-endpoint-url")
    parser.add_argument("--expected-prompt-version", type=int, required=True)
    parser.add_argument("--expected-editing-prompt-version", type=int, required=True)
    parser.add_argument("--modes", nargs="+", choices=MODES, default=list(MODES))
    parser.add_argument("--test-ids", nargs="+")
    parser.add_argument("--run-timeout-seconds", type=int, default=21600)
    args = parser.parse_args()
    if len(set(args.modes)) != len(args.modes) or args.run_timeout_seconds < 1:
        parser.error("模式不得重复，超时必须为正数")
    if set(args.modes) - {"direct"}:
        if not args.expected_provider or not args.expected_model or not args.expected_endpoint_url:
            parser.error("润色模式必须提供冻结 Provider、模型与真实 Endpoint")
        legacy.validated_provider_endpoint(args.expected_endpoint_url)
    document = validated_dataset(args.dataset, args.expected_dataset_sha256, args.contracts, args.expected_contract_sha256)
    manifest = validated_manifest(args)
    if manifest.get("three_mode_input_count") != document["input_count"]:
        raise ValueError("候选构建清单的三档输入数与冻结数据集不一致")
    candidate = candidate_evidence(args)
    inputs = selected_inputs(document, args.test_ids)
    scope = "full" if args.test_ids is None and set(args.modes) == set(MODES) else "diagnostic"
    validate_run_root(args.run_root)
    args.run_root.mkdir(mode=0o700)
    run_input_path = args.run_root / "runner-input.json"
    write_exclusive(run_input_path, {"schema_version": 1, "name": document["name"], "inputs": inputs})
    expected = {
        "source_commit": args.expected_source_commit, "executable_sha256": args.expected_executable_sha256,
        "run_input_sha256": legacy.sha256_file(run_input_path), "provider": args.expected_provider,
        "model": args.expected_model, "endpoint_url": args.expected_endpoint_url,
        "prompt_version": args.expected_prompt_version, "editing_prompt_version": args.expected_editing_prompt_version,
    }
    tool_hashes = {str(path): legacy.sha256_file(path) for path in [
        Path(__file__), ROOT / "scripts/evaluate-voice-polish-quality-report.py",
        ROOT / "scripts/voice_polish_quality_checks.py",
    ]}
    write_exclusive(args.run_root / "frozen-evidence.json", {
        "scope": scope, "expected": expected, "modes": args.modes,
        "dataset_sha256": args.expected_dataset_sha256, "contract_sha256": args.expected_contract_sha256,
        "build_manifest_sha256": args.expected_build_manifest_sha256,
        "source_tree": args.expected_source_tree,
        "designated_requirement_sha256": args.expected_designated_requirement_sha256,
        "evaluator_sha256": legacy.sha256_file(Path(__file__)),
        "legacy_audit_implementation_sha256": legacy.sha256_file(ROOT / "scripts/evaluate-voice-polish-quality-report.py"),
        "tool_hashes": tool_hashes,
        "test_input_ids": [x["test_input_id"] for x in inputs], "quality_status": "待独立语义评审",
    })
    outcomes = {}
    for mode in args.modes:
        directory = args.run_root / mode
        try:
            report, receipts, nonce, pid, started, finished = launch_run(
                candidate["executable_path"], run_input_path, directory, mode, args.run_timeout_seconds
            )
            failures, blockers = validate_report(report, receipts, inputs, mode=mode, expected=expected,
                                                nonce=nonce, process_id=pid, started=started, finished=finished)
            if legacy.sha256_file(run_input_path) != expected["run_input_sha256"]:
                failures.append("本轮输入文件在运行期间发生变化")
            validated_dataset(args.dataset, args.expected_dataset_sha256, args.contracts, args.expected_contract_sha256)
            validated_manifest(args)
            candidate_evidence(args)
            for path, frozen_hash in tool_hashes.items():
                if legacy.sha256_file(Path(path)) != frozen_hash:
                    failures.append("证据校验工具在运行期间变化")
            outcome = {"mode": mode, "scope": scope, "evidence_passed": not failures,
                       "evidence_failures": failures, "quality_blockers": blockers,
                       "quality_status": "待独立语义评审；非发布通过结论",
                       "report_sha256": legacy.sha256_file(directory / "report.json"),
                       "provider_audit_sha256": legacy.sha256_file(directory / "provider-audit.jsonl"),
                       "groups": performance_summary(report, document)}
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            outcome = {"mode": mode, "scope": scope, "evidence_passed": False,
                       "evidence_failures": [str(error)], "quality_status": "未完成"}
        outcomes[mode] = outcome
        write_exclusive(args.run_root / f"{mode}-verification.json", outcome)
        print(json.dumps({"mode": mode, "scope": scope, "evidence_passed": outcome["evidence_passed"]}, ensure_ascii=False), flush=True)
    write_exclusive(args.run_root / "summary.json", {"scope": scope, "modes": outcomes,
                    "quality_status": "必须分别独立评审，不合算分数或自动批准发布"})
    if not all(x["evidence_passed"] for x in outcomes.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"FAIL: {error}") from error
