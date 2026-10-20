#!/usr/bin/env python3
"""校验 Dal 语音润色 V3 多维测试集的结构、覆盖和自动检查定义。"""

from __future__ import annotations

import csv
import difflib
import json
import re
import unicodedata
from collections import Counter
from pathlib import Path

from voice_polish_quality_checks import fact_group_is_preserved, relation_blocks


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DATA_PATH = PROJECT_ROOT / "docs/2026-08-17-Dal-Voice-Polish-Quality-Test-Set.json"
RUN_PATH = PROJECT_ROOT / "docs/2026-08-17-Dal-Voice-Polish-Quality-Test-Run-Template.csv"

REQUIRED_BLIND_CATEGORIES = {
    "proper_noun", "self_correction", "aside", "disordered",
    "list", "numbers", "mixed_language", "ai_prompt",
}
REQUIRED_BASE_FIELDS = {
    "id", "scenario_group", "writing_scene", "title", "difficulty",
    "challenge_tags", "blind_categories", "spoken_input", "reference_output",
    "must_preserve", "must_remove", "must_not_invent", "format_expectation",
    "tone_expectation", "acceptable_variations", "evaluation_focus",
}
REQUIRED_MULTIDIMENSION_FIELDS = {
    "length_bucket", "context_type", "quality_dimensions",
    "requires_transformation", "segment_texts", "automatic_checks",
}
REQUIRED_AUTOMATIC_CHECK_FIELDS = {
    "required_substrings", "forbidden_substrings", "forbidden_context_substrings",
}
LENGTH_BUCKETS = (
    ("micro_1_15", 1, 15),
    ("short_16_80", 16, 80),
    ("medium_81_300", 81, 300),
    ("long_301_1000", 301, 1000),
    ("very_long_1001_3000", 1001, 3000),
    ("ultra_long_3001_8000", 3001, 8000),
)
REMOVAL_FACTORS = {
    "filler_words", "lexical_repetition", "semantic_repetition",
    "self_correction", "false_start", "unfinished_fragment",
    "explicit_aside", "meta_instruction", "stutter_repetition",
}
ALLOWED_FACTOR_ASSERTION_KEYS = {
    "requires_transformation", "required_substrings", "forbidden_substrings",
    "required_order", "maximum_occurrences", "minimum_sentence_count",
    "minimum_list_item_count", "minimum_reference_length_ratio",
    "requires_terminal_punctuation", "maximum_input_segment_count",
    "minimum_internal_chunk_count",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def require_unique(values: list[str], label: str) -> None:
    require(len(values) == len(set(values)), f"{label}存在重复")


def load_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def expected_length_bucket(text: str) -> str:
    size = len(text)
    for bucket, minimum, maximum in LENGTH_BUCKETS:
        if minimum <= size <= maximum:
            return bucket
    raise ValueError(f"输入长度 {size} 不在 1～8000 字范围内")


def require_string_list(item: dict, key: str, label: str) -> list[str]:
    value = item.get(key)
    require(isinstance(value, list), f"{label} 的 {key} 必须是数组")
    require(all(isinstance(entry, str) and entry.strip() for entry in value), f"{label} 的 {key} 含空值")
    require_unique(value, f"{label} 的 {key}")
    return value


def fact_group_tokens(group: dict) -> list[str]:
    if group.get("mode") == "same_block":
        return list(group.get("tokens", []))
    values: list[str] = []
    for field in ("subject", "owner", "due", "action"):
        value = group.get(field)
        if isinstance(value, str):
            values.append(value)
        elif isinstance(value, list):
            values.extend(value)
    return values


def paragraph_count(text: str) -> int:
    return len([part for part in re.split(r"\n\s*\n", text.strip()) if part.strip()])


def list_item_count(text: str) -> int:
    pattern = re.compile(r"(?m)^\s*(?:\d{1,3}[.)、）]|[一二三四五六七八九十]{1,3}[、.)）]|[-*•])\s*")
    return len(pattern.findall(text))


def semantic_length(text: str) -> int:
    return sum(character.isalnum() for character in unicodedata.normalize("NFKC", text))


def sentence_count(text: str) -> int:
    return max(1, len([
        part for part in re.split(r"[。！？!?；;]+", text)
        if part.strip()
    ]))


def factor_assertion_passes_text(text: str, reference: str, assertion: dict) -> bool:
    """用与 evaluator 一致的文字规则做测试集反向自检。"""
    if any(token not in text for token in assertion.get("required_substrings", [])):
        return False
    if any(token in text for token in assertion.get("forbidden_substrings", [])):
        return False
    if order := assertion.get("required_order"):
        if not contains_in_order(text, order):
            return False
    for token, maximum in assertion.get("maximum_occurrences", {}).items():
        if text.count(token) > maximum:
            return False
    if minimum := assertion.get("minimum_sentence_count"):
        if sentence_count(text) < minimum:
            return False
    if assertion.get("requires_terminal_punctuation") and not re.search(
        r"[。！？!?]\s*$", text
    ):
        return False
    if minimum := assertion.get("minimum_list_item_count"):
        if list_item_count(text) < minimum:
            return False
    if minimum := assertion.get("minimum_reference_length_ratio"):
        reference_length = semantic_length(reference)
        if reference_length and semantic_length(text) / reference_length < minimum:
            return False
    return True


def contains_in_order(text: str, tokens: list[str]) -> bool:
    cursor = 0
    for token in tokens:
        location = text.find(token, cursor)
        if location < 0:
            return False
        cursor = location + len(token)
    return True


def validate_reference_checks(item: dict, reference: str, label: str) -> None:
    """冻结集自己的参考成稿也必须满足同一套机器断言。"""
    checks = item["automatic_checks"]
    for token in checks["required_substrings"]:
        require(token in reference, f"{label} 的参考成稿缺少必含文本 {token!r}")
    for group in checks.get("required_substring_groups", []):
        require(any(token in reference for token in group), f"{label} 的参考成稿未命中必含候选组 {group!r}")
    blocks = relation_blocks(reference)
    fact_groups = checks.get("required_fact_groups", [])
    for group in fact_groups:
        require(
            fact_group_is_preserved(group, fact_groups, blocks),
            f"{label} 的参考成稿没有在同一语义块保留事实关系 {group!r}",
        )
    for claim in checks.get("required_claim_groups", []):
        matched = any(token in reference for token in claim["alternatives"])
        if claim["disposition"] == "required":
            require(matched, f"{label} 的参考成稿未覆盖来源段 {claim['source_segment_index']} 的信息")
            require(
                any(
                    item["spoken_input"].count(token) == 1
                    and reference.count(token) == 1
                    for token in claim["alternatives"]
                ),
                f"{label} 的来源段 {claim['source_segment_index']} 没有来源与参考均唯一的 claim 锚点",
            )
        else:
            require(not matched, f"{label} 的参考成稿保留了来源段 {claim['source_segment_index']} 的废弃信息")
    for token in checks["forbidden_substrings"]:
        require(token not in reference, f"{label} 的参考成稿仍含禁含文本 {token!r}")
    for token in checks["forbidden_context_substrings"]:
        require(token not in reference, f"{label} 的参考成稿泄漏上下文文本 {token!r}")
    if minimum := checks.get("minimum_paragraph_count"):
        require(paragraph_count(reference) >= minimum, f"{label} 的参考成稿段落数少于 {minimum}")
    if minimum := checks.get("minimum_list_item_count"):
        require(list_item_count(reference) >= minimum, f"{label} 的参考成稿列表项少于 {minimum}")
    if minimum_ratio := checks.get("minimum_reference_length_ratio"):
        reference_length = semantic_length(reference)
        require(reference_length > 0, f"{label} 的参考成稿不能是空文本")
        require(
            semantic_length(reference) / reference_length >= minimum_ratio,
            f"{label} 的参考成稿完整度低于 {minimum_ratio}",
        )
    if minimum_ratio := checks.get("minimum_source_length_ratio"):
        source_length = semantic_length(item["spoken_input"])
        require(source_length > 0, f"{label} 的来源正文不能是空文本")
        require(
            semantic_length(reference) / source_length >= minimum_ratio,
            f"{label} 的参考成稿相对来源完整度低于 {minimum_ratio}",
        )


def validate_multidimension_item(
    item: dict,
    *,
    label: str,
    length_definitions: dict,
    context_definitions: dict,
    quality_definitions: dict,
) -> None:
    missing = REQUIRED_MULTIDIMENSION_FIELDS - item.keys()
    require(not missing, f"{label} 缺少多维字段：{sorted(missing)}")
    spoken = item["spoken_input"]
    require(isinstance(spoken, str) and spoken.strip(), f"{label} 的 spoken_input 不能为空")
    expected_bucket = expected_length_bucket(spoken)
    require(item["length_bucket"] == expected_bucket, f"{label} 的 length_bucket 应为 {expected_bucket}")
    require(item["length_bucket"] in length_definitions, f"{label} 使用未定义长度桶")
    require(item["context_type"] in context_definitions, f"{label} 使用未定义上下文类型")

    dimensions = require_string_list(item, "quality_dimensions", label)
    require(dimensions, f"{label} 必须声明质量维度")
    unknown_dimensions = set(dimensions) - set(quality_definitions)
    require(not unknown_dimensions, f"{label} 使用未定义质量维度：{sorted(unknown_dimensions)}")
    for required in ("final_intent", "fact_preservation", "no_invention", "direct_send"):
        require(required in dimensions, f"{label} 缺少基础质量维度 {required}")
    require(isinstance(item["requires_transformation"], bool), f"{label} 的 requires_transformation 必须是布尔值")

    segments = require_string_list(item, "segment_texts", label)
    require(segments, f"{label} 至少需要一个 segment")
    require("".join(segments) == spoken, f"{label} 的 segment_texts 拼接后与 spoken_input 不一致")
    if "multi_segment" in dimensions:
        require(len(segments) > 1, f"{label} 标记 multi_segment 但只有一个 segment")
        require_unique(segments, f"{label} 的多段正文")
    if "cross_segment_correction" in dimensions:
        require(len(segments) >= 2, f"{label} 的跨段纠错至少需要两个 segment")

    checks = item["automatic_checks"]
    require(isinstance(checks, dict), f"{label} 的 automatic_checks 必须是对象")
    missing_checks = REQUIRED_AUTOMATIC_CHECK_FIELDS - checks.keys()
    require(not missing_checks, f"{label} 缺少自动检查：{sorted(missing_checks)}")
    required = require_string_list(checks, "required_substrings", f"{label} 自动检查")
    required_groups = checks.get("required_substring_groups", [])
    require(isinstance(required_groups, list), f"{label} 的 required_substring_groups 必须是数组")
    for index, group in enumerate(required_groups):
        require(isinstance(group, list) and group, f"{label} 的必含候选组 {index} 不能为空")
        require(
            all(isinstance(entry, str) and entry.strip() for entry in group),
            f"{label} 的必含候选组 {index} 含空值",
        )
        require_unique(group, f"{label} 的必含候选组 {index}")
    fact_groups = checks.get("required_fact_groups", [])
    require(isinstance(fact_groups, list), f"{label} 的 required_fact_groups 必须是数组")
    fact_group_anchors: list[str] = []
    for index, group in enumerate(fact_groups):
        require(isinstance(group, dict), f"{label} 的事实关系组 {index} 必须是对象")
        mode = group.get("mode")
        require(mode in {"assignment", "same_block"}, f"{label} 的事实关系组 {index} mode 无效")
        if mode == "assignment":
            require(set(group) <= {"mode", "subject", "owner", "due", "action"}, f"{label} 的 assignment {index} 含未知字段")
            require(isinstance(group.get("subject"), str) and group["subject"].strip(), f"{label} 的 assignment {index} 缺 subject")
            require(isinstance(group.get("owner"), str) and group["owner"].strip(), f"{label} 的 assignment {index} 缺 owner")
            fact_group_anchors.append(f"assignment|{group['subject']}")
        else:
            require(set(group) == {"mode", "tokens"}, f"{label} 的 same_block {index} 字段无效")
            tokens = group.get("tokens")
            require(isinstance(tokens, list) and len(tokens) >= 2, f"{label} 的 same_block {index} 至少需要两个 token")
            fact_group_anchors.append(f"same_block|{tokens[0]}")
        tokens = fact_group_tokens(group)
        require(all(isinstance(entry, str) and entry.strip() for entry in tokens), f"{label} 的事实关系组 {index} 含空值")
        require_unique(tokens, f"{label} 的事实关系组 {index}")
        for field in ("due", "action"):
            value = group.get(field)
            require(value is None or isinstance(value, list), f"{label} 的 assignment {index} 字段 {field} 必须是数组")
            if isinstance(value, list):
                require(value, f"{label} 的 assignment {index} 字段 {field} 不能为空")
    require_unique(fact_group_anchors, f"{label} 的事实关系锚点")
    claim_groups = checks.get("required_claim_groups", [])
    require(isinstance(claim_groups, list), f"{label} 的 required_claim_groups 必须是数组")
    claim_indices = []
    required_claim_anchors: list[str] = []
    for index, claim in enumerate(claim_groups):
        require(isinstance(claim, dict), f"{label} 的来源段断言 {index} 必须是对象")
        source_index = claim.get("source_segment_index")
        require(isinstance(source_index, int), f"{label} 的来源段断言 {index} 缺少有效索引")
        is_collapsed_variant = "provider_segment_collapse" in item.get("input_factors", [])
        require(
            0 <= source_index < len(segments) or is_collapsed_variant,
            f"{label} 的来源段断言 {index} 越界",
        )
        alternatives = require_string_list(claim, "alternatives", f"{label} 来源段断言 {index}")
        require(
            claim.get("disposition") in {"required", "superseded"},
            f"{label} 的来源段断言 {index} disposition 无效",
        )
        require(
            any(
                token in (spoken if is_collapsed_variant else segments[source_index])
                for token in alternatives
            ),
            f"{label} 的来源段断言 {index} 与对应 segment 无关",
        )
        if claim.get("disposition") == "required":
            minimum_anchor_length = 4 if checks.get("minimum_source_length_ratio") else 3
            require(
                all(semantic_length(token) >= minimum_anchor_length for token in alternatives),
                f"{label} 的来源段断言 {index} 锚点过短或过弱",
            )
            required_claim_anchors.extend(alternatives)
        claim_indices.append(source_index)
    require_unique(required_claim_anchors, f"{label} 的来源段断言锚点")
    forbidden = require_string_list(checks, "forbidden_substrings", f"{label} 自动检查")
    forbidden_context = require_string_list(checks, "forbidden_context_substrings", f"{label} 自动检查")
    require(
        all(token not in spoken for token in forbidden_context),
        f"{label} 的上下文泄漏检查不得重复使用口述正文中的 alias",
    )
    require(set(required).isdisjoint(forbidden), f"{label} 的必含与禁含文本冲突")
    require(set(required).isdisjoint(forbidden_context), f"{label} 的必含与上下文禁含文本冲突")
    for group in required_groups:
        require(set(group).isdisjoint(forbidden), f"{label} 的必含候选组与禁含文本冲突")
        require(set(group).isdisjoint(forbidden_context), f"{label} 的必含候选组与上下文禁含文本冲突")
    for group in fact_groups:
        tokens = set(fact_group_tokens(group))
        require(tokens.isdisjoint(forbidden), f"{label} 的事实关系组与禁含文本冲突")
        require(tokens.isdisjoint(forbidden_context), f"{label} 的事实关系组与上下文禁含文本冲突")
    for claim in claim_groups:
        alternatives = set(claim["alternatives"])
        if claim["disposition"] == "required":
            require(alternatives.isdisjoint(forbidden), f"{label} 的来源段断言与禁含文本冲突")
        else:
            require(alternatives <= set(forbidden), f"{label} 的废弃来源段断言必须同时进入禁含文本")
        require(alternatives.isdisjoint(forbidden_context), f"{label} 的来源段断言与上下文禁含文本冲突")
    if "minimum_paragraph_count" in checks:
        require(checks["minimum_paragraph_count"] > 0, f"{label} 的最少段落数必须大于 0")
    if "minimum_list_item_count" in checks:
        require(checks["minimum_list_item_count"] > 0, f"{label} 的最少列表项必须大于 0")
    if "minimum_reference_length_ratio" in checks:
        ratio = checks["minimum_reference_length_ratio"]
        require(isinstance(ratio, (int, float)), f"{label} 的参考长度比例必须是数字")
        require(0 < ratio <= 1, f"{label} 的参考长度比例必须在 0～1 之间")
    if "minimum_source_length_ratio" in checks:
        ratio = checks["minimum_source_length_ratio"]
        require(isinstance(ratio, (int, float)), f"{label} 的来源长度比例必须是数字")
        require(0 < ratio <= 1, f"{label} 的来源长度比例必须在 0～1 之间")

    context_type = item["context_type"]
    fixture = item.get("context_fixture")
    if context_type == "none":
        require(fixture is None, f"{label} 的无上下文样本不应携带 context_fixture")
        return

    require(isinstance(fixture, dict), f"{label} 缺少 context_fixture")
    require(fixture.get("type") == context_type, f"{label} 的 context_fixture.type 不一致")
    require(fixture.get("level") in {"metadataOnly", "selectedText", "nearbyText"}, f"{label} 的上下文级别无效")
    require(fixture.get("safety") in {"safe", "secure", "unknown"}, f"{label} 的上下文安全级别无效")
    require(isinstance(fixture.get("recent_muse_inputs"), list), f"{label} 的 recent_muse_inputs 必须是数组")
    if context_type == "secure_blocked":
        require(fixture["safety"] == "secure", f"{label} 必须使用 secure 安全级别")
        require(forbidden_context, f"{label} 必须声明安全字段泄漏检查")
    elif context_type == "unknown_blocked":
        require(fixture["safety"] == "unknown", f"{label} 必须使用 unknown 安全级别")
        require(forbidden_context, f"{label} 必须声明未知字段泄漏检查")
    else:
        require(fixture["safety"] == "safe", f"{label} 的授权上下文必须标记为 safe")


def main() -> None:
    with DATA_PATH.open(encoding="utf-8") as handle:
        document = json.load(handle)

    cases = document["cases"]
    variants = document["stress_variants"]
    all_items = cases + variants
    factor_definitions = document["input_factor_definitions"]
    factor_acceptance_rules = document["factor_acceptance_rules"]
    factor_requirements = document["factor_coverage_requirements"]
    stutter_form_definitions = document["stutter_form_definitions"]
    stutter_form_requirements = document["stutter_form_coverage_requirements"]
    length_definitions = document["length_bucket_definitions"]
    context_definitions = document["context_type_definitions"]
    quality_definitions = document["quality_dimension_definitions"]

    require(document["schema_version"] == 7, "schema_version 必须为 7")
    require(document["north_star_metric"] == "direct_send", "北极星指标必须为 direct_send")
    thresholds = document.get("acceptance_thresholds", {})
    require(thresholds.get("baseline_direct_send_minimum") == 0.85, "基准 direct_send 门槛必须为 85%")
    require(thresholds.get("baseline_direct_or_minor_minimum") == 0.95, "基准可用门槛必须为 95%")
    require(thresholds.get("stress_direct_send_minimum") == 0.85, "脏输入 direct_send 门槛必须为 85%")
    require(thresholds.get("stress_direct_or_minor_minimum") == 0.95, "脏输入可用门槛必须为 95%")
    require(thresholds.get("critical_fact_intent_entity_errors") == 0, "关键事实、意图和实体错误必须为 0")
    require(thresholds.get("long_context_major_or_unusable") == 0, "长文与上下文 major/unusable 必须为 0")
    require(thresholds.get("long_text_fallbacks") == 0, "长文回退必须为 0")
    require(document["case_count"] == len(cases), "case_count 与实际基准样本数不一致")
    require(document["stress_variant_count"] == len(variants), "stress_variant_count 与实际专项变体数不一致")
    require(document["total_input_count"] == len(all_items), "total_input_count 与实际输入总数不一致")
    require(len(all_items) >= 100, "多维测试集至少需要 100 次输入")
    require(set(length_definitions) == {item[0] for item in LENGTH_BUCKETS}, "长度桶定义不完整")
    require(set(document["length_bucket_coverage_requirements"]) == set(length_definitions), "长度桶门槛与定义不一致")
    require(set(document["context_type_coverage_requirements"]) == set(context_definitions), "上下文门槛与定义不一致")
    require(set(document["quality_dimension_coverage_requirements"]) <= set(quality_definitions), "质量维度门槛包含未定义项")

    case_ids = [item["id"] for item in cases]
    variant_ids = [item["id"] for item in variants]
    require_unique(case_ids, "基准样本 ID")
    require_unique(variant_ids, "专项变体 ID")
    require(set(case_ids).isdisjoint(variant_ids), "基准样本与专项变体 ID 冲突")
    require_unique([item["title"] for item in cases], "基准样本标题")
    require_unique([item["spoken_input"] for item in cases], "基准输入")
    require_unique([item["reference_output"] for item in cases], "参考成稿")
    require_unique([item["spoken_input"] for item in variants], "专项变体输入")

    blind_categories: set[str] = set()
    for item in cases:
        missing = REQUIRED_BASE_FIELDS - item.keys()
        require(not missing, f"样本 {item.get('id', '<unknown>')} 缺少字段：{sorted(missing)}")
        require(item["reference_output"].strip(), f"样本 {item['id']} 的 reference_output 不能为空")
        require_string_list(item, "must_preserve", f"样本 {item['id']}")
        require(item["must_preserve"], f"样本 {item['id']} 必须定义 must_preserve")
        require_string_list(item, "must_remove", f"样本 {item['id']}")
        require_string_list(item, "must_not_invent", f"样本 {item['id']}")
        require(item["must_not_invent"], f"样本 {item['id']} 必须定义 must_not_invent")
        require_string_list(item, "evaluation_focus", f"样本 {item['id']}")
        require(item["evaluation_focus"], f"样本 {item['id']} 必须定义 evaluation_focus")
        require_string_list(item, "blind_categories", f"样本 {item['id']}")
        blind_categories.update(item["blind_categories"])
        validate_multidimension_item(
            item,
            label=f"样本 {item['id']}",
            length_definitions=length_definitions,
            context_definitions=context_definitions,
            quality_definitions=quality_definitions,
        )
        validate_reference_checks(item, item["reference_output"], f"样本 {item['id']}")
    require(REQUIRED_BLIND_CATEGORIES <= blind_categories, f"缺少盲测难点类别：{sorted(REQUIRED_BLIND_CATEGORIES - blind_categories)}")

    case_id_set = set(case_ids)
    base_by_id = {item["id"]: item for item in cases}
    factor_counts: Counter[str] = Counter()
    stutter_form_counts: Counter[str] = Counter()
    for item in variants:
        variant_id = item["id"]
        require(item["base_case_id"] in case_id_set, f"变体 {variant_id} 指向不存在的基准样本")
        factors = require_string_list(item, "input_factors", f"变体 {variant_id}")
        require(factors, f"变体 {variant_id} 必须包含 input_factors")
        for factor in factors:
            require(factor in factor_definitions, f"变体 {variant_id} 使用未定义因素 {factor}")
            factor_counts[factor] += 1
        if "stutter_repetition" in factors:
            stutter_form = item.get("stutter_form")
            require(stutter_form in stutter_form_definitions, f"口吃变体 {variant_id} 缺少有效 stutter_form")
            stutter_form_counts[stutter_form] += 1
        else:
            require("stutter_form" not in item, f"非口吃变体 {variant_id} 不得定义 stutter_form")
        validate_multidimension_item(
            item,
            label=f"变体 {variant_id}",
            length_definitions=length_definitions,
            context_definitions=context_definitions,
            quality_definitions=quality_definitions,
        )
        validate_reference_checks(
            item,
            base_by_id[item["base_case_id"]]["reference_output"],
            f"变体 {variant_id}",
        )
        checks = item["automatic_checks"]
        factor_assertions = item.get("factor_assertions")
        require(isinstance(factor_assertions, dict), f"变体 {variant_id} 缺少逐因素自动断言")
        require(set(factor_assertions) == set(factors), f"变体 {variant_id} 的因素与断言未一一对应")
        reference = base_by_id[item["base_case_id"]]["reference_output"]
        for factor, assertion in factor_assertions.items():
            require(isinstance(assertion, dict), f"变体 {variant_id} 的 {factor} 断言必须是对象")
            unknown_keys = set(assertion) - ALLOWED_FACTOR_ASSERTION_KEYS
            require(
                not unknown_keys,
                f"变体 {variant_id} 的 {factor} 使用 evaluator 不识别的断言：{sorted(unknown_keys)}",
            )
            require(
                assertion.get("requires_transformation") is True,
                f"变体 {variant_id} 的 {factor} 未要求发生实质整理",
            )
            substantive = set(assertion) - {"requires_transformation"}
            require(substantive, f"变体 {variant_id} 的 {factor} 只有空泛改写要求")
            if factor in REMOVAL_FACTORS:
                require(
                    assertion.get("forbidden_substrings")
                    or assertion.get("maximum_occurrences"),
                    f"变体 {variant_id} 的 {factor} 没有绑定实际清理目标",
                )
            for token in assertion.get("required_substrings", []):
                require(token in reference, f"变体 {variant_id} 的 {factor} 必含断言不在参考成稿中")
            for token in assertion.get("forbidden_substrings", []):
                require(token in item["spoken_input"], f"变体 {variant_id} 的 {factor} 禁含断言不在脏输入中")
                require(token not in reference, f"变体 {variant_id} 的 {factor} 禁含断言误伤参考成稿")
                require(token in checks["forbidden_substrings"], f"变体 {variant_id} 的 {factor} 禁含断言未进入总门禁")
            if order := assertion.get("required_order"):
                require(
                    isinstance(order, list) and len(order) >= 2 and contains_in_order(reference, order),
                    f"变体 {variant_id} 的 {factor} 顺序断言无效",
                )
            if maximums := assertion.get("maximum_occurrences"):
                require(isinstance(maximums, dict) and maximums, f"变体 {variant_id} 的 {factor} 重复次数断言无效")
                for token, maximum in maximums.items():
                    require(isinstance(maximum, int) and maximum >= 0, f"变体 {variant_id} 的 {factor} 重复次数上限无效")
                    require(item["spoken_input"].count(token) > maximum, f"变体 {variant_id} 的 {factor} 输入没有超出重复次数")
                    require(reference.count(token) <= maximum, f"变体 {variant_id} 的 {factor} 参考成稿仍超出重复次数")
            if minimum := assertion.get("minimum_sentence_count"):
                require(sentence_count(reference) >= minimum >= 2, f"变体 {variant_id} 的 {factor} 句界断言无效")
            if assertion.get("requires_terminal_punctuation") is not None:
                require(
                    assertion["requires_terminal_punctuation"] is True,
                    f"变体 {variant_id} 的 {factor} 句末标点断言必须为 true",
                )
                require(
                    re.search(r"[。！？!?]\s*$", reference) is not None,
                    f"变体 {variant_id} 的 {factor} 参考成稿没有可核验的句末标点",
                )
            if minimum := assertion.get("minimum_list_item_count"):
                require(list_item_count(reference) >= minimum > 0, f"变体 {variant_id} 的 {factor} 列表断言无效")
            if minimum := assertion.get("minimum_reference_length_ratio"):
                require(0 < minimum <= 1, f"变体 {variant_id} 的 {factor} 完整度断言无效")
            if maximum := assertion.get("maximum_input_segment_count"):
                require(
                    isinstance(maximum, int) and maximum >= 1,
                    f"变体 {variant_id} 的 {factor} 输入分段上限无效",
                )
                require(
                    len(item["segment_texts"]) <= maximum,
                    f"变体 {variant_id} 的 {factor} 实际输入分段超过声明上限",
                )
            if minimum := assertion.get("minimum_internal_chunk_count"):
                require(
                    isinstance(minimum, int) and minimum >= 2,
                    f"变体 {variant_id} 的 {factor} 内部切片下限无效",
                )

            require(
                factor_assertion_passes_text(reference, reference, assertion),
                f"变体 {variant_id} 的 {factor} 断言会误伤参考成稿",
            )
            if factor != "provider_segment_collapse":
                require(
                    not factor_assertion_passes_text(
                        item["spoken_input"], reference, assertion
                    ),
                    f"变体 {variant_id} 的 {factor} 断言连原始脏输入都能通过",
                )
        positive_assertions = (
            checks["required_substrings"]
            or checks.get("required_substring_groups", [])
            or checks.get("required_fact_groups", [])
            or checks.get("required_claim_groups", [])
        )
        require(positive_assertions, f"变体 {variant_id} 缺少任何正向自动断言")
        if REMOVAL_FACTORS & set(factors):
            require(
                checks["forbidden_substrings"],
                f"变体 {variant_id} 声明清理类因素却没有禁含断言",
            )
        if "provider_segment_collapse" in factors:
            require(
                "segment_boundary_robustness" in item["quality_dimensions"],
                f"变体 {variant_id} 缺少 segment 边界质量维度",
            )
            require(
                checks.get("minimum_reference_length_ratio", 0) >= 0.65,
                f"变体 {variant_id} 缺少长文完整度门槛",
            )

    require(set(factor_requirements) == set(factor_definitions) == set(factor_acceptance_rules), "因素定义、验收规则与最低覆盖门槛必须一一对应")
    for factor, minimum in factor_requirements.items():
        require(factor_counts[factor] >= minimum, f"因素 {factor} 只有 {factor_counts[factor]} 条，低于最低门槛 {minimum}")
    require(set(stutter_form_requirements) == set(stutter_form_definitions), "口吃形态定义与最低覆盖门槛必须一一对应")
    for stutter_form, minimum in stutter_form_requirements.items():
        require(stutter_form_counts[stutter_form] >= minimum, f"口吃形态 {stutter_form} 只有 {stutter_form_counts[stutter_form]} 条，低于最低门槛 {minimum}")

    length_counts = Counter(item["length_bucket"] for item in all_items)
    context_counts = Counter(item["context_type"] for item in all_items)
    dimension_counts = Counter(dimension for item in all_items for dimension in item["quality_dimensions"])
    for bucket, minimum in document["length_bucket_coverage_requirements"].items():
        require(length_counts[bucket] >= minimum, f"长度桶 {bucket} 只有 {length_counts[bucket]} 条，低于门槛 {minimum}")
    for context_type, minimum in document["context_type_coverage_requirements"].items():
        require(context_counts[context_type] >= minimum, f"上下文类型 {context_type} 只有 {context_counts[context_type]} 条，低于门槛 {minimum}")
    for dimension, minimum in document["quality_dimension_coverage_requirements"].items():
        require(dimension_counts[dimension] >= minimum, f"质量维度 {dimension} 只有 {dimension_counts[dimension]} 条，低于门槛 {minimum}")

    long_items = [item for item in cases if "long_content_completion" in item["quality_dimensions"]]
    require(len(long_items) >= 20, "长文本专项至少需要 20 条基准样本")
    for item in long_items:
        for artifact in ("前前", "完成完成", "前之前"):
            require(
                artifact not in item["reference_output"],
                f"长文本参考成稿 {item['id']} 含机械拼接残片 {artifact}",
            )
    natural_long_items = [item for item in long_items if item["id"].startswith("natural-long-")]
    require(len(natural_long_items) == 10, "自然长语音盲测必须恰好包含 10 条")
    natural_buckets = Counter(item["length_bucket"] for item in natural_long_items)
    require(
        natural_buckets == Counter({"long_301_1000": 4, "very_long_1001_3000": 4, "ultra_long_3001_8000": 2}),
        f"自然长语音长度覆盖错误：{dict(natural_buckets)}",
    )
    for left_index, left in enumerate(natural_long_items):
        for right in natural_long_items[left_index + 1:]:
            similarity = difflib.SequenceMatcher(None, left["spoken_input"], right["spoken_input"]).ratio()
            require(
                similarity < 0.70,
                f"自然长语音 {left['id']} 与 {right['id']} 相似度过高：{similarity:.3f}",
            )
    for item in natural_long_items:
        claim_groups = item["automatic_checks"].get("required_claim_groups", [])
        require(
            {claim["source_segment_index"] for claim in claim_groups}
            == set(range(len(item["segment_texts"]))),
            f"自然长语音 {item['id']} 未给每个来源段建立独立信息断言",
        )
        require(
            item["automatic_checks"].get("minimum_reference_length_ratio", 0) >= 0.65,
            f"自然长语音 {item['id']} 缺少最低完整度门槛",
        )
        if item["length_bucket"] == "ultra_long_3001_8000":
            require(
                len(claim_groups) >= len(item["segment_texts"]) * 2,
                f"超长自然语音 {item['id']} 未逐个独立分句建立断言",
            )
            require(
                item["automatic_checks"].get("minimum_source_length_ratio", 0) >= 0.82,
                f"超长自然语音 {item['id']} 缺少相对来源的不摘要门槛",
            )
    ultra_lengths = sorted(
        len(item["spoken_input"])
        for item in natural_long_items
        if item["length_bucket"] == "ultra_long_3001_8000"
    )
    require(ultra_lengths[0] >= 6_000, f"超长自然语音下边界不足：{ultra_lengths}")
    require(ultra_lengths[-1] >= 7_900, f"超长自然语音上边界不足：{ultra_lengths}")
    context_items = [item for item in cases if item["context_type"] != "none"]
    require(len(context_items) >= 21, "上下文专项至少需要 21 条基准样本")
    require(
        all(item["automatic_checks"]["forbidden_context_substrings"] for item in context_items),
        "每条上下文专项都必须有真实的上下文非泄漏断言",
    )
    safe_context_sentences: Counter[str] = Counter()
    for item in context_items:
        fixture = item.get("context_fixture", {})
        if fixture.get("safety") != "safe":
            continue
        context_texts = [
            fixture.get("selected_text") or "",
            fixture.get("text_before_cursor") or "",
            fixture.get("text_after_cursor") or "",
            *fixture.get("recent_muse_inputs", []),
        ]
        for sentence in re.split(r"[。！？!?；;]+", " ".join(context_texts)):
            normalized_sentence = sentence.strip()
            if len(normalized_sentence) >= 10 and "CTX-ONLY-" not in normalized_sentence:
                safe_context_sentences[normalized_sentence] += 1
    repeated_context_sentences = {
        sentence: count
        for sentence, count in safe_context_sentences.items()
        if count > 2
    }
    require(
        not repeated_context_sentences,
        f"安全上下文自然陷阱重复过多：{repeated_context_sentences}",
    )
    micro_items = [item for item in cases if item["id"].startswith("micro-")]
    require(len(micro_items) == 12, "极短文本专项必须恰好包含 12 条基准样本")
    require(any(not item["requires_transformation"] for item in micro_items), "极短文本必须覆盖无需改写的合格原文")
    require(any(item["requires_transformation"] for item in micro_items), "极短文本必须覆盖必须改写的脏输入")
    require(
        sum("deliberate_repetition_preservation" in item["quality_dimensions"] for item in micro_items) == 4,
        "极短文本必须包含 4 条有意重复保留样本",
    )
    collapse_variants = [
        item for item in variants
        if "provider_segment_collapse" in item["input_factors"]
    ]
    require(len(collapse_variants) == 4, "Provider segment 压缩变体必须恰好 4 条")
    require(
        {len(item["segment_texts"]) for item in collapse_variants} == {1, 2},
        "Provider segment 压缩必须同时覆盖单段与双段长语音",
    )
    dirty_ultra_variants = [
        item for item in collapse_variants
        if "asr-dirty" in item["id"]
    ]
    require(len(dirty_ultra_variants) == 2, "必须包含 6k 与近 8k 两条真实脏口述变体")
    dirty_lengths = sorted(len(item["spoken_input"]) for item in dirty_ultra_variants)
    require(dirty_lengths[0] >= 6_000, f"6k 脏口述长度不足：{dirty_lengths}")
    require(dirty_lengths[-1] >= 7_900, f"近 8k 脏口述长度不足：{dirty_lengths}")
    required_dirty_factors = {
        "provider_segment_collapse", "filler_words", "stutter_repetition",
        "false_start", "self_correction", "unfinished_fragment",
        "missing_punctuation", "wrong_sentence_boundary",
    }
    for item in dirty_ultra_variants:
        require(
            required_dirty_factors <= set(item["input_factors"]),
            f"脏口述 {item['id']} 的真实 ASR 因素不完整",
        )
        punctuation_count = len(re.findall(r"[，。！？；：,.!?;]", item["spoken_input"]))
        require(
            punctuation_count / len(item["spoken_input"]) < 0.04,
            f"脏口述 {item['id']} 的标点密度仍不像 ASR：{punctuation_count}",
        )

    # 门禁自测：负责人交换后，即使所有词仍在全文，也不能满足原事实关系。
    swapped_relation = "1. 首页文案：由小林负责，周一完成。\n2. 引导页：由小陈负责，周二完成。"
    swapped_blocks = relation_blocks(swapped_relation)
    dense_groups = [
        {"mode": "assignment", "subject": "首页文案", "owner": "小陈", "due": ["周一"]},
        {"mode": "assignment", "subject": "引导页", "owner": "小林", "due": ["周二"]},
    ]
    require(
        not fact_group_is_preserved(
            dense_groups[0],
            dense_groups,
            swapped_blocks,
        ),
        "事实关系门禁错误地允许跨列表项凑词",
    )
    dense_swapped = "首页文案和引导页分别由小林和小陈负责，周一和周二完成。"
    require(
        not fact_group_is_preserved(dense_groups[0], dense_groups, relation_blocks(dense_swapped)),
        "事实关系门禁错误地允许同一句密集关系交换负责人",
    )
    two_sentence_item = "1. 首页文案由小陈负责。\n周一完成。\n2. 引导页由小林负责，周二完成。"
    require(
        fact_group_is_preserved(dense_groups[0], dense_groups, relation_blocks(two_sentence_item)),
        "事实关系门禁错误地拒绝同一列表项内的两句话",
    )
    dense_correct = "首页文案由小陈负责、周一完成，引导页由小林负责、周二完成。"
    require(
        all(
            fact_group_is_preserved(group, dense_groups, relation_blocks(dense_correct))
            for group in dense_groups
        ),
        "事实关系门禁错误地拒绝同一句里的正确密集关系",
    )
    parallel_correct = "首页文案和引导页分别由小陈和小林负责，时间分别为周一和周二。"
    require(
        all(
            fact_group_is_preserved(group, dense_groups, relation_blocks(parallel_correct))
            for group in dense_groups
        ),
        "事实关系门禁错误地拒绝顺序一一对应的分别句式",
    )
    owner_first = "小陈周一完成首页文案。"
    require(
        fact_group_is_preserved(dense_groups[0], dense_groups, relation_blocks(owner_first)),
        "事实关系门禁错误地拒绝负责人前置句式",
    )
    incidental_swapped = (
        "首页文案由小林负责，周一和小陈沟通。"
        "引导页由小陈负责，周二和小林沟通。"
    )
    require(
        not any(
            fact_group_is_preserved(group, dense_groups, relation_blocks(incidental_swapped))
            for group in dense_groups
        ),
        "事实关系门禁错误地把顺带出现的人名当成负责人",
    )
    for invalid_relation in [
        "首页文案由王五负责，小陈只旁听，周一完成。",
        "首页文案不由小陈负责，改由王五，周一完成。",
        "首页文案曾由小陈负责，现交给王五，周一完成。",
        "首页文案由小陈负责，实际交给王五，周一完成。",
    ]:
        require(
            not fact_group_is_preserved(
                dense_groups[0], dense_groups, relation_blocks(invalid_relation)
            ),
            f"事实关系门禁错误地接受无效负责人关系：{invalid_relation}",
        )
    for invalid_parallel in [
        "首页文案和引导页分别不由小陈和小林负责，时间分别不是周一和周二。",
        "首页文案和引导页分别由小陈和小林旁听，王五和赵六负责，时间分别为周一和周二。",
    ]:
        require(
            not any(
                fact_group_is_preserved(group, dense_groups, relation_blocks(invalid_parallel))
                for group in dense_groups
            ),
            f"事实关系门禁错误地接受无效分别关系：{invalid_parallel}",
        )

    action_group = {
        "mode": "assignment",
        "subject": "首页文案",
        "owner": "小陈",
        "due": "周一上午",
        "action": "补齐验收截图",
    }
    for valid_relation in [
        "首页文案由小陈负责，验收截图需要在周一上午前补齐。",
        "周一上午前，小陈把首页文案的验收截图补齐。",
        "首页文案由小陈负责，最晚不超过周一上午补齐验收截图。",
        "首页文案：负责人小陈；截止：周一上午；动作：补齐验收截图。",
        "1. 首页文案：负责人小陈。截止：周一上午。动作：补齐验收截图。",
        "小陈负责首页文案，并于周一上午补齐验收截图。",
    ]:
        require(
            fact_group_is_preserved(
                action_group, [action_group], relation_blocks(valid_relation)
            ),
            f"事实关系门禁错误地拒绝自然正确语序：{valid_relation}",
        )
    for invalid_relation in [
        "如果资源到位，首页文案由小陈负责，周一上午补齐验收截图。",
        "有人说，首页文案由小陈负责，周一上午补齐验收截图。",
        "旧会议纪要写道：“首页文案由小陈负责，周一上午补齐验收截图。”",
        "首页文案由小陈负责沟通，周一上午的验收截图由王五补齐。",
        "首页文案由小陈负责，周二补齐验收截图；周一上午只是参加例会。",
        "首页文案由小陈负责；如果有空，周一上午补齐验收截图。",
        "首页文案由小陈负责，周一上午补齐验收截图；后来交由王五。",
        "首页文案由小陈负责，周一上午参加例会，周二补齐验收截图。",
        "首页文案由小陈负责，周二补齐验收截图，周一上午参加例会。",
        "上周会议纪要写道：“首页文案由小陈负责，周一上午补齐验收截图。”",
        "首页文案由小陈负责，周一上午补齐验收截图；负责人已经换成王五。",
        "“首页文案由小陈负责，周一上午补齐验收截图”。这只是旧记录，已撤销。",
        "首页文案由小陈负责，周一上午补齐验收截图；以上安排作废。",
        "首页文案由小陈负责，周一上午补齐验收截图。后来改由王五负责。",
        "首页文案由小陈负责，周一上午补齐验收截图，后续改派王五。",
        "王五将在周一上午补齐验收截图，首页文案由小陈负责。",
        "首页文案由小陈负责沟通，王五将在周一上午补齐验收截图。",
        "首页文案由小陈负责，补齐验收截图后，周一上午参加例会，周二正式提交。",
        "首页文案由小陈负责沟通，王五补齐验收截图，周一上午前完成。",
        "王五将在周一上午补齐小陈整理的验收截图，首页文案由小陈负责。",
        "首页文案由小陈负责，周一上午参加例会，随后补齐验收截图。",
        "首页文案由小陈负责协调，补齐验收截图的是王五，周一上午前完成。",
        "首页文案由小陈负责，验收截图让王五补齐，周一上午前完成。",
    ]:
        require(
            not fact_group_is_preserved(
                action_group, [action_group], relation_blocks(invalid_relation)
            ),
            f"事实关系门禁错误地接受假设、引语、撤销或改派：{invalid_relation}",
        )

    parallel_action_groups = [
        action_group,
        {
            "mode": "assignment",
            "subject": "引导页",
            "owner": "小林",
            "due": "周二下班前",
            "action": "确认最终文案",
        },
    ]
    reassigned_parallel = (
        "首页文案和引导页分别由小陈和小林负责，时间分别为周一上午和周二下班前，"
        "任务分别为补齐验收截图和确认最终文案；实际首页归小林，引导页归小陈。"
    )
    require(
        not any(
            fact_group_is_preserved(
                group, parallel_action_groups, relation_blocks(reassigned_parallel)
            )
            for group in parallel_action_groups
        ),
        "事实关系门禁错误地接受并列任务后续互换负责人",
    )

    same_block_group = {"mode": "same_block", "tokens": ["swift test", "全量测试"]}
    for invalid_claim in [
        "swift test 并不代表全量测试。",
        "如果 swift test 能覆盖全量测试就好了。",
        "有人误称 swift test 是全量测试；实际不是。",
    ]:
        require(
            not fact_group_is_preserved(
                same_block_group,
                [same_block_group],
                relation_blocks(invalid_claim),
            ),
            f"同块主张门禁错误地接受否定或假设：{invalid_claim}",
        )

    rows = load_csv(RUN_PATH)
    expected_rows = [(item["id"], item["id"], "base", item) for item in cases]
    expected_rows += [(item["id"], item["base_case_id"], "stress_variant", item) for item in variants]
    require(len(rows) == len(expected_rows), "试跑 CSV 行数与测试集不一致")
    for row, (test_id, base_id, kind, item) in zip(rows, expected_rows):
        require(row["test_input_id"] == test_id, f"试跑 CSV 的 ID/顺序错误：{test_id}")
        require(row["base_case_id"] == base_id, f"试跑 CSV 的 base_case_id 错误：{test_id}")
        require(row["input_kind"] == kind, f"试跑 CSV 的 input_kind 错误：{test_id}")
        require(row["length_bucket"] == item["length_bucket"], f"试跑 CSV 的长度桶错误：{test_id}")
        require(row["context_type"] == item["context_type"], f"试跑 CSV 的上下文类型错误：{test_id}")
        require(row["quality_dimensions"].split("+") == item["quality_dimensions"], f"试跑 CSV 的质量维度错误：{test_id}")
        require(row["requires_transformation"] == str(item["requires_transformation"]).lower(), f"试跑 CSV 的改写要求错误：{test_id}")

    print(
        f"PASS：{len(cases)} 条基准 + {len(variants)} 条变体 = {len(all_items)} 次输入；"
        f"长度覆盖 {dict(length_counts)}；上下文专项 {len(context_items)} 条；长文本专项 {len(long_items)} 条。"
    )
    print(f"质量维度：{dict(sorted(dimension_counts.items()))}")
    print(f"脏输入因素：{dict(sorted(factor_counts.items()))}")


if __name__ == "__main__":
    main()
