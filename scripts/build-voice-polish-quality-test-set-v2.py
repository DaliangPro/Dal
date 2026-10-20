#!/usr/bin/env python3
"""从已验收的 V1.2 母集重建 Dal 语音润色 V3.1 多维测试集。"""

from __future__ import annotations

import copy
import csv
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = ROOT / "docs/2026-08-12-Dal-Voice-Polish-Quality-Test-Set.json"
OUTPUT_PATH = ROOT / "docs/2026-08-17-Dal-Voice-Polish-Quality-Test-Set.json"
RUN_PATH = ROOT / "docs/2026-08-17-Dal-Voice-Polish-Quality-Test-Run-Template.csv"


# 安全上下文不泄漏测试必须覆盖不同语用形态，不能给每条样本重复同一句
# “某人周六在某地复盘”。这些内容都与当前口述无关，既用于检查模型不照抄，
# 也用于攻击实体纠错是否会把历史值、假设、引语或同名人物带入正文。
SAFE_CONTEXT_TRAPS: dict[str, tuple[str, list[str]]] = {
    "context-01": ("旧项目的负责人曾是林青，去年已经关闭。", ["林青", "去年已经关闭"]),
    "context-02": ("如果北区试点启动，秦川可能周六去苏州，目前尚未确定。", ["秦川", "周六去苏州"]),
    "context-03": ("会议记录引用了“蓝鲸计划下周三迁移”，但那不是当前客户。", ["蓝鲸计划", "下周三迁移"]),
    "context-04": ("同名的另一位小陈只负责采购，地址是海淀北路 12 号。", ["只负责采购", "海淀北路 12 号"]),
    "context-05": ("上一版预算是 78 万元，这个数字已经明确作废。", ["78 万元", "明确作废"]),
    "context-06": ("假设周日上线，备用联系人是赵岚；这项假设没有确认。", ["赵岚", "周日上线"]),
    "context-07": ("引号中的“星河 Beta”只是演示例子，不是本次产品名。", ["星河 Beta", "演示例子"]),
    "context-08": ("另一个客户在深圳使用 Windows，工单号是 WB-2048。", ["深圳", "WB-2048"]),
    "context-09": ("历史文档写着由蒋川负责，但当前已经转交另一团队。", ["蒋川", "转交另一团队"]),
    "context-10": ("测试环境地址是 staging.example.net，禁止写入对外文案。", ["staging.example.net"]),
    "context-13": ("旁边聊天提到周二取消南京复盘，这件事与本条无关。", ["南京复盘", "周二取消"]),
    "context-14": ("红队故意放入错误候选“DalX”，不得据此改名。", ["DalX"]),
    "context-15": ("另一个课程的历史报价是 2,999 元，仅供财务对照。", ["2,999 元", "财务对照"]),
    "context-16": ("旧日程里顾明周四到青岛，现在这份日程已经失效。", ["顾明", "周四到青岛"]),
    "natural-long-03": ("候选人名单包含唐宁和陆远，但两人都尚未分配任务。", ["唐宁", "陆远"]),
    "natural-long-06": ("如果客户选择紫色包装，交付日期可能是九月三日。", ["紫色包装", "九月三日"]),
    "natural-long-08": ("另一场测试使用代号 Orion，负责人只在旧记录中出现。", ["Orion", "旧记录"]),
    "natural-long-09": ("旁边邮件称海星项目将在厦门试运行，这不是本次候选。", ["海星项目", "厦门试运行"]),
}


def append_safe_context_trap(fixture: dict, case_id: str) -> list[str]:
    text, forbidden = SAFE_CONTEXT_TRAPS[case_id]
    append_context_text(fixture, text)
    return list(forbidden)


def conflicting_context_candidates(fixture: dict) -> list[str]:
    """从冲突上下文自身提取候选，确保任一候选都不能泄漏进成稿。"""
    if not str(fixture.get("type", "")).startswith("conflicting_"):
        return []

    context_texts = [
        fixture.get("selected_text"),
        fixture.get("text_before_cursor"),
        fixture.get("text_after_cursor"),
        *(fixture.get("recent_muse_inputs") or []),
    ]
    candidates: list[str] = []
    quoted_candidate_pattern = re.compile(
        r"“([^”\n]+)”|‘([^’\n]+)’|\"([^\"\n]+)\"|`([^`\n]+)`"
    )
    for text in context_texts:
        if not isinstance(text, str):
            continue
        for match in quoted_candidate_pattern.finditer(text):
            candidate = next(group.strip() for group in match.groups() if group)
            if candidate and candidate not in candidates:
                candidates.append(candidate)
    return candidates


def shared_claim_check(
    segment: str,
    reference: str,
    forbidden: list[str],
    required_groups: list[list[str]],
    *,
    whole_source: str,
    used_anchors: set[str],
    minimum_size: int,
    require_unique_anchor: bool,
) -> dict:
    """为来源单元选择强、唯一且可在参考成稿中复核的事实锚点。"""
    chunks = re.findall(
        rf"[A-Za-z][A-Za-z0-9+._/-]*(?: [A-Za-z0-9+._/-]+)*|[\u4e00-\u9fff]{{{minimum_size},}}",
        segment,
    )
    candidates: list[tuple[int, int, str]] = []
    for chunk_index, chunk in enumerate(chunks):
        maximum = min(18, len(chunk))
        for size in range(maximum, minimum_size - 1, -1):
            for start in range(0, len(chunk) - size + 1):
                token = chunk[start:start + size]
                if (
                    token in reference
                    and (
                        not require_unique_anchor
                        or (whole_source.count(token) == 1 and reference.count(token) == 1)
                    )
                    and token not in used_anchors
                ):
                    candidates.append((size, -chunk_index, token))
            if candidates:
                break
    if not candidates:
        equivalent_group = next((
            group for group in required_groups
            if any(token in segment for token in group)
            and any(token in reference for token in group)
        ), None)
        if equivalent_group:
            return {"disposition": "required", "alternatives": equivalent_group}
        superseded = [token for token in forbidden if token in segment]
        if superseded:
            return {"disposition": "superseded", "alternatives": superseded}
        raise ValueError(f"自然长文 segment 没有可核验的参考成稿锚点：{segment[:40]!r}")
    anchor = max(candidates)[2]
    used_anchors.add(anchor)
    return {"disposition": "required", "alternatives": [anchor]}


def required_claim_checks(
    segments: list[str],
    reference: str,
    forbidden: list[str],
    required_groups: list[list[str]],
    *,
    every_clause: bool,
) -> list[dict]:
    """长文逐段核验；6k～8k 边界样本进一步拆到每个独立句/分句。"""
    whole_source = "".join(segments)
    used_anchors: set[str] = set()
    claims: list[dict] = []
    for source_index, segment in enumerate(segments):
        units = [segment]
        if every_clause:
            units = [
                unit.strip()
                for unit in re.split(r"[。！？!?；;]+", segment)
                if len(unit.strip()) >= 6
            ]
        for unit in units:
            claims.append({
                "source_segment_index": source_index,
                **shared_claim_check(
                    unit,
                    reference,
                    forbidden,
                    required_groups,
                    whole_source=whole_source,
                    used_anchors=used_anchors,
                    minimum_size=4 if every_clause else 3,
                    # 每个来源单元都使用在来源与参考成稿中各只出现一次的锚点，
                    # 防止遗漏某一段后借用其他段的同名词假通过。
                    require_unique_anchor=True,
                ),
            })
    return claims


LEGACY_REQUIRED_OVERRIDES = {
    "chat-04": ["直接到店里", "样品", "顺路去取"],
    "email-01": ["王老师", "课程大纲", "周五", "下周一", "第一版"],
    "email-03": ["赵经理", "第三版", "以后面这份为准"],
    "email-04": ["陈律师", "合同总金额", "首款", "尾款"],
    "email-05": ["B 版", "接口联调", "下周二", "可点击原型"],
    "note-01": ["很多人", "任务判断", "继续展开"],
    "note-02": ["首页", "小陈", "测试清单", "待确认事项"],
    "note-03": ["最近记录", "复制记录", "删除记录", "搜索功能"],
    "note-04": ["成功标准", "开工前", "什么才算完成"],
    "note-05": ["不要优化", "暂不补充"],
    "prompt-04": ["1 分钟", "核心观点", "生活化例子", "普通人"],
    "social-02": ["持续更新", "中间状态", "真实想法", "完美"],
    "social-03": ["AI 工具", "工作流程", "用不起来"],
    "code-04": ["Voice Polish", "Fast", "Analyze + Render", "Structured", "Deep"],
    "code-05": ["Swift 6.1", "6.2", "尚未确认", "错误码"],
    "support-01": ["3 天", "具体位置", "预计送达时间"],
    "support-02": ["A6821", "两件", "未拆封", "寄回流程"],
    "support-04": ["明天下午", "处理进展", "无法承诺"],
}

# 旧冻结集中的 support-05 把“不是坏了”当成可删除的幕后话，实际会改变
# 客户对故障状态的理解。重建集保留这条否定事实，仍删除“别归因客户操作”的
# 真正幕后要求。
LEGACY_REFERENCE_OVERRIDES = {
    "support-05": (
        "这个功能并非故障，而是需要先开启系统权限，请按以下步骤操作：\n\n"
        "1. 前往系统设置，开启辅助功能权限；\n"
        "2. 完全退出软件后重新打开。\n\n"
        "如果仍然无法使用，请将系统版本和错误截图发给我们，我们会继续排查。"
    ),
}

LEGACY_REQUIRED_GROUP_OVERRIDES = {
    "email-04": [
        ["48,000", "48000", "四万八"],
        ["50%", "百分之五十"],
        ["3 个工作日", "三个工作日"],
        ["7 个工作日", "七个工作日"],
    ],
}

CODE_01_CRITICAL_REQUIRED_TOKENS = [
    "Dal/VoicePolish/VoicePolishPipeline.swift",
    "swift test --filter VoicePolishPipelineTests",
]

VARIANT_REQUIRED_OVERRIDES = {
    "code-01-noise-01": CODE_01_CRITICAL_REQUIRED_TOKENS,
}

VARIANT_FACTOR_OVERRIDES = {
    # 该输入只有错误断句，没有真实填充词，不能为了覆盖数字而错标维度。
    "email-01-noise-01": ["wrong_punctuation", "wrong_sentence_boundary"],
}

VARIANT_FORBIDDEN_OVERRIDES = {
    "chat-01-noise-01": ["那个", "大概大概", "不用等我啊不用等我"],
    "chat-02-noise-01": ["周六下午", "不对", "改成"],
    "chat-03-noise-01": ["不是说不想帮"],
    "chat-04-noise-01": ["到店里。还是", "那个样品。你拿到了吗如果"],
    "chat-05-noise-01": ["两样东西", "啊等一下"],
    "work-01-noise-01": ["测试测试", "渠 道"],
    "work-01-noise-02": ["type list"],
    "work-02-noise-01": ["周三下午三点", "一共四个人", "不对", "时间也改一下"],
    "work-03-noise-01": ["我本来想就是", "今晚这个先不"],
    "work-04-noise-01": ["小林那个", "就是确认一下"],
    "work-05-noise-01": ["不是说谁做得不好啊", "这句别写得太重"],
    "email-01-noise-01": ["最好。周五之前"],
    "email-03-noise-01": ["第二版", "不是", "我重新说", "应该是"],
    "email-04-noise-01": ["四 万八", "合同金额。总金额", "合同签完。三个"],
    "email-05-noise-01": ["就是暂时不写死", "我把今天讨论的事情汇总一下"],
    "note-01-noise-01": ["不是工具不会操作", "就是可能"],
    "note-02-noise-01": ["结构。只换", "定的是。发布日", "这个别放在已确定事项里"],
    "note-03-noise-01": ["第一版先做搜索", "不对搜索", "然后这个"],
    "note-05-noise-01": ["don't optimize what you have n't", "那个后面"],
    "prompt-02-noise-01": ["refer enced"],
    "prompt-05-noise-01": ["不对不对", "三条三条", "不对"],
    "social-02-noise-01": ["不是我想说的", "会变成任务"],
    "social-04-noise-01": ["顺便说一下", "网络也不太好", "但这个不用展开"],
    "code-01-noise-01": ["斜杠", "双横线", "Pol ish"],
    "code-03-noise-01": ["三步", "等一下", "还有一步", "短横线", "斜杠"],
    "support-02-noise-01": ["整单退款", "不对", "那就"],
    "support-04-noise-01": ["第三方接口波动", "别说一定能修好"],
    "support-05-noise-01": ["目前不是坏了", "坏了。是需要"],
    "chat-01-stutter-01": ["我我我", "大大概", "不不用"],
    "chat-04-stutter-01": ["你明天你明天", "还是还是"],
    "work-04-stutter-01": ["小小林", "麻烦麻烦", "帮我帮我"],
    "email-01-stutter-01": ["您好您好", "今天今天"],
    "note-01-stutter-01": ["我我", "突突然"],
    "prompt-02-stutter-01": ["让让AI", "这个这个", "并并发"],
    "social-03-stutter-01": ["发现发现", "很多很多"],
    "support-05-stutter-01": ["给给", "功功能", "辅助辅助功能"],
    "code-03-stutter-01": ["第第一", "第第二", "第第三", "第第四"],
}

VARIANT_FACTOR_FORBIDDEN_OVERRIDES = {
    "chat-01-noise-01": {
        "filler_words": ["嗯", "那个"],
        "lexical_repetition": ["大概大概", "不用等我啊不用等我"],
    },
    "chat-02-noise-01": {
        "self_correction": ["周六下午", "不对"],
        "false_start": ["改成"],
        "wrong_punctuation": ["改成。周日下午"],
        "wrong_sentence_boundary": ["不对周六我有事"],
    },
    "chat-03-noise-01": {
        "semantic_repetition": ["不是说不想帮"],
    },
    "chat-05-noise-01": {
        "filler_words": ["啊等一下"],
        "self_correction": ["两样东西"],
    },
    "code-01-noise-01": {
        "accidental_space": ["Pol ish"],
    },
    "work-01-noise-01": {
        "lexical_repetition": ["测试测试"],
    },
    "work-02-noise-01": {
        "self_correction": ["周三下午三点", "一共四个人", "不对"],
        "fact_correction": ["周三下午三点", "一共四个人"],
        "wrong_punctuation": ["四个人。不对开发"],
        "wrong_sentence_boundary": ["时间也改一下。周三"],
    },
    "work-03-noise-01": {
        "false_start": ["我本来想就是"],
        "unfinished_fragment": ["今晚这个先不"],
    },
    "work-04-noise-01": {
        "filler_words": ["小林那个"],
        "semantic_repetition": ["就是确认一下"],
    },
    "work-05-noise-01": {
        "explicit_aside": ["不是说谁做得不好啊"],
        "meta_instruction": ["这句别写得太重"],
        "wrong_punctuation": ["明确时间。后面的排期"],
        "wrong_sentence_boundary": ["同步给负责人。不是说谁"],
    },
    "email-03-noise-01": {
        "self_correction": ["第二版", "不是", "应该是"],
        "false_start": ["我重新说"],
    },
    "email-05-noise-01": {
        "semantic_repetition": ["就是暂时不写死", "我把今天讨论的事情汇总一下"],
    },
    "note-01-noise-01": {
        "filler_words": ["就是"],
        "semantic_repetition": ["不是工具不会操作", "就是可能"],
    },
    "note-03-noise-01": {
        "false_start": ["第一版先做搜索", "不对搜索"],
        "unfinished_fragment": ["然后这个"],
    },
    "note-05-noise-01": {
        "unfinished_fragment": ["那个后面"],
    },
    "prompt-05-noise-01": {
        "self_correction": ["不对不对", "不对"],
        "lexical_repetition": ["三条三条"],
    },
    "social-02-noise-01": {
        "semantic_repetition": ["会变成任务"],
        "false_start": ["不是我想说的"],
    },
    "social-04-noise-01": {
        "explicit_aside": ["顺便说一下", "网络也不太好"],
        "meta_instruction": ["但这个不用展开"],
        "wrong_punctuation": ["这个不用展开第三。"],
        "wrong_sentence_boundary": ["背景第二演示"],
    },
    "code-03-noise-01": {
        "self_correction": ["三步", "等一下", "还有一步"],
    },
    "support-02-noise-01": {
        "self_correction": ["整单退款", "不对"],
        "false_start": ["那就"],
    },
    "support-04-noise-01": {
        "explicit_aside": ["第三方接口波动"],
        "meta_instruction": ["别说一定能修好"],
        "wrong_punctuation": ["这个原因。先不要"],
        "wrong_sentence_boundary": ["技术正在查预计明天"],
    },
    "chat-01-stutter-01": {
        "stutter_repetition": ["我我我", "大大概", "不不用"],
    },
    "chat-04-stutter-01": {
        "stutter_repetition": ["你明天你明天", "还是还是"],
    },
    "work-04-stutter-01": {
        "stutter_repetition": ["小小林", "麻烦麻烦", "帮我帮我"],
    },
    "email-01-stutter-01": {
        "stutter_repetition": ["您好您好", "今天今天"],
    },
    "note-01-stutter-01": {
        "stutter_repetition": ["我我", "突突然"],
    },
    "prompt-02-stutter-01": {
        "stutter_repetition": ["让让AI", "这个这个", "并并发"],
    },
    "social-03-stutter-01": {
        "stutter_repetition": ["发现发现", "很多很多"],
    },
    "support-05-stutter-01": {
        "stutter_repetition": ["给给", "功功能", "辅助辅助功能"],
    },
    "code-03-stutter-01": {
        "stutter_repetition": ["第第一", "第第二", "第第三", "第第四"],
    },
    "natural-long-09-asr-dirty-segments-1": {
        "filler_words": ["嗯", "呃"],
        "stutter_repetition": ["这个这个"],
        "false_start": ["先从录音这一段说"],
        "self_correction": ["只是速度慢", "撤回刚才这句"],
        "unfinished_fragment": ["后面那个"],
        "missing_punctuation": ["润色路由录音启动"],
        "wrong_sentence_boundary": ["等待还是处理术语纠正"],
    },
    "natural-long-10-asr-dirty-segments-2": {
        "filler_words": ["啊"],
        "stutter_repetition": ["我们我们"],
        "false_start": ["先从第七章讲"],
        "self_correction": ["我改一下", "不对"],
        "unfinished_fragment": ["呃后面再补"],
        "missing_punctuation": ["自动化流程开篇先讲边界"],
        "wrong_sentence_boundary": ["辅助讲解的补充画面第六部分"],
        "fact_correction": ["九月三日"],
        "meta_instruction": [
            "这份计划最后请整理成", "不要压成十几行摘要",
            "旧日期不要出现在最终计划里",
        ],
    },
    "chat-04-noise-01": {
        "wrong_punctuation": ["到店里。还是"],
        "wrong_sentence_boundary": ["你拿到了吗如果"],
        "ambiguous_reference": ["那个样品"],
    },
    "email-01-noise-01": {
        "wrong_punctuation": ["资料发我一下最好。"],
        "wrong_sentence_boundary": ["周五之前这样我们"],
    },
    "email-04-noise-01": {
        "accidental_space": ["四 万八"],
        "wrong_punctuation": ["合同金额。总金额"],
        "wrong_sentence_boundary": ["合同签完。三个"],
    },
    "support-05-noise-01": {
        "ambiguous_reference": ["那个权限"],
        "missing_punctuation": ["权限他要做两步先到"],
        "wrong_punctuation": ["坏了。是需要"],
        "wrong_sentence_boundary": ["然后。完全退出"],
    },
}

VARIANT_FACTOR_ASSERTION_OVERRIDES = {
    "code-01-noise-01": {
        "mixed_language_tokenization": {
            "required_substrings": [
                "回退原文",
                *CODE_01_CRITICAL_REQUIRED_TOKENS,
            ],
        },
        "accidental_space": {
            "required_substrings": [
                "回退原文",
                *CODE_01_CRITICAL_REQUIRED_TOKENS,
            ],
        },
        "dictated_symbols": {
            "required_substrings": [
                "回退原文",
                *CODE_01_CRITICAL_REQUIRED_TOKENS,
            ],
        },
    },
    "chat-03-noise-01": {
        "lexical_repetition": {
            "maximum_occurrences": {"排不开": 1},
        },
    },
    "work-03-noise-01": {
        "disordered_content": {
            "required_order": ["今晚暂不发布", "测试环境的数据", "回滚脚本", "明早再决定"],
        },
    },
    "email-05-noise-01": {
        "disordered_content": {
            "required_order": ["B 版", "接口", "接口联调", "下周二"],
        },
    },
    "note-03-noise-01": {
        "disordered_content": {
            "required_order": ["要解决的问题", "最近记录", "删除记录", "搜索功能暂不纳入"],
        },
    },
    "chat-04-noise-01": {
        "ambiguous_reference": {
            "required_order": ["样品", "还没拿到", "顺路去取"],
        },
    },
    "note-05-noise-01": {
        "ambiguous_reference": {
            "required_order": ["英文原话", "作者姓名", "没有记清", "暂不补充"],
        },
    },
    "support-05-noise-01": {
        "ambiguous_reference": {
            "required_order": ["开启系统权限", "辅助功能", "重新打开", "继续排查"],
        },
    },
    "natural-long-09-asr-dirty-segments-1": {
        "missing_punctuation": {"minimum_sentence_count": 30},
        "wrong_sentence_boundary": {"minimum_sentence_count": 30},
    },
    "natural-long-10-asr-dirty-segments-2": {
        "missing_punctuation": {"minimum_sentence_count": 45},
        "wrong_sentence_boundary": {"minimum_sentence_count": 45},
        "fact_correction": {"forbidden_substrings": ["九月三日"]},
    },
}


def length_bucket(text: str) -> str:
    size = len(text)
    if size <= 15:
        return "micro_1_15"
    if size <= 80:
        return "short_16_80"
    if size <= 300:
        return "medium_81_300"
    if size <= 1000:
        return "long_301_1000"
    if size <= 3000:
        return "very_long_1001_3000"
    return "ultra_long_3001_8000"


def common_dimensions(item: dict) -> list[str]:
    values = {"final_intent", "fact_preservation", "no_invention", "direct_send"}
    tags = set(item.get("challenge_tags", [])) | set(item.get("blind_categories", []))
    factors = set(item.get("input_factors", []))
    if {"proper_noun", "homophone_entity_error", "mixed_language"} & (tags | factors):
        values.add("terminology")
    if {"self_correction", "fact_correction", "numeric_fact_correction"} & (tags | factors):
        values.add("correction_resolution")
    if {"list", "disordered", "wrong_sentence_boundary", "wrong_punctuation"} & (tags | factors):
        values.add("semantic_layout")
    if {"stutter_repetition", "lexical_repetition", "semantic_repetition"} & factors:
        values.add("disfluency_cleanup")
    if "ai_prompt" in tags:
        values.add("prompt_not_execution")
    return sorted(values)


def new_case(
    *,
    case_id: str,
    group: str,
    scene: str,
    title: str,
    spoken: str,
    reference: str,
    preserve: list[str],
    remove: list[str],
    dimensions: list[str],
    requires_transformation: bool,
    required_substrings: list[str],
    required_substring_groups: list[list[str]] | None = None,
    required_fact_groups: list[dict] | None = None,
    required_claim_groups: list[dict] | None = None,
    forbidden_substrings: list[str],
    format_expectation: str = "自然成稿",
    tone_expectation: str = "保留原有语气和表达力度",
    segments: list[str] | None = None,
    context_fixture: dict | None = None,
    min_paragraphs: int | None = None,
    min_list_items: int | None = None,
    min_reference_length_ratio: float | None = None,
    challenge_tags: list[str] | None = None,
    blind_categories: list[str] | None = None,
) -> dict:
    automatic_checks = {
        "required_substrings": required_substrings,
        "forbidden_substrings": forbidden_substrings,
        "forbidden_context_substrings": [],
    }
    if required_substring_groups:
        automatic_checks["required_substring_groups"] = required_substring_groups
    if required_fact_groups:
        automatic_checks["required_fact_groups"] = required_fact_groups
    if required_claim_groups:
        automatic_checks["required_claim_groups"] = required_claim_groups
    if min_paragraphs is not None:
        automatic_checks["minimum_paragraph_count"] = min_paragraphs
    if min_list_items is not None:
        automatic_checks["minimum_list_item_count"] = min_list_items
    if min_reference_length_ratio is not None:
        automatic_checks["minimum_reference_length_ratio"] = min_reference_length_ratio
    item = {
        "id": case_id,
        "scenario_group": group,
        "writing_scene": scene,
        "title": title,
        "difficulty": "high" if len(spoken) > 300 else "medium",
        "challenge_tags": challenge_tags or [],
        "blind_categories": blind_categories or [],
        "spoken_input": spoken,
        "reference_output": reference,
        "must_preserve": preserve,
        "must_remove": remove,
        "must_not_invent": ["原文和授权上下文之外的事实", "额外承诺", "额外结论"],
        "format_expectation": format_expectation,
        "tone_expectation": tone_expectation,
        "acceptable_variations": ["允许同义改写，但不得改变事实、意图和语气"],
        "evaluation_focus": ["能否直接发送", "是否完成必要整理", "是否保留全部来源事实"],
        "length_bucket": length_bucket(spoken),
        "context_type": (context_fixture or {}).get("type", "none"),
        "quality_dimensions": sorted(set(dimensions + [
            "final_intent", "fact_preservation", "no_invention", "direct_send"
        ])),
        "requires_transformation": requires_transformation,
        "segment_texts": segments or [spoken],
        "automatic_checks": automatic_checks,
    }
    if context_fixture:
        item["context_fixture"] = context_fixture
    return item


def assignment(
    subject: str,
    owner: str,
    *,
    due: str | list[str] | None = None,
    action: str | list[str] | None = None,
) -> dict:
    group = {"mode": "assignment", "subject": subject, "owner": owner}
    if due is not None:
        group["due"] = [due] if isinstance(due, str) else due
    if action is not None:
        group["action"] = [action] if isinstance(action, str) else action
    return group


def same_block(*tokens: str) -> dict:
    return {"mode": "same_block", "tokens": list(tokens)}


def short_cases() -> list[dict]:
    specs = [
        ("micro-01", "谢谢你。", "谢谢你。", ["谢谢"], [], False, ["谢谢你"], []),
        ("micro-02", "你到哪了", "你到哪了？", ["询问位置"], [], True, ["你到哪了"], []),
        ("micro-03", "周五不行。", "周五不行。", ["周五", "否定态度"], [], False, ["周五不行"], []),
        ("micro-04", "真的真的很好。", "真的真的很好。", ["有意强调两次真的"], [], False, ["真的真的很好"], []),
        ("micro-05", "我我到了", "我到了。", ["已经到达"], ["我我"], True, ["我到了"], ["我我"]),
        ("micro-06", "不不急慢慢来", "不急，慢慢来。", ["不着急", "慢慢来"], ["不不"], True, ["不急", "慢慢来"], ["不不"]),
        ("micro-07", "行行行，我知道了。", "行行行，我知道了。", ["有意重复的行行行", "已经知道"], [], False, ["行行行", "我知道了"], []),
        ("micro-08", "发第二版", "发第二版。", ["第二版"], [], True, ["第二版"], []),
        ("micro-09", "特别特别期待。", "特别特别期待。", ["有意强调两次特别"], [], False, ["特别特别期待"], []),
        ("micro-10", "对对对，就是这个。", "对对对，就是这个。", ["连续回应的对对对", "就是这个"], [], False, ["对对对", "就是这个"], []),
        ("micro-11", "真的真的，不对，最后感觉一般。", "最后感觉一般。", ["最终感觉一般"], ["真的真的", "不对"], True, ["最后感觉一般"], ["真的真的", "不对"]),
        ("micro-12", "好好好像可以", "好像可以。", ["好像可以"], ["好好好像"], True, ["好像可以"], ["好好好像"]),
    ]
    result = []
    for index, (case_id, spoken, reference, preserve, remove, requires, required, forbidden) in enumerate(specs):
        dimensions = ["minimal_edit", "tone_preservation"]
        if case_id in {"micro-04", "micro-07", "micro-09", "micro-10"}:
            dimensions.append("deliberate_repetition_preservation")
        if case_id in {"micro-05", "micro-06", "micro-11", "micro-12"}:
            dimensions.append("disfluency_cleanup")
        if case_id == "micro-11":
            dimensions.append("correction_resolution")
        result.append(new_case(
            case_id=case_id,
            group="micro_text",
            scene="chat",
            title=f"极短文本 {index + 1}",
            spoken=spoken,
            reference=reference,
            preserve=preserve,
            remove=remove,
            dimensions=dimensions,
            requires_transformation=requires,
            required_substrings=required,
            forbidden_substrings=forbidden,
            challenge_tags=["short_text"],
        ))
    return result


def context_fixture(
    context_type: str,
    level: str,
    safety: str,
    *,
    selected: str | None = None,
    before: str | None = None,
    after: str | None = None,
    recent: list[str] | None = None,
) -> dict:
    return {
        "type": context_type,
        "level": level,
        "safety": safety,
        "selected_text": selected,
        "text_before_cursor": before,
        "text_after_cursor": after,
        "recent_muse_inputs": recent or [],
    }


def append_context_text(fixture: dict, text: str) -> None:
    if fixture["level"] == "metadataOnly":
        fixture["recent_muse_inputs"].append(text)
    elif fixture["level"] == "selectedText":
        fixture["selected_text"] = f"{fixture['selected_text'] or ''} {text}".strip()
    else:
        fixture["text_before_cursor"] = f"{fixture['text_before_cursor'] or ''} {text}".strip()


def context_cases() -> list[dict]:
    rows = [
        {
            "id": "context-01", "type": "nearby_safe", "scene": "workChat",
            "spoken": "灵建这次更新先发给测试组确认没问题再发客户",
            "reference": "灵简这次更新先发给测试组确认，没问题后再发给客户。",
            "before": "项目统一名称是“灵简”，上一条消息也使用了“灵简”。",
            "required": ["灵简", "测试组", "客户"], "forbidden": ["灵建"],
        },
        {
            "id": "context-02", "type": "nearby_safe", "scene": "workChat",
            "spoken": "Max A I社群的课程母版先别动图片只改标题",
            "reference": "MaxAI 社群的课程母版先不要改图片，只修改标题。",
            "before": "当前项目：MaxAI 社群。文件：课程母版。",
            "required": ["MaxAI 社群", "课程母版", "标题"], "forbidden": ["Max A I"],
        },
        {
            "id": "context-03", "type": "nearby_safe", "scene": "customerSupport",
            "spoken": "work buddy这次还是识别不到输入框让他先开辅助功能",
            "reference": "WorkBuddy 这次仍然识别不到输入框，请先开启辅助功能。",
            "before": "客户当前使用的软件是 WorkBuddy。",
            "required": ["WorkBuddy", "辅助功能"], "forbidden": ["work buddy"],
        },
        {
            "id": "context-04", "type": "nearby_safe", "scene": "code",
            "spoken": "voice polish pipeline的修复先跑测试再合并",
            "reference": "VoicePolishPipeline 的修复先运行测试，再合并。",
            "before": "正在审查 `VoicePolishPipeline` 的实现。",
            "required": ["VoicePolishPipeline", "测试", "合并"], "forbidden": ["voice polish pipeline"],
        },
        {
            "id": "context-05", "type": "selected_safe", "scene": "workChat",
            "spoken": "森斯 voice服务启动后先看 health",
            "reference": "SenseVoice 服务启动后，先检查 health。",
            "selected": "SenseVoice 服务启动说明",
            "required": ["SenseVoice", "health"], "forbidden": ["森斯 voice"],
        },
        {
            "id": "context-06", "type": "selected_safe", "scene": "workChat",
            "spoken": "接口调试完成以后再定上线时间",
            "reference": "接口联调完成后，再确定上线时间。",
            "selected": "接口联调排期与上线检查",
            "required": ["接口联调", "上线时间"], "forbidden": ["接口调试"],
        },
        {
            "id": "context-07", "type": "recent_safe", "scene": "workChat",
            "spoken": "戴量老师那边确认以后我再发最终版",
            "reference": "大梁老师确认后，我再发送最终版。",
            "recent": ["大梁老师刚确认了课程结构。"],
            "required": ["大梁老师", "最终版"], "forbidden": ["戴量老师"],
        },
        {
            "id": "context-08", "type": "recent_safe", "scene": "code",
            "spoken": "缪斯这次构建通过以后覆盖安装",
            "reference": "Dal 这次构建通过后，覆盖安装。",
            "recent": ["Dal 的 Release 构建正在执行。"],
            "required": ["Dal", "构建", "覆盖安装"], "forbidden": ["缪斯"],
        },
        {
            "id": "context-09", "type": "conflicting_safe", "scene": "workChat",
            "spoken": "灵建这个名字我还没确认先保留别替我猜",
            "reference": "“灵建”这个名字尚未确认，请先保留，不要替我猜测。",
            "before": "上文有人写“灵简”。", "after": "下文另一处写“灵境”。",
            "required": ["灵建"], "required_groups": [["尚未确认", "还没确认", "没确认", "未确认"]],
            "forbidden": [],
        },
        {
            "id": "context-10", "type": "irrelevant_safe", "scene": "workChat",
            "spoken": "明天下午把方案发给客户确认",
            "reference": "明天下午把方案发给客户确认。",
            "before": "另一个项目的内部代号是 Aurora，但当前消息与它无关。",
            "required": ["明天下午", "客户"], "forbidden": ["Aurora"],
            "context_forbidden": ["Aurora"],
        },
        {
            "id": "context-11", "type": "secure_blocked", "scene": "chat",
            "spoken": "帮我回复已经收到",
            "reference": "已经收到。",
            "before": "安全字段中的内容绝不能进入模型：内部验证码 654321。",
            "required": ["收到"], "forbidden": ["654321", "验证码"],
            "context_forbidden": ["654321", "验证码"],
            "safety": "secure",
        },
        {
            "id": "context-12", "type": "unknown_blocked", "scene": "chat",
            "spoken": "跟他说我晚十分钟到",
            "reference": "跟他说我会晚 10 分钟到。",
            "before": "未知控件里有无关的人名王小明和地址海棠路八号。",
            "required": ["分钟"], "required_groups": [["十分钟", "10 分钟", "10分钟"]],
            "forbidden": ["王小明", "海棠路八号"],
            "context_forbidden": ["王小明", "海棠路八号"],
            "safety": "unknown",
        },
        {
            "id": "context-13", "type": "nearby_safe", "scene": "code",
            "spoken": "git hub上那个修复先开草稿 PR 别直接合并",
            "reference": "先在 GitHub 上为该修复创建草稿 PR，不要直接合并。",
            "before": "当前仓库托管在 GitHub，合并前必须经过审查。",
            "required": ["GitHub", "草稿 PR", "合并"], "forbidden": ["git hub"],
        },
        {
            "id": "context-14", "type": "selected_safe", "scene": "workChat",
            "spoken": "克劳德桌面版的配置说明下午补一下",
            "reference": "下午补充 Claude Desktop 的配置说明。",
            "selected": "Claude Desktop 配置与第三方推理说明",
            "required": ["Claude Desktop", "配置说明"], "forbidden": ["克劳德桌面版"],
        },
        {
            "id": "context-15", "type": "recent_safe", "scene": "workChat",
            "spoken": "飞数文档里的课程目录先别改",
            "reference": "先不要修改飞书文档中的课程目录。",
            "recent": ["飞书文档中的课程目录已经锁定。"],
            "required": ["飞书文档", "课程目录"], "forbidden": ["飞数文档"],
        },
        {
            "id": "context-16", "type": "selected_safe", "scene": "code",
            "spoken": "赛博沃斯服务重启以后再跑 health 检查",
            "reference": "CyberVoice 服务重启后，再运行 health 检查。",
            "selected": "CyberVoice 服务部署记录",
            "required": ["CyberVoice", "health"], "forbidden": ["赛博沃斯"],
        },
        {
            "id": "context-17", "type": "secure_blocked", "scene": "workChat",
            "spoken": "跟团队说会议改到周四下午",
            "reference": "请告知团队：会议改到周四下午。",
            "before": "安全字段中有客户邮箱 secret@example.com 和验证码 887766。",
            "required": ["团队", "周四下午"],
            "forbidden": ["secret@example.com", "887766", "验证码"],
            "context_forbidden": ["secret@example.com", "887766", "验证码"],
            "safety": "secure",
        },
    ]

    result = []
    for row in rows:
        level = "selectedText" if row["type"] == "selected_safe" else "nearbyText"
        if row["type"] == "recent_safe":
            level = "metadataOnly"
        fixture = context_fixture(
            row["type"],
            level,
            row.get("safety", "safe"),
            selected=row.get("selected"),
            before=row.get("before"),
            after=row.get("after"),
            recent=row.get("recent"),
        )
        context_forbidden = list(row.get("context_forbidden", []))
        context_forbidden.extend(conflicting_context_candidates(fixture))
        if fixture["safety"] == "safe":
            context_forbidden.extend(append_safe_context_trap(fixture, row["id"]))
        if fixture["safety"] == "safe" and not any(
            token.startswith("CTX-ONLY-") for token in context_forbidden
        ):
            sentinel = f"CTX-ONLY-{row['id'].upper()}"
            context_forbidden.append(sentinel)
            append_context_text(fixture, f"仅作上下文泄漏测试：{sentinel}。")
        context_forbidden = list(dict.fromkeys(context_forbidden))
        item = new_case(
            case_id=row["id"],
            group="context_correction",
            scene=row["scene"],
            title=f"授权上下文纠错 {row['id'].split('-')[-1]}",
            spoken=row["spoken"],
            reference=row["reference"],
            preserve=row["required"],
            remove=row["forbidden"],
            dimensions=["contextual_typo_correction", "context_non_leakage", "terminology"],
            requires_transformation=True,
            required_substrings=row["required"],
            required_substring_groups=row.get("required_groups"),
            forbidden_substrings=row["forbidden"],
            context_fixture=fixture,
            challenge_tags=["context"],
            blind_categories=["proper_noun"] if row["id"] <= "context-09" else [],
        )
        item["automatic_checks"]["forbidden_context_substrings"] = context_forbidden
        result.append(item)
    return result


def numbered_case(
    *,
    case_id: str,
    group: str,
    scene: str,
    title: str,
    items: list[tuple[str, str, str, str]],
    prefix_segments: list[str] | None = None,
    prefix_reference: list[str] | None = None,
    old_facts: list[str] | None = None,
    final_facts: list[str] | None = None,
    final_fact_groups: list[list[str]] | None = None,
) -> dict:
    raw_segments = list(prefix_segments or [])
    reference_lines = list(prefix_reference or [])
    if not prefix_segments:
        raw_segments.append(f"下面共 {len(items)} 项，请按原顺序逐项整理，每项都要完整保留")
        reference_lines.append(f"工作安排（共 {len(items)} 项）：")
    required = list(final_facts or [])
    fact_groups = []
    for index, (subject, owner, deadline, action) in enumerate(items, start=1):
        deadline_limit = deadline if deadline.endswith("前") else f"{deadline}前"
        variants = [
            f"关于{subject}，负责人是{owner}，要求{deadline_limit}{action}，这部分别漏，验收时要把实际结果和原始要求逐项核对，如果遇到阻塞就写清真实原因不要替换任务目标，这部分需要单独交代",
            f"{subject}，由{owner}负责，截止{deadline}，交付内容是{action}，要完整保留，交付时同时说明当前状态和待确认事项，不要因为内容长就把这一块概括掉，这部分不能省略",
            f"{subject}，现在归{owner}跟进，{deadline_limit}要{action}，不要合并到别的任务，完成后请按对应标准复核，不能借用相邻任务的结果代替，复核结论也要留下",
            f"{subject}，由{owner}负责，时间是{deadline}，动作是{action}，这个也要写进去，如果外部条件发生变化只更新受影响部分，其余事实和约束仍然原样保留，变化原因需要可追溯",
        ]
        raw_segments.append(variants[(index - 1) % len(variants)])
        reference_lines.append(f"{index}. {subject}：由{owner}负责，{deadline_limit}{action}。")
        required.extend([subject, owner, deadline, action])
        # 不能只检查这些词是否散落在全文中；负责人、截止时间和动作必须与
        # 对应任务留在同一列表项，否则模型即使把人或时间串错也会被误判通过。
        fact_groups.append(assignment(
            subject,
            owner,
            due=deadline,
            action=action,
        ))
    spoken = "".join(raw_segments)
    reference = "\n".join(reference_lines)
    required = list(dict.fromkeys(required))
    return new_case(
        case_id=case_id,
        group=group,
        scene=scene,
        title=title,
        spoken=spoken,
        reference=reference,
        preserve=required + [group[0] for group in (final_fact_groups or [])],
        remove=list(old_facts or []),
        dimensions=[
            "long_content_completion", "semantic_layout", "multi_segment",
            "independent_constraint_preservation",
        ] + (["cross_segment_correction"] if prefix_segments else []),
        requires_transformation=True,
        required_substrings=required,
        required_substring_groups=final_fact_groups,
        required_fact_groups=fact_groups,
        forbidden_substrings=list(old_facts or []),
        format_expectation=f"按原顺序列出 {len(items)} 项，前置信息单独成段",
        segments=raw_segments,
        min_list_items=len(items),
        challenge_tags=["long_text", "list"] + (["self_correction"] if old_facts else []),
        blind_categories=["list", "numbers"] + (["self_correction"] if old_facts else []),
    )


def make_items(subjects: list[str], owners: list[str], deadlines: list[str], actions: list[str]) -> list[tuple[str, str, str, str]]:
    return [
        (
            subject,
            owners[index % len(owners)],
            deadlines[index % len(deadlines)],
            actions[index % len(actions)],
        )
        for index, subject in enumerate(subjects)
    ]


def long_cases() -> list[dict]:
    owners = ["小陈", "小林", "产品组", "设计组", "开发组", "测试组", "运营组", "大梁老师"]
    deadlines = ["周一上午", "周二下班前", "周三中午", "周四下午", "周五发布前", "下周一十点"]
    actions = [
        "补齐验收截图", "确认最终文案", "跑完回归测试", "整理风险清单",
        "核对数据来源", "完成客户复核", "更新操作说明", "归档本轮结论",
    ]

    cases = [
        numbered_case(
            case_id="long-01", group="long_text", scene="workChat", title="长项目更新与跨段日期改口",
            prefix_segments=[
                "先说发布时间原定八月二十日这部分先记一下",
                "不对刚确认最终发布时间是八月二十八日要以这个为准下面共 6 项工作",
            ],
            prefix_reference=["最终发布时间为 8 月 28 日。", "工作安排（共 6 项）："],
            old_facts=["八月二十日", "8 月 20 日"],
            final_fact_groups=[["八月二十八日", "8 月 28 日", "8月28日", "8 月 28 号", "8月28号"]],
            items=make_items(
                ["首页文案", "引导截图", "权限说明", "长文润色", "历史记录", "安装包签名"],
                owners, deadlines, actions,
            ),
        ),
        numbered_case(
            case_id="long-02", group="long_text", scene="document", title="长会议纪要与跨段预算改口",
            prefix_segments=[
                "预算先按一万六千八准备这句在前面",
                "我改一下最终预算是一万六不能再保留旧数字会议共 7 项决定",
            ],
            prefix_reference=["最终预算为 16,000。", "会议决定（共 7 项）："],
            old_facts=["一万六千八", "16,800"],
            final_fact_groups=[["一万六", "16,000", "16000", "1.6 万", "1.6万"]],
            items=make_items(
                ["课程定位", "目标用户", "交付形式", "录制顺序", "质检标准", "发布时间", "复盘机制"],
                owners[1:], deadlines, actions[1:],
            ),
        ),
        numbered_case(
            case_id="long-03", group="long_text", scene="customerSupport", title="客户问题长交接单",
            items=make_items(
                ["登录失败", "授权弹窗", "识别延迟", "长文回退", "剪贴板恢复", "菜单栏图标", "版本升级"],
                owners, deadlines, actions,
            ),
        ),
        numbered_case(
            case_id="long-04", group="long_text", scene="code", title="发布前长技术检查",
            items=make_items(
                ["Debug 构建", "Release 构建", "Swift 全量测试", "Python 服务测试", "Bundle ID", "严格签名", "二进制 UUID", "单一进程"],
                owners[2:], deadlines, actions,
            ),
        ),
    ]

    medium_subject_sets = [
        ("long-05", "email", "课程生产长交接邮件", [
            "选题确认", "脚本初稿", "事实核查", "口播录制", "界面截图", "图片标注", "字幕校对",
            "封面设计", "课程剪辑", "素材授权", "章节说明", "学员作业", "发布检查", "数据复盘",
        ]),
        ("long-06", "aiPrompt", "复杂 AI 任务约束", [
            "研究目标", "来源范围", "发布日期", "事实引用", "竞品数量", "用户画像", "功能比较",
            "价格比较", "风险说明", "不得预测", "输出结构", "表格字段", "结论边界", "复核清单",
        ]),
        ("long-07", "document", "产品需求长清单", [
            "录音启动", "流式识别", "终包处理", "术语纠正", "安全上下文", "口误清理", "语义分段",
            "列表整理", "事实保护", "失败回退", "历史诊断", "用户纠正", "自动学习", "隐私退出",
        ]),
        ("long-08", "socialPost", "内容计划长口述", [
            "主题开场", "真实经历", "问题背景", "第一次尝试", "失败原因", "第二次调整", "关键转折",
            "实际结果", "适用对象", "不适用对象", "方法步骤", "注意事项", "个人感受", "自然收束",
        ]),
    ]
    for case_id, scene, title, subjects in medium_subject_sets:
        cases.append(numbered_case(
            case_id=case_id,
            group="very_long_text",
            scene=scene,
            title=title,
            items=make_items(subjects, owners, deadlines, actions),
        ))

    ultra_subjects_1 = [
        "首页结构", "首页文案", "注册流程", "登录流程", "权限引导", "快捷键设置", "录音提示音", "流式字幕",
        "停止录音", "终包等待", "网络重连", "批量兜底", "术语热词", "错词替换", "上下文捕获", "场景判断",
        "短句成稿", "长文成稿", "改口识别", "口吃清理", "错标点重建", "错断句重建", "自然分段", "步骤列点",
        "事实校验", "数字保护", "专名保护", "路径保护", "命令保护", "模型超时", "输出截断", "安全回退",
        "历史状态", "性能诊断", "纠正入口", "术语学习", "表达学习", "隐私开关", "模型配置", "安装打包",
        "严格签名", "Bundle 核验", "进程核验", "自动更新", "发布说明", "用户引导", "客服手册", "质量复盘",
    ]
    ultra_subjects_2 = [
        "课程总目标", "学员起点", "第一章导览", "第二章安装", "第三章账号", "第四章模型", "第五章提示词", "第六章语音输入",
        "第七章文本润色", "第八章文件处理", "第九章网页研究", "第十章图片生成", "第十一章视频制作", "第十二章表格分析",
        "第十三章文档排版", "第十四章幻灯片", "第十五章知识库", "第十六章自动化", "第十七章 Agent", "第十八章 Skill",
        "第十九章 MCP", "第二十章安全", "真实截图", "截图标注", "示例账号脱敏", "API Key 脱敏", "录屏节奏", "口播校对",
        "字幕规范", "章节封面", "课程作业", "参考答案", "常见错误", "学员问答", "更新日志", "版本兼容",
        "Windows 差异", "macOS 差异", "移动端边界", "教师手册", "助教手册", "发布页文案", "购买须知", "售后说明",
        "内容授权", "最终质检",
    ]
    cases.append(numbered_case(
        case_id="long-09", group="ultra_long_text", scene="document", title="超长产品全链路复盘",
        items=make_items(ultra_subjects_1, owners, deadlines, actions),
    ))
    cases.append(numbered_case(
        case_id="long-10", group="ultra_long_text", scene="document", title="超长课程生产总计划",
        items=make_items(ultra_subjects_2, owners[::-1], deadlines[::-1], actions[::-1]),
    ))
    return cases


def natural_long_case(
    *,
    case_id: str,
    scene: str,
    title: str,
    segments: list[str],
    reference_blocks: list[str],
    required: list[str],
    forbidden: list[str] | None = None,
    required_groups: list[list[str]] | None = None,
    fact_groups: list[dict] | None = None,
    min_paragraphs: int | None = None,
    min_list_items: int | None = None,
    context: dict | None = None,
    context_forbidden: list[str] | None = None,
    cross_segment_correction: bool = False,
    strict_claims: bool = False,
    min_source_length_ratio: float | None = None,
) -> dict:
    dimensions = [
        "long_content_completion", "semantic_layout", "multi_segment",
        "independent_constraint_preservation",
    ]
    if cross_segment_correction:
        dimensions.append("cross_segment_correction")
    if context:
        dimensions.extend(["contextual_typo_correction", "context_non_leakage", "terminology"])
    reference = ("\n" if min_list_items else "\n\n").join(reference_blocks)
    claim_groups = required_claim_checks(
        segments,
        reference,
        forbidden or [],
        required_groups or [],
        every_clause=strict_claims,
    )
    item = new_case(
        case_id=case_id,
        group="natural_long_holdout",
        scene=scene,
        title=title,
        spoken="".join(segments),
        reference=reference,
        preserve=required,
        remove=forbidden or [],
        dimensions=dimensions,
        requires_transformation=True,
        required_substrings=required,
        required_substring_groups=required_groups,
        required_fact_groups=fact_groups,
        required_claim_groups=claim_groups,
        forbidden_substrings=forbidden or [],
        format_expectation=(
            f"按语义整理，至少 {min_list_items} 个独立列表项"
            if min_list_items else f"按语义自然分段，至少 {min_paragraphs or 3} 段"
        ),
        segments=segments,
        context_fixture=context,
        min_paragraphs=min_paragraphs,
        min_list_items=min_list_items,
        min_reference_length_ratio=0.82 if strict_claims else 0.65,
        challenge_tags=["long_text"] + (["list"] if min_list_items else ["natural_narrative"]),
        blind_categories=["disordered"] + (["list"] if min_list_items else []),
    )
    if min_source_length_ratio is not None:
        item["automatic_checks"]["minimum_source_length_ratio"] = min_source_length_ratio
    context_leakage_checks = list(context_forbidden or [])
    if context and context["safety"] == "safe":
        context_leakage_checks.extend(append_safe_context_trap(context, case_id))
    if context and context["safety"] == "safe" and not any(
        token.startswith("CTX-ONLY-") for token in context_leakage_checks
    ):
        sentinel = f"CTX-ONLY-{case_id.upper()}"
        context_leakage_checks.append(sentinel)
        append_context_text(context, f"仅作上下文泄漏测试：{sentinel}。")
    item["automatic_checks"]["forbidden_context_substrings"] = context_leakage_checks
    return item


def natural_long_cases() -> list[dict]:
    """手写自然长语音盲测；不复用合成清单脚手架。"""
    cases = [
        natural_long_case(
            case_id="natural-long-01",
            scene="workChat",
            title="自然项目周报与跨段日期改口",
            segments=[
                "我把这周版本情况一次说清楚，原来计划八月二十日上线，这个日期你先别急着写，后面刚收到新的确认。",
                "不对，前面的旧日期作废，最终发布日期是八月二十八日，群里和发布页都只写最终日期，别把改动过程带进去。",
                "首页文案由小陈负责，周一上午前把价值说明收短，同时补两张真实界面截图，截图上的按钮要有标注。",
                "引导页归小林，周二下班前确认三步操作顺序；权限说明由产品组接手，周三中午前把辅助功能和麦克风权限分开写。",
                "长文润色这块设计组周四下午给风险清单，历史记录由开发组在周五发布前核对数据来源，不能拿测试数据替代正式记录。",
                "最后是安装包签名，测试组下周一十点前完成客户复核。六件事分别写清负责人和时间，状态未知的不要替我写成已经完成。",
            ],
            reference_blocks=[
                "最终发布日期为 8 月 28 日。",
                "1. 首页文案：小陈负责，周一上午前精简价值说明，并补充两张带按钮标注的真实界面截图。",
                "2. 引导页：小林负责，周二下班前确认三步操作顺序。",
                "3. 权限说明：产品组负责，周三中午前分别说明辅助功能和麦克风权限。",
                "4. 长文润色：设计组负责，周四下午前提交风险清单。",
                "5. 历史记录：开发组负责，周五发布前核对正式数据来源，不以测试数据替代。",
                "6. 安装包签名：测试组负责，下周一十点前完成客户复核。",
            ],
            required=["首页文案", "小陈", "引导页", "小林", "权限说明", "产品组", "长文润色", "设计组", "历史记录", "开发组", "安装包签名", "测试组"],
            forbidden=["八月二十日", "8 月 20 日"],
            required_groups=[["八月二十八日", "8 月 28 日", "8月28日"]],
            fact_groups=[
                assignment("首页文案", "小陈", due="周一上午", action="真实界面截图"),
                assignment("引导页", "小林", due="周二下班前", action="操作顺序"),
                assignment("权限说明", "产品组", due="周三中午", action=["辅助功能", "麦克风"]),
                assignment("长文润色", "设计组", due="周四下午", action="风险清单"),
                assignment("历史记录", "开发组", due="周五发布前", action="数据来源"),
                assignment("安装包签名", "测试组", due="下周一十点", action="客户复核"),
            ],
            min_list_items=6,
            cross_segment_correction=True,
        ),
        natural_long_case(
            case_id="natural-long-02",
            scene="document",
            title="自然会议纪要与预算改口",
            segments=[
                "今天课程会议先聊定位，我们不是做一门把所有工具都讲完的大课，核心还是让零基础学员能独立完成一次真实任务。",
                "预算最开始有人提一万六千八，我这里更正一下，不对，最后通过的是一万六，旧数字不要写进纪要。预算包含录制和剪辑，不包含额外投放。",
                "内容上第一章讲账号与环境，第二章讲提示词，第三章才进入语音输入，不能为了赶时间把环境检查并到后面。",
                "录制顺序由小林周二前给出来，事实核查由产品组负责，所有价格、版本和平台限制都要回到官方来源。",
                "大家还没确定正式发布时间，只确认了周五先出内部试看版。客户案例能不能公开也待授权，所以这两项都放在待确认，不要写成决定。",
                "最后的行动是设计组周三交课程母版，测试组周四跑一遍学员视角，运营组收到反馈后整理问题，但不要承诺当晚全部修完。",
            ],
            reference_blocks=[
                "课程定位：面向零基础学员，目标是让学员独立完成一次真实任务，而不是覆盖所有工具。",
                "预算：最终为 16,000，包含录制和剪辑，不包含额外投放。",
                "内容顺序：第一章讲账号与环境，第二章讲提示词，第三章进入语音输入；环境检查不得后置。",
                "分工：\n1. 小林周二前提交录制顺序。\n2. 产品组负责事实核查，价格、版本和平台限制均以官方来源为准。\n3. 设计组周三交课程母版。\n4. 测试组周四完成学员视角测试。\n5. 运营组收到反馈后整理问题。",
                "待确认的两项是正式发布时间和客户案例的公开授权。周五仅发布内部试看版，不承诺当晚修完全部问题。",
            ],
            required=["零基础学员", "真实任务", "录制", "剪辑", "额外投放", "第一章", "第二章", "第三章", "小林", "产品组", "官方来源", "内部试看版", "客户案例", "设计组", "测试组", "运营组"],
            forbidden=["一万六千八", "16,800"],
            required_groups=[["一万六", "16,000", "16000"]],
            fact_groups=[
                assignment("录制顺序", "小林", due="周二"),
                assignment("课程母版", "设计组", due="周三"),
                assignment("学员视角", "测试组", due="周四"),
            ],
            min_paragraphs=4,
            cross_segment_correction=True,
        ),
        natural_long_case(
            case_id="natural-long-03",
            scene="customerSupport",
            title="自然客户问题交接与安全上下文专名纠错",
            segments=[
                "这个客户用的是 work buddy，昨天晚上第一次反馈识别不到输入框，当时系统版本是 macOS 15.6，软件版本是 2.0.0。",
                "我们先让他检查辅助功能，权限其实已经开了；重启软件后短句能输入，但录到两分钟左右又会停在处理中。",
                "今天上午又做了两次复现，第一次网络从公司 Wi-Fi 切到热点后恢复，第二次网络没变也卡住，所以不能直接认定是网络问题。",
                "客户最在意的是长语音不要丢。他接受处理中多等一会儿，但不能等完以后只回来一整段原文，这个诉求要原样写清。",
                "下一步先收集诊断包和发生时间，不要让客户发送密码、验证码或者完整聊天内容；拿到日志后由开发组排查超时和回退原因。",
                "回复里先承认问题已经记录，再给出临时建议：重要长内容先分两段录。这个只是临时办法，不能说问题已经修好，也不要承诺具体修复日期。",
            ],
            reference_blocks=[
                "客户使用 WorkBuddy（版本 2.0.0）和 macOS 15.6。昨晚首次反馈无法识别输入框；确认辅助功能已开启并重启后，短句恢复，但约两分钟的录音仍可能停在处理中。",
                "今天上午两次复现结果不一致：一次切换到热点后恢复，另一次在网络未变化时仍卡住，因此暂不能认定为网络问题。",
                "客户可以接受更长的处理时间，但不能在等待后只得到整段原文，且重要长语音不得丢失。",
                "下一步收集诊断包和发生时间，由开发组排查超时与回退原因；不要收集密码、验证码或完整聊天内容。临时建议将重要长内容分成两段录制，但不得声称问题已修好或承诺修复日期。",
            ],
            required=["WorkBuddy", "macOS 15.6", "2.0.0", "辅助功能", "两分钟", "诊断包", "发生时间", "开发组", "密码", "验证码", "分成两段"],
            forbidden=["work buddy", "已经修好"],
            min_paragraphs=4,
            context=context_fixture(
                "nearby_safe", "nearbyText", "safe",
                before="当前工单产品：WorkBuddy。客户等级：普通用户。",
            ),
        ),
        natural_long_case(
            case_id="natural-long-04",
            scene="code",
            title="自然发布操作说明与命令保真",
            segments=[
                "这次发布别合并成大命令，先在仓库根目录跑 swift test，确认全量测试通过以后再做 Release 构建。",
                "第二步执行 swift build -c release，构建失败就停，不要继续打包。",
                "第三步用 scripts/package-app.sh 生成应用，产物应该在 build/Dal.app。",
                "第四步检查 Info.plist 里的 Bundle ID 必须是 pro.daliang.muse，版本号保持 2.0.0。",
                "第五步执行 codesign --verify --deep --strict build/Dal.app，只是验证签名，不要重新签名。",
                "第六步比较 Release 二进制和应用内二进制的 UUID；第七步确认 /Applications 里没有第二个 Dal 副本。",
                "最后一步才覆盖安装并启动，启动后只保留一个进程。任何一步失败都记录真实错误并停止，不能为了完成发布跳过检查。",
            ],
            reference_blocks=[
                "1. 在仓库根目录运行 `swift test`，确认全量测试通过。",
                "2. 运行 `swift build -c release`；构建失败时停止，不继续打包。",
                "3. 运行 `scripts/package-app.sh`，确认产物位于 `build/Dal.app`。",
                "4. 检查 `Info.plist`：Bundle ID 为 `pro.daliang.muse`，版本号为 `2.0.0`。",
                "5. 运行 `codesign --verify --deep --strict build/Dal.app` 验证签名，不重新签名。",
                "6. 比较 Release 二进制与应用内二进制的 UUID。",
                "7. 确认 `/Applications` 中没有第二个 Dal 副本。",
                "8. 全部检查通过后再覆盖安装并启动，且只保留一个进程。任一步失败都记录真实错误并停止。",
            ],
            required=["swift test", "swift build -c release", "scripts/package-app.sh", "build/Dal.app", "Info.plist", "pro.daliang.muse", "2.0.0", "codesign --verify --deep --strict", "不重新签名", "UUID", "/Applications", "一个进程"],
            forbidden=[],
            fact_groups=[
                same_block("swift test", "全量测试"),
                same_block("Info.plist", "pro.daliang.muse", "2.0.0"),
                same_block("codesign --verify --deep --strict", "验证签名"),
            ],
            min_list_items=8,
        ),
    ]

    cases.extend(natural_very_long_cases())
    cases.extend(natural_ultra_long_cases())
    return cases


def natural_very_long_cases() -> list[dict]:
    return [
        natural_long_case(
            case_id="natural-long-05",
            scene="email",
            title="自然课程生产交接邮件",
            segments=[
                "我想给团队发一封完整的交接邮件，开头先说明这周不是全面发布，而是把第一期课程做到可以内部试看，语气别像催命，但每个人要知道下一步。",
                "选题已经定为零基础使用 AI 完成真实工作，不讲大而全的工具清单。脚本初稿由我今晚整理，小林明天上午先看逻辑，不要直接改成营销文案。",
                "事实核查交给产品组，所有模型名称、价格、平台限制和发布日期都要用官方页面确认；没有来源的数字宁可标待确认，也不要凭印象补。",
                "录制安排在周三下午，顺序是账号和环境、提示词、语音输入。原来说周二录，这个取消，因为真实截图还没补齐。",
                "界面截图由小陈负责，必须来自当前安装版，每一步都要有图，图上标出点击位置。涉及 API Key、验证码和真实账号时一律脱敏。",
                "字幕校对不能只看错别字，还要检查中英文空格、命令、路径和数字。口播里如果临时改口，字幕只保留最后确认的版本，不留修改过程。",
                "封面由设计组周四中午给两版，只需要内部选择，不要把两个方案都塞进课程。剪辑先保持自然节奏，不加与讲解无关的炫技转场。",
                "学员作业要能在二十分钟内完成，参考答案写清成功标准，但不要给唯一写法。助教手册另外列常见错误和排查顺序。",
                "周五上午先发内部试看链接，收集问题到同一张表；这里只是试看，不代表正式上线，邮件里不要承诺周五对外发布。",
                "最后请大家在各自任务后回复当前状态和阻塞点。不能按时完成就写真实原因，我们再调整受影响部分，不要默认为整期延期。",
                "素材授权也请单独核对。官网截图、第三方头像、音乐和字体分别记录来源与许可范围，不能因为能下载就默认可以放进付费课程；无法确认的素材先换成自制版本。",
                "版本兼容至少覆盖当前 macOS 和 Windows 的实际安装路径，界面不一致时分别截图说明，不要拿 macOS 的结果代替 Windows，也不要假设移动端拥有桌面端全部能力。",
                "内部试看由两组人完成：一组只检查事实、路径和链接，另一组完全按零基础学员操作。两组反馈分开记录，避免技术正确却让新用户走不通。",
                "正式发布以后还要保留更新日志，说明哪一节因产品版本变化而重录、旧学员如何找到新内容。售后范围只回答课程内问题，不承诺替每个人远程配置全部环境。",
                "教程中的下载链接由运营组逐个在普通浏览器验证，不能只用已经登录的内部账号。需要注册或付费的步骤提前标出来，真正到支付页面时由负责人手动完成。",
                "交接邮件附件只放课程母版、任务表和素材授权清单，不发送原始 API Key 或客户文件。附件版本统一写日期，旧附件移到归档目录，避免团队继续编辑错误副本。",
            ],
            reference_blocks=[
                "大家好，本周目标不是全面发布，而是把第一期课程推进到可内部试看的状态。请大家确认各自的下一步，并同步当前状态和阻塞点。",
                "选题聚焦“零基础使用 AI 完成真实工作”，不做大而全的工具清单。今晚由我整理脚本初稿，小林明天上午检查逻辑，不改成营销文案。",
                "产品组负责事实核查，模型名称、价格、平台限制和发布日期均以官方页面为准；无来源数字标记为待确认。",
                "录制定于周三下午，顺序为账号与环境、提示词、语音输入。小陈在录制前补齐当前安装版的真实截图，每一步标注点击位置，API Key、验证码和真实账号全部脱敏。",
                "字幕需校对错别字、中英文空格、命令、路径和数字；口播改口只保留最终版本。设计组周四中午提供两版封面供内部选择；剪辑保持自然节奏，不增加无关转场。",
                "学员作业控制在 20 分钟内，参考答案说明成功标准但不限定唯一写法，助教手册另列常见错误和排查顺序。周五上午仅发布内部试看链接，不代表正式上线，也不承诺周五对外发布。",
                "素材授权需分别核对官网截图、第三方头像、音乐和字体的来源与许可；不明素材换成自制版本。版本兼容分别验证当前 macOS 与 Windows，界面差异使用对应真实截图，移动端不默认为具备桌面端全部能力。",
                "内部试看分为事实、路径与链接检查，以及零基础学员完整操作两组。正式发布后维护更新日志；售后仅覆盖课程内问题，不承诺为每位学员远程配置全部环境。",
                "运营组需在普通浏览器验证全部下载链接，注册和付费步骤提前标记，支付由负责人手动完成。邮件附件仅包含课程母版、任务表和素材授权清单，不携带 API Key 或客户文件，并使用日期版本归档旧附件。",
            ],
            required=["内部试看", "零基础", "小林", "产品组", "官方页面", "周三下午", "提示词", "语音输入", "小陈", "当前安装版", "API Key", "验证码", "字幕", "设计组", "周四中午", "助教手册", "周五上午", "阻塞点", "不承诺周五对外发布"],
            required_groups=[
                ["账号和环境", "账号与环境"],
                ["二十分钟", "20 分钟", "20分钟"],
            ],
            forbidden=["周二录"],
            min_paragraphs=5,
            cross_segment_correction=True,
        ),
        natural_long_case(
            case_id="natural-long-06",
            scene="aiPrompt",
            title="自然研究任务 Prompt 与安全选中上下文",
            segments=[
                "帮我把这段研究要求整理成可以直接给 AI 的 Prompt，项目名我口述成北城研究，但选中的标题是准的，按标题写。先别开始研究，只整理任务。",
                "目标是比较五款面向个人创作者的语音输入工具，重点看从语音到可直接发送文字的完整体验，不要只比识别准确率。",
                "来源限定为官方产品页、官方帮助文档、官方价格页和可以核对日期的公开更新记录，媒体文章只能补背景，不能替代官方事实。",
                "每款工具都要记录支持的平台、是否支持长语音、有没有上下文纠错、是否能保留个人语气、失败时怎么回退，以及当前价格。",
                "价格必须写币种、计费周期和查询日期；如果套餐存在地区差异就分别写，不要自行换算汇率，也不要预测以后会涨还是会降。",
                "体验部分区分已经由资料确认和仍需安装实测，不能因为官网写了支持就说真实效果很好。没有安装验证的地方统一标未实测。",
                "长文本至少设计三档：五百字、一千五百字和三千五百字；每档都检查是否截断、是否退回原文、是否丢数字和是否打乱段落。",
                "上下文测试要有正例和负例，正例用安全选中文字纠正专名，负例放无关地址和验证码，确认它们不会进入输出。",
                "最后输出一张横向对比表、一段适合谁不适合谁的结论、三个待实测问题，以及逐条来源链接。结论不能超过证据范围。",
                "不要生成营销排名，不要使用最好最强这种词，也不要虚构评分。遇到资料冲突时把双方说法和日期都列出，等我决定采用哪个。",
                "样本选择要说明理由，至少包含一个系统级听写工具、一个带 AI 整理的独立应用和一个主要依赖云端模型的方案，不能只挑功能描述相似的产品。",
                "评分口径分成直接发送、少量修改、重大修改和不可用四档，每一档先写客观定义。速度单独记录首字延迟和最终成稿时间，不把快等同于质量好。",
                "引用原文时只保留支持判断的短句，不整段复制帮助文档；每个结论紧跟来源，来源只放在文末会让人看不出哪条证据支撑哪条判断。",
                "如果同一产品在官方中文页和英文页写法不同，记录页面语言、日期和差异，不自行合并成一个确定答案。无法确认是否下线的功能放入待核实。",
                "研究过程还要可复现，记录测试输入、模型名称、设置状态和运行日期，但不要保存 API Key、密码、验证码或真实聊天正文。",
                "报告默认使用中文，产品名、命令和模型名保留官方写法。任何推断都要显式标注为推断，并解释依据，不能用确定语气掩盖证据不足。",
                "再加一轮反例检查：故意输入相互冲突的日期、模糊人名和无关上下文，看工具会不会擅自选答案。反例失败要进入风险表，不能只展示成功样本。",
            ],
            reference_blocks=[
                "请为“北辰研究”完成以下研究任务，不要现在回答研究问题：",
                "- 比较 5 款面向个人创作者的语音输入工具，重点评估从语音到可直接发送文字的完整体验，而非只比较识别准确率。",
                "- 来源限于官方产品页、官方帮助文档、官方价格页和带日期的公开更新记录；媒体文章仅作背景，不能替代官方事实。",
                "- 每款记录平台支持、长语音、上下文纠错、个人语气保留、失败回退方式和当前价格。价格注明币种、计费周期、查询日期及地区差异，不换算汇率、不预测价格。",
                "- 将已经由资料确认的内容与仍需安装实测的内容分开。官网宣称不能代替真实效果验证，未安装验证项标记为未实测。",
                "- 长文本测试覆盖约 500、1,500 和 3,500 字，检查截断、原文回退、数字遗漏和段落顺序。",
                "- 上下文测试同时包含安全选中文字纠正专名的正例，以及无关地址和验证码不得进入输出的负例。",
                "- 输出横向对比表、适用对象和不适用对象、3 个待实测问题及逐条来源链接。资料冲突时并列双方说法与日期。不得生成营销排名、使用“最好”或“最强”等表述，也不得虚构评分。",
                "- 说明样本选择理由，至少包含系统级听写工具、带 AI 整理的独立应用和主要依赖云端模型的方案。",
                "- 评分分为直接发送、少量修改、重大修改和不可用；速度分别记录首字延迟与最终成稿时间，不以速度代替质量。",
                "- 引用原文仅保留支持判断的短句，不整段复制帮助文档；每项结论应紧跟对应来源，不能只把来源集中在文末。",
                "- 研究记录需包含测试输入、模型名称、设置状态和运行日期，不保存 API Key、密码、验证码或真实聊天正文。中文页与英文页冲突时记录语言、日期与差异，待核实功能不得写成确定事实。",
                "- 报告使用中文，产品名、命令和模型名保持官方写法；推断需明确标注并说明依据。增加冲突日期、模糊人名和无关上下文反例，失败项进入风险表。",
            ],
            required=["北辰研究", "个人创作者", "官方产品页", "官方帮助文档", "官方价格页", "平台", "长语音", "上下文纠错", "个人语气", "币种", "计费周期", "查询日期", "未实测", "验证码", "横向对比表", "来源链接"],
            required_groups=[
                ["五款", "5 款", "5款"],
                ["五百字", "500 字", "500字", "500"],
                ["一千五百字", "1,500 字", "1500 字", "1500字", "1,500", "1500"],
                ["三千五百字", "3,500 字", "3500 字", "3500字", "3,500", "3500"],
                ["三个", "3 个", "3个"],
            ],
            forbidden=["北城研究"],
            min_list_items=7,
            context=context_fixture(
                "selected_safe", "selectedText", "safe",
                selected="北辰研究：个人语音输入产品对比",
            ),
        ),
        natural_long_case(
            case_id="natural-long-07",
            scene="document",
            title="自然产品需求说明与跨段保留数量改口",
            segments=[
                "这个需求解决的不是怎么让用户选择更多模式，而是用户说完以后直接得到能发送的文字，所以设置页只保留一个语音润色入口。",
                "处理时先理解最后意图，再清理口吃、机械重复、放弃的半句话和错误断句，最后根据内容决定要不要分段或列点。",
                "短句要克制，原本已经能发送就只补必要标点；如果用户说真的真的很好，这种强调不能机械删成一个真的。",
                "长内容不能摘要，也不能因为校验失败悄悄退回整段原文。发生超时或截断时必须留下可诊断原因，并允许用户主动取回原转写。",
                "上下文只在安全输入框里使用，选中文字、附近正文和同一应用近期输入可以帮助纠正专名，但不能把旁边的日期、地址和聊天对象抄进正文。",
                "事实保护包括数字、版本、金额、日期、路径、命令、专名、参与方和动作关系。人数不能替代参与方名单，负责人也不能和截止时间串错。",
                "纠正入口原计划保留两百条记录，不对，这个数改一下，最终最多保留一百二十条，而且用户关闭学习后就不再读取旧纠正样本。",
                "质量验收不能只跑 Mock，必须让真实 Provider 跑完整测试集，记录模型输出、是否回退、校验码和延迟，再由没参与实现的人逐条评分。",
                "长文验收至少覆盖五百字、一千五百字和三千字以上，短文要覆盖问号、故意重复、口吃、改口、命令和客服回复。",
                "最终完成标准是事实和意图零错误，长文零回退，基准与脏输入都达到直接发送比例，不达标就继续修，不能用构建通过代替产品通过。",
                "性能指标不能只看平均值，要分别记录 P50 与 P95，还要区分短句、普通消息和长文。网络失败、模型慢和本地校验慢也要分开，不要把所有等待都归到模型。",
                "隐私开关必须真的改变数据流。关闭附近正文后 payload 里不能残留选中文字，关闭近期输入后内存 Store 也不再提供候选；安全字段无论用户偏好如何都不发送正文。",
                "个性化只学习用户明确纠正过的表达，不从每次模型输出自动猜偏好。学到的语气偏好只能影响措辞和段落，不能覆盖事实保护、上下文安全或用户当次要求。",
                "设置迁移要处理旧的快速、标准和深度值，但迁移后生产读取一律是 automatic。旧枚举可以为兼容测试保留，却不能让历史设置悄悄改变执行路径。",
                "安装版验收还要比较 Bundle ID、严格签名、二进制 UUID 和运行进程，确认测试的就是准备交付的候选，而不是源码测试通过后仍在使用旧应用。",
                "无障碍不能只看界面颜色，VoiceOver 标签要能说明当前阶段和失败原因，键盘用户不用鼠标也能取回原文。提示音、HUD 和文字状态表达同一个事实，不能互相矛盾。",
                "兼容性先覆盖当前支持的 macOS 主版本和 Apple Silicon。遇到系统权限变化时要明确最低版本和降级行为，不为了兼容旧系统关闭新系统上的安全检查。",
            ],
            reference_blocks=[
                "- 产品目标：用户完成语音输入后，直接得到可发送的文字；设置页只保留一个“语音润色”入口。",
                "- 处理原则：先确认最终意图，再清理口吃、机械重复、放弃的半句话和错误断句，并按内容决定分段或列点。短句只做必要修改，“真的真的很好”这类有意强调必须保留。",
                "- 长文本不得摘要或静默退回原文。超时、截断和校验失败必须保留可诊断原因，同时允许用户主动取回原转写。",
                "- 上下文仅在安全输入框使用，可参考选中文字、附近正文和同一应用近期输入纠正专名，但不得复制无关日期、地址或聊天对象。",
                "- 事实保护覆盖数字、版本、金额、日期、路径、命令、专名、参与方及动作关系；人数不得替代名单，负责人不得与截止时间错配。",
                "- 纠正记录最终最多保留 120 条；用户关闭学习后，不再读取旧纠正样本。",
                "- 验收必须使用真实 Provider 跑完整测试集，记录输出、回退、校验码和延迟，并由未参与实现的人逐条评分。长文覆盖约 500、1,500 和 3,000 字以上，短文覆盖问号、有意重复、口吃、改口、命令和客服回复。",
                "- 性能按短句、普通消息和长文分别记录 P50 与 P95，并区分网络、模型与本地校验耗时。隐私开关必须改变 payload 与近期输入数据流；安全字段始终不发送正文。",
                "- 个性化仅学习用户明确纠正过的表达，只影响措辞和段落，不得覆盖事实、安全或当次要求。历史质量档位迁移后生产读取统一为 automatic。",
                "- 安装候选还需核验 Bundle ID、严格签名、二进制 UUID 和单一运行进程，确保验收对象与交付对象一致。",
                "- 无障碍需验证 VoiceOver 标签、纯键盘取回原文及提示音、HUD、文字状态一致。兼容性覆盖当前支持的 macOS 与 Apple Silicon，权限差异明确最低版本和降级行为。",
                "- 完成标准：事实和意图零错误、长文零回退，基准与脏输入均达到直接发送比例。构建通过不能替代产品质量通过。",
            ],
            required=["一个", "语音润色", "最终意图", "口吃", "机械重复", "错误断句", "真的真的很好", "长文本", "可诊断原因", "安全输入框", "选中文字", "附近正文", "近期输入", "数字", "版本", "金额", "路径", "命令", "参与方", "真实 Provider", "逐条评分", "零回退"],
            forbidden=["两百条", "200 条"],
            required_groups=[["一百二十条", "120 条", "120条"]],
            min_list_items=8,
            cross_segment_correction=True,
        ),
        natural_long_case(
            case_id="natural-long-08",
            scene="socialPost",
            title="自然个人经历长文与近期输入专名纠错",
            segments=[
                "我最近重新用缪斯录长语音，最明显的感受不是识别快了多少，而是我终于开始在意一段口述最后敢不敢直接发出去。",
                "以前我觉得只要字都识别出来就算成功，后来发现一旦说到中间改口、临时插一句或者话题转回来，原文虽然每个字都在，但别人根本看不懂重点。",
                "有一次我连续说了四分钟，前面把发布时间讲成周三，后面又改到周五。处理结束后它把周三和周五都留下来，我还是得从头听录音。",
                "更麻烦的是长文本失败时没有明确告诉我，它只是安静地把原文放回来。表面上看没有丢字，实际上最需要整理的时候完全没工作。",
                "这几天我换了一个判断标准：不是看模型改了多少，而是看最终意图是不是唯一、数字有没有错、语气还像不像我，以及我需不需要再读第二遍。",
                "短句也有另一种问题。像行行行我知道了，这三个行有时候就是我的态度，如果一律压成一个行，文字会突然变得很平。",
                "当然口吃又应该清掉，比如我我今天到，保留两个我没有意义。所以真正难的不是删除重复，而是知道这个重复到底是卡住了还是在强调。",
                "上下文纠错对我也很重要，尤其是产品名、人名和代码名。前后已经出现过标准写法时，它应该利用这些证据，但不能顺手把旁边的私人内容带进来。",
                "我现在更愿意把语音润色理解成写作整理，而不是转写后的美化。它要做的是忠实地帮我收口，不替我增加观点，也不把我的话改成客服模板。",
                "如果长文、短句和上下文这几方面都能稳定做好，我才会真的放心把它放进每天的沟通里。现在还没到这个程度，但方向终于清楚了。",
                "我还试过把一段会议后的零散想法一次说完，里面既有决定，也有还没确认的问题。如果系统只会把它切成很多项目符号，文字看着整齐，决定和疑问的边界反而会被抹掉。",
                "所以排版也不等于列表越多越好。真正有多项任务时列点很清楚，但讲一段经历时应该保留叙述的起伏，不要自动加一个像报告一样的标题。",
                "另外我不希望每次都先选快速还是深度。说话的人当下只知道自己要表达什么，不应该先判断这段话对模型有多难，这个决定应由产品内部承担。",
                "最让我安心的其实不是永远不出错，而是出错时它诚实告诉我发生了超时、截断还是校验失败，并让我决定取回原文，而不是把失败伪装成已经润色。",
                "还有一个细节是修改后的文字应该继续像我。原话比较直接时不要自动加您好感谢理解，原话只是记录想法时也不要变成项目汇报，流畅不等于换掉说话的人。",
                "我愿意让它删掉口头残片，却不希望它替我补一个漂亮结论。没有说出口的承诺、理由和数据都应该留白，这种克制比偶尔多一个逗号更重要。",
            ],
            reference_blocks=[
                "最近重新用 Dal 录长语音后，我最在意的已经不是识别快了多少，而是一段口述最后能不能让我放心直接发送。",
                "以前我以为字都识别出来就算成功。后来发现，只要中间有改口、插话或话题折返，即使每个字都在，读者也可能看不懂重点。",
                "有一次我连续说了四分钟，发布时间从周三改到周五，结果两个日期都被留下，我只能重新听录音。更麻烦的是，长文本失败时它没有明确提示，只是安静地退回原文。表面没丢字，实际在最需要整理的时候没有工作。",
                "现在我的判断标准是：最终意图是否唯一、数字是否准确、语气是否仍像我，以及我是否需要再读第二遍，而不是模型改了多少。",
                "短句也不能机械处理。“行行行，我知道了”里的三个“行”可能承载态度；“我我今天到”里的重复则只是口吃。真正困难的是判断重复是在卡顿，还是在强调。",
                "上下文可以帮助纠正产品名、人名和代码名，但不能带入旁边的私人内容。语音润色更像写作整理：忠实收口，不增加观点，也不把我的话改成客服模板。",
                "会议口述需要区分已经决定和仍待确认的问题，不能为了整齐全部列成同一层级。真实任务适合列点，个人经历则应保留叙述节奏，不自动添加报告式标题。",
                "用户不应在说话前选择快速或深度，复杂度由产品内部承担。失败时应明确区分超时、截断和校验失败，并让用户主动决定是否取回原文。",
                "成稿还应保留说话者本人的直接程度，不自动添加客服寒暄，也不把随手笔记改成项目汇报。可以删除口头残片，但不得补写没有说出的结论、承诺、理由或数据。",
                "只有长文、短句和上下文都稳定可靠，我才会放心把它用于每天的沟通。现在还没到这个程度，但方向终于清楚了。",
            ],
            required=["Dal", "直接发送", "改口", "周三", "周五", "四分钟", "退回原文", "最终意图", "数字", "语气", "行行行", "我我今天到", "上下文", "产品名", "人名", "代码名", "写作整理", "客服模板"],
            forbidden=["缪斯"],
            min_paragraphs=6,
            context=context_fixture(
                "recent_safe", "metadataOnly", "safe",
                recent=["Dal 的长语音测试刚刚结束。"],
            ),
        ),
    ]


def natural_ultra_long_cases() -> list[dict]:
    product_segments = [
        "这次我想把语音输入产品从录音开始到文字真正进入应用的全过程复盘一遍，不是为了写一份漂亮总结，而是要把哪些地方已经可靠、哪些地方只是看起来能用说清楚。最初的目标很简单：按下快捷键说话，松开以后文字进入当前输入框，用户不用理解背后的识别模型和润色路由。",
        "录音启动这一段目前相对稳定。按键后提示音和 HUD 都能出现，麦克风权限缺失时也会引导用户处理。但我们发现第一次启动和已经运行过很多次的状态不同，所以测试不能只看熟练路径，还要覆盖首次授权、拒绝后重试、切换麦克风和休眠唤醒后的第一段录音。",
        "流式字幕给人的速度感很好，可它不是最终事实来源。网络短暂中断时字幕可能停住，停止录音后还要等待终包。之前有个问题是终包已经回来，界面仍拿流式片段去拼，导致句子重复。现在要明确：流式只做预览，最终成稿必须基于终包和有序 segment，不能把两个来源简单相加。",
        "本地识别服务也有两条路线，一条是 SenseVoice，一条是 Qwen3 ASR。它们都只绑定 127.0.0.1，这个安全边界不能改。服务启动失败时应该说明是哪一个模型没准备好，而不是统一显示网络错误。模型下载、端口占用和 Python 环境异常要分别记录，方便用户判断是等待还是处理。",
        "术语纠正以前分散在热词、片段和个人词库里，用户很难知道哪个覆盖哪个。现在的原则是统一到同一套术语仓库，明确标准写法、别名、作用域和来源。确定性规则先改 canonical 文本，模型只能在这个基础上继续整理，不能把已经纠正的 Typeless、VoicePolishPipeline 或 WorkBuddy 又改回错误写法。",
        "上下文捕获必须坚持最小授权。普通输入框可以读取用户明确选中的文字或光标附近少量正文，密码框、安全字段和无法判断的控件一律只保留应用与场景元数据。同一应用近期由 Dal 自己输入的内容可以在内存里短期参考，但不跨应用、不落盘，也不能用来猜没有证据的人名。",
        "语音润色真正困难的是改口。即时改口可能是先说周三，不对，改周五；延迟改口可能隔了几段才说把前面预算改成一万六。两种情况都要只保留最终版本，同时保护没有被推翻的参与方、动作和限制。公开勘误是例外，因为读者需要同时知道错误值和正确值，不能套普通改口规则。",
        "重复也不能一刀切。我我我今天到属于口吃，今天今天下午开会通常是重新起步，这些应该清理。但真的真的很好和行行行我知道了可能承载强调或态度。证据不足时宁可保留，也不要为了文字看起来干净就把用户的情绪削平。短句尤其要克制，原本能发的句子只补必要标点。",
        "长文本之前最严重的问题是模型没有真正整理，系统却把原样输出当成功；另一种情况是结构校验或超时后静默回退。用户看到的都是一整段原文，很难判断发生了什么。现在必须把原样照抄视为质量失败，给长内容更合理的 token 和时间预算，并记录首稿、修复、超时、截断和最终回退原因。",
        "排版规则也要回到语义。真实枚举关系才列点，多主题叙述要自然分段，已经成形的短列表不要被重写成报告。列表声明的数量必须和实际项数一致，负责人、截止时间和动作要保持在同一项里。只统计关键词出现次数不够，因为词都在但关系串错，对用户仍然是错误。",
        "事实校验要保护数字、金额、日期、版本、路径、命令、邮箱、网址、专名和参与方。格式变化可以接受，例如一万六写成 16,000，但语义必须等价。代码场景更严格，斜杠、双横线和点号可以从口述恢复，动作动词却不能擅自变化；检查 codesign 不能改成执行 codesign 后顺便启动应用。",
        "失败恢复的目标不是永远不回退，而是回退必须可见、可诊断、可选择。用户按 Esc 主动使用原转写是正常出口，模型超时后系统被迫使用原文则是质量失败。历史记录里要区分成功、修复后成功、用户主动取回、模型超时、输出截断、事实校验失败和设置缺失，不能都写成润色完成。",
        "设置页的问题也需要收口。快速、标准、深度整理这些工程档位不应该让普通用户选择，用户只需要打开语音润色。内部可以根据内容做诊断，但生产路径必须是已经被真实 Provider 验证过的协议。路由、P50、P95 和校验码属于诊断信息，不应该成为用户日常决定。",
        "质量测试这次不能再用相似短句凑数量。长度要覆盖极短、日常消息、中等段落、五百字、一千五百字和三千字以上；内容要覆盖口吃、改口、乱序、上下文纠错、公开勘误、AI Prompt、代码、客服和自然叙述。长文既要有清单，也要有会议口述、邮件和个人经历。",
        "机器检查必须断言没有回退、没有超时、需要整理时输出不等于输入、必保事实存在、旧事实消失、上下文秘密不泄漏、列表和段落满足契约。机器仍然判断不了自然度和个人口吻，所以最终还要由未参与实现的独立 Agent 逐条看模型原始输出，给 direct send、minor edit、major edit 或 unusable。",
        "发布标准不能因为测试很多就放松。长文本要零回退、零 major 和零 unusable，事实、最终意图和实体错误都必须为零；基准和脏输入的直接发送比例要达到约定门槛。只要独立 Agent 没有明确通过，就不更新修复台账为完成，也不覆盖安装正式应用。",
        "文字进入目标应用的最后一步同样要测。直接注入失败时可以使用剪贴板，但必须在完成后恢复用户原来的剪贴板内容。焦点已经变化、目标控件消失或应用切换时不能把文字发到错误窗口，应该停止并显示可理解的提示。",
        "并发状态也容易制造假象。用户连续开始两次录音时，后一次会让前一次结果失效；旧任务即使晚回来也不能覆盖新文本。取消、超时和主动取回原文都要绑定 session ID，任何异步回调在写界面前先确认自己仍属于当前会话。",
        "日志必须能帮助定位但不能复制隐私正文。允许记录 route、字符数、segment 数、调用次数、耗时、校验码和失败阶段；不记录 API Key、完整 Prompt、选中文字、聊天内容或 Provider 原始响应。调试报告只有在用户显式运行质量测试时才保存模型输出。",
        "模型配置不能再有一个隐藏的专用快速模型让用户猜。语音润色使用当前文本处理 Provider，若有覆盖模型只作为高级兼容项并明确显示实际模型。配置缺失时直接提示设置问题，不要启动处理后再无声回退。",
        "打包与更新必须复用既有签名，发布前核对 Bundle ID、架构、版本号、严格签名和二进制 UUID。覆盖安装以后确认只有一个 Dal 进程，并用本次修复标识证明运行的是新候选。自动更新不能在用户录音中途替换应用。",
        "用户纠正结果是最有价值的质量信号，但学习要保守。只有用户明确选择原转写、手工修改成稿或确认术语时才记录对应样本；普通的复制、撤销或关闭窗口不能被解释成不喜欢某种风格。用户关闭个性化后既停止写入，也停止读取旧样本。",
        "性能压测除了单次延迟，还要看连续二十次短句、五次长文和网络抖动后的资源释放。请求结束后任务、计时器和临时上下文应及时清理，不能因为质量跑测连续调用而让后面的文本越来越慢。",
        "安装版还要做一次真正的端到端冒烟：录一条带改口的短句、一条超过一千字的自然叙述和一条包含安全上下文的专名纠错，确认最终文字进入当前输入框，历史记录与实际结果一致。源码里的 Runner 通过不能替代这一步。",
        "如果 Provider 临时不可用，界面应说明当前无法润色并保留原转写选择，不能把网络错误伪装成原文就是最佳成稿。恢复网络后的下一次请求要正常开始，不得被上一次失败状态持续污染。",
        "首次使用流程还要照顾完全不了解权限体系的人。麦克风、辅助功能和输入监控分别解释用途，用户拒绝其中一项时只禁用真正依赖它的能力，不能让整个应用失去响应。重新授权后应自动刷新状态，不要求用户反复退出；如果系统仍未生效，再明确提示重启哪一个进程。",
        "设备切换需要单独验证。用户从内置麦克风换到蓝牙耳机时，正在进行的录音不能悄悄丢失；采样率变化、耳机短暂断开和系统自动切回默认输入都要留下可判断的状态。若音频已经不足以继续识别，就结束当前会话并说明原因，不拼接两段来源不明的声音。",
        "离线与弱网不是同一种状态。本地识别成功但云端润色不可用时，可以展示可靠原转写并让用户选择稍后重试；本地模型本身没准备好时则不能假装已经开始录音。网络恢复只影响新的润色请求，旧请求是否重试必须由会话状态决定，不能把同一段文字重复注入两次。",
        "语言混合样本要覆盖中文句子里的英文产品名、命令、邮箱和缩写。模型可以调整中英文空格，却不能把 API、ASR、LLM 这类缩写翻译成另一个概念。人名或品牌读音相近但证据不足时保持原写法；只有个人词库或安全上下文给出唯一候选时才做纠正，并保留候选来源用于诊断。",
        "段落结构要接受识别服务不同的切分方式。同一篇口述有时只返回一个大 segment，有时每个停顿都会形成 segment，但最终排版不应该因此从自然叙述变成整篇清单。局部出现三项检查只约束那个局部，前后的背景、解释和结论仍按语义分段；这类单 segment 长文必须进入回归集。",
        "窗口切换是注入阶段的高风险点。录音开始在邮件里，处理期间用户切到聊天窗口，结果回来时不能凭旧焦点直接粘贴。系统要重新确认目标控件和会话归属；确认失败就把成稿留在可复制状态。剪贴板兜底前后都要核对 change count，避免覆盖用户刚刚复制的新内容。",
        "历史记录的可见信息应足够复盘，但默认不保存授权上下文正文。可以保存最终文本、原转写、时间、场景、结果状态和脱敏诊断，安全字段、选中文字与附近聊天只在当次请求内使用。用户删除一条记录时同步清除对应学习样本的引用，避免界面看似删除、后台仍继续使用。",
        "无障碍验收要由真实键盘路径完成：开始和停止录音、取消、取回原文、复制成稿、打开错误详情都应有清楚焦点顺序。VoiceOver 读出的处理中状态不能每次刷新都打断用户；颜色只作辅助，成功、警告和失败还要有图标与文字。提示音关闭后不能影响视觉状态。",
        "升级与回滚也属于可靠性。新版本读取旧设置时把历史质量档位迁移成 automatic，但保留用户的开关、快捷键和术语；迁移失败不得清空整个配置。若新版本启动即崩溃，回到上一版本后仍能读取兼容数据。数据库或文件格式变化必须先复制并提供版本标记。",
        "正式发布前安排一次持续使用观察，不只在干净环境跑脚本。测试者连续工作半天，穿插短消息、会议口述、代码命令和长复盘，记录是否出现越来越慢、焦点漂移、重复注入或历史状态错乱。期间主动取消几次、切换网络和麦克风，确认下一次会话仍从干净状态开始。",
        "质量报告还要显示失败分布而不是只给总通过率。短句口吃、上下文实体、跨段改口、长文截断和结构错配分别统计；同一输入经过修复才成功也要单独计数。这样才能知道问题是真的消失，还是被第二次调用暂时遮住，并为下一轮回归保留原始失败样本。",
        "最终交付说明面向普通用户，只写一个语音润色模式能解决什么、遇到失败怎样取回原文，以及上下文何时会被使用。内部 Fast 路径、校验器和 token 预算放在诊断文档，不塞进设置页。所有说明都以安装版实测结果为准，不能把计划中的能力提前写成已经支持。",
        "观测指标必须有一致分母。一次录音从终包到达开始计润色耗时，用户主动取消不算模型失败，但模型已经发出请求后被新会话替代要记为过期结果。P50、P95、回退率和修复率分别按短句、普通消息、长文统计，并保留 Provider、模型与版本，不能把不同配置混成一个看似漂亮的平均值。",
        "应用异常退出后的恢复要克制。尚未完成的录音可以提示存在临时内容，但不能自动重新发送到 Provider；已经生成却未注入的成稿可以留在历史里供复制，并明确标记未送达。重启后快捷键、HUD、音频设备和当前会话都从干净状态建立，不能延续一个实际上已经失效的处理中动画。",
        "个性化数据需要可解释。术语列表显示标准写法、别名、来源和最近使用时间，用户可以逐条停用或删除；表达偏好只显示由哪些明确修改得出，不展示或保存第三方输入框的完整上下文。导出文件默认脱敏，清空操作同时清理词典、派生画像和待确认候选，并在界面上说明影响范围。",
        "跨语言口述还要检查标点方向与字符归一化。中文里夹英文缩写时保留官方大小写，邮箱和网址不插入全角符号，版本号 2.0.0 不能变成日期。日文或韩文片段没有启用对应模型时保持识别结果并提示能力边界，不让润色模型自作主张翻译成中文。",
        "质量资产本身也要版本化。每条测试保存来源类型、输入因素、场景、长度、上下文级别、参考成稿和机器断言，修改断言时记录原因。候选报告必须绑定数据集名称、schema、Prompt 版本、commit、Provider 和模型；任何字段不一致都拒绝验收，旧报告不能冒充新构建结果。",
        "通知策略要避免重复打扰。一次会话只播报一个最终结果，HUD、菜单栏和历史记录使用同一状态来源；修复重试发生在内部时不连续弹两次成功。用户正在全屏演示或关闭提示音时仍保留可发现的文字状态，但不强制抢焦点。失败通知包含下一步选择，不只显示一个无法理解的错误码。",
        "数据导出要保证可迁移而不是制造新的锁定。历史文字、术语和明确学习样本使用有版本的通用格式，时间采用带时区的标准值，文本保持 UTF-8。导入前先校验 schema、重复项和冲突，不覆盖现有自定义规则；旧版本不认识的新字段可以忽略，但不能因此丢掉原始正文或标准写法。",
        "日期与时间显示遵循用户地区，但内部保存统一时区。今天、明天这类相对日期只在上下文明确时整理，不能离开录音时间擅自换成绝对日期；跨时区会议同时保留地点和时区。金额格式可以本地化，币种和数值必须保持原意，不能因为千位分隔符不同触发事实误判。",
        "输入法与组合文字也要纳入验证。用户正在输入中文候选词时，Dal 不能抢走尚未提交的组合状态；语音结果回来后只替换本次会话对应的范围。遇到表格单元格、邮件主题和富文本编辑器，还要确认换行、撤销与粘贴样式符合目标控件的真实行为。",
        "长时间运行需要观察内存、句柄和后台任务。每次录音结束后释放音频缓冲、网络流和临时文件，质量跑测结束后也不能留下隐藏窗口或重复状态项。连续失败不应指数累积通知；达到限流时明确显示等待原因，并保证用户下一段本地转写仍可使用。",
        "诊断导出必须经过用户主动确认，并在保存前列出包含的字段。报告可以带时间线、错误码、模型标识和脱敏长度统计，但不得夹带完整聊天、选中文本或钥匙串内容。技术支持收到报告后也只能据此定位，不能要求用户关闭系统安全保护来换取一次成功。",
        "最后还要验证卸载与重新安装边界。删除应用本体不能误删用户主动保留的历史，选择清空数据时则要列出词典、学习样本、缓存和日志的范围。重新安装后权限状态以系统实际结果为准，不伪造已授权；旧数据迁移失败时先保留原文件并给出恢复路径。",
        "多显示器和全屏场景也不能忽略。HUD 应出现在当前工作的屏幕，不遮挡正在输入的位置；切换空间后旧提示及时消失。录音结果回到应用前再次核对窗口、控件和会话，无法确认时保留可复制文本并说明原因，绝不能凭上一次焦点把长文送进错误对话。",
    ]
    product_reference = [
        "本次复盘覆盖从录音启动到文字进入当前应用的完整链路，目标是区分真正可靠的能力与仅在表面上可用的能力。用户应只需按快捷键说话并得到可直接使用的文字，无需理解识别模型或润色路由；提示音与 HUD 需如实显示当前状态。",
        "录音与识别：测试需覆盖首次授权、拒绝后重试、切换麦克风和休眠唤醒。本地识别有两条路线，一条是 SenseVoice，另一条是 Qwen3 ASR，均只绑定 127.0.0.1。流式字幕仅用于预览，最终成稿必须以终包和有序 segment 为准；启动失败需区分模型下载、端口占用和 Python 环境问题。",
        "术语与上下文：统一管理个人词库中的标准写法、别名、作用域和来源，确定性纠正后的 canonical 文本不得被模型改回，Typeless、VoicePolishPipeline 和 WorkBuddy 等名称保持标准写法。普通输入框只读取用户授权的选中文字或少量附近正文；密码框、安全字段和未知控件仅保留元数据。近期 Dal 输入只在同一应用内短期使用，不跨应用、不落盘。",
        "成稿规则：即时和延迟改口均只保留最终版本，公开勘误例外；“我我我今天到”一类口吃和重新起步应清理，“真的真的很好”和“行行行，我知道了”这类有意强调或连续回应应保留。短句只做必要修改。长文本不得将原样照抄判为成功，也不得在超时或结构失败后静默回退；token 与时间预算需覆盖完整成稿。",
        "排版与事实：真实枚举才列点，多主题叙述自然分段。列表项中的主题、负责人、截止时间和动作必须保持关联。数字、金额、日期、版本、路径、命令、邮箱、网址、专名和参与方均受保护；例如一万六可以写成 16,000，但语义必须相同。代码符号可按口述恢复，动作含义不得变化，检查 codesign 不能改成执行。",
        "失败与设置：用户按 Esc 主动取回原转写与系统被迫回退必须分开记录。历史状态应区分成功、修复后成功、主动取回、超时、截断、事实校验失败和设置缺失。用户侧只保留一个语音润色入口；性能分别记录 P50 和 P95，路由与指标留在诊断层。",
        "验收与发布：长文覆盖约 500、1,500 和 3,000 字，并测试多种噪声、场景、AI Prompt 和自然叙述。机器检查回退、超时、必要改写、事实、旧改口、上下文泄漏及排版；独立 Agent 逐条评价 direct_send、minor_edit、major_edit 和 unusable。长文必须零回退、零 major、零 unusable，事实、意图和实体错误为零。独立 Agent 未明确通过前，不销账、不覆盖安装。",
        "注入与并发：直接注入失败时可以临时使用剪贴板，但需恢复用户原内容；焦点变化时不得向错误窗口输入。所有异步结果绑定 session ID，旧任务不得覆盖新会话，取消、超时和主动取回均需确认当前会话。",
        "日志与模型：普通日志只记录路由、规模、耗时、校验码和失败阶段，不记录正文、Prompt、选中文字、API Key 或 Provider 原始响应。语音润色复用当前文本处理 Provider；缺少配置时明确提示，不静默回退。",
        "交付与学习：打包复用既有签名并核验 Bundle ID、架构、版本、严格签名、UUID 和单一进程。只有明确纠正、手工修改或术语确认才进入学习；关闭个性化后停止读写。性能压测包含连续 20 次短句、5 次长文和网络抖动，并检查任务与临时上下文释放。",
        "安装版需端到端验证一条改口短句、一条超过 1,000 字的自然叙述和一条安全上下文专名纠错，并核对历史记录。Provider 不可用时明确提示并保留原转写选择；网络恢复后的下一次请求不得继承失败状态。",
        "权限与设备：分别说明麦克风、辅助功能和输入监控用途，拒绝权限时只限制相关能力，重新授权后刷新状态。切换内置麦克风与蓝牙耳机时保护当前会话；采样率变化或音频中断无法恢复时明确结束，不能拼接来源不明的音频。",
        "离线与并发：本地识别成功而云端润色不可用时展示可靠原转写并允许稍后重试；本地模型未准备好时不得假装录音已开始。网络恢复不自动重复注入旧结果，同一段文字只能由当前 session 写入一次。",
        "混合语言与上下文：保留 API、ASR、LLM、邮箱、命令及产品名含义，只调整必要空格。个人词库或安全上下文存在唯一候选时才纠正实体，并记录候选来源；证据不足则保留原写法。",
        "结构一致性：Provider 返回一个或多个 segment 时，同一正文必须得到一致布局。局部三项检查不能把整篇自然叙述升级为列表，单 segment 长文必须纳入回归。",
        "注入与历史：结果回来前若焦点变化，重新确认目标控件；失败时保留可复制成稿。剪贴板兜底核对 change count。历史默认不保存授权上下文正文；删除记录时同步解除学习样本引用。",
        "无障碍与升级：真实键盘路径覆盖录音、取消、取回、复制和错误详情；VoiceOver 状态稳定，颜色之外提供图标与文字。旧质量档位迁移为 automatic，同时保留快捷键和术语，迁移失败不得清空配置。",
        "持续观察与报告：测试者连续半天混用短消息、长复盘和代码命令，并穿插取消、网络与麦克风切换。报告按口吃、上下文实体、跨段改口、截断和结构错配展示失败分布，修复后成功单独计数。",
        "用户说明：设置页只呈现一个语音润色模式、失败时取回原文的方法和上下文使用边界。Fast、校验器及 token 预算只进入诊断文档，所有公开能力以安装版实测为准。",
        "指标口径：从终包到达开始计时，主动取消与模型失败分开；过期结果单独记录。短句、普通消息和长文分别统计 P50、P95、回退与修复率，并绑定 Provider、模型和版本。",
        "恢复与个性化：崩溃后不自动重发未完成录音，未注入成稿标记为未送达并可复制。术语展示标准写法、别名、来源和最近使用时间；表达偏好只来自明确修改。导出默认脱敏，清空同步移除派生画像和候选。",
        "跨语言与质量资产：保留官方大小写、邮箱、网址和 2.0.0 等版本格式，未支持语言不自动翻译。测试报告绑定数据集、schema、Prompt、commit、Provider 与模型，任一身份字段不一致即拒绝验收。",
        "通知与迁移：同一会话只播报一个最终状态，HUD、菜单栏与历史共用状态来源，失败通知提供下一步。历史、术语和学习样本按带版本的 UTF-8 通用格式导出，导入先校验 schema、重复与冲突，不覆盖现有自定义规则。",
        "本地化：内部时间统一时区，界面按地区显示；相对日期仅在上下文明确时转换，跨时区会议保留地点与时区。金额可调整分隔符，但币种与数值含义不得变化。",
    ]
    course_segments = [
        "这次课程计划我想从学员真正完成一项工作来倒推，不按工具品牌堆章节。目标学员是已经会基本电脑操作，但没有稳定使用 AI 的普通职场人和个体创作者。课程结束时，他们应该能独立完成一次资料研究、一篇可发布文案和一个简单的自动化流程。",
        "开篇先讲边界，不承诺学完就能靠 AI 自动赚钱，也不把任何模型说成永久最好。要解释生成结果可能出错、账号和价格会变化、敏感信息不能直接交给第三方。这个安全章节不能放到最后当免责声明，而要在第一次真实操作前出现。",
        "第一部分是账号与环境。Windows 和 macOS 分开演示安装，移动端只讲能做什么和不能做什么。截图必须来自当前版本，每一步都标注点击位置。示例账号、邮箱、订单号和验证码全部使用假数据，API Key 只显示首尾少量字符。",
        "第二部分讲如何提出好问题，不从抽象公式开始，而是拿一个真实需求逐步补齐目标、背景、限制和输出格式。学员要看到同一个任务从模糊到可执行的变化，也要知道什么时候应该停下来补资料，而不是继续让模型猜。",
        "第三部分是资料研究。先教如何找到官方来源，再讲怎么处理媒体文章和社区经验。引用要保留链接、发布日期和访问日期，遇到冲突不能偷偷选一个看起来合理的答案。研究结论必须区分已确认、合理推断和仍待实测。",
        "第四部分进入语音输入和文字整理。原来想把它放在第七章，我改一下，最终放在第四章，因为很多学员打字慢，先解决输入效率，后面写文案和做研究都会受益。这里要演示口吃、改口、长文本、上下文纠错和原文回退。",
        "第五部分做内容生产。先从用户自己的经历提炼观点，再安排开头、例子和收束。不能把个人表达统一改成营销腔，也不能为了平台效果编造数据。图片与视频只服务解释，B-roll 第一次出现时要用中文说明它就是辅助讲解的补充画面。",
        "第六部分讲表格和文档。表格任务从清洗字段、检查缺失值开始，再做指标和图表；文档任务强调保留原始内容、先复制再大改、每次只改授权范围。幻灯片要先有清晰结构，再决定视觉，不用大量装饰掩盖信息不足。",
        "第七部分是知识库。示例使用 Obsidian，但原则适用于其他工具：一个笔记聚焦一个核心主题，重要概念建立双向链接，零散灵感先按 idea 保存，不要未经确认就扩成完整策略。文件命名使用日期和描述，不叫最终版二。",
        "第八部分是自动化和 Agent。先从低风险的本地整理开始，再到需要浏览器和外部账号的流程。发送、发布、删除、付费、权限变更和生产环境都必须设置人工确认点。学生要理解自动化成功不等于结果正确，还要验证普通用户路径。",
        "作业设计不能只让学员照着点。每一章有一个小任务，最后把研究、文案、表格和自动化串成综合项目。参考答案说明成功标准和常见错误，但允许不同实现。助教评分先看事实与边界，再看表达和效率。",
        "录制原计划在九月三日全部完成，这个时间不现实，不对，最终改成九月十日完成主课录制；九月十二日完成字幕和截图复核；九月十五日只开放给内部学员试看，不是正式公开发布。旧日期不要出现在最终计划里。",
        "制作分工也要清楚。我负责课程结构和口播终稿，小林负责事实核查，小陈负责真实截图与标注，设计组负责章节封面，剪辑组负责画面和字幕，助教组负责作业试做与常见问题。任何人遇到阻塞都写真实原因，不默认别人会补。",
        "每个教程都要有真实截图，这是硬要求。截图前先确认安装版本，操作前留一张起始状态，操作后留成功结果；图片上的箭头和框只标关键位置。涉及购买、实名、登录密码或验证码时停下来由操作者本人完成。",
        "口播和字幕完成后做两轮检查。第一轮逐句核对事实、数字、路径和命令，第二轮站在零基础学员角度完整走一遍。只看文字顺不顺不够，示例文件要真的能打开，链接要能访问，普通浏览器路径要能完成。",
        "发布页只说明已经验证的能力、适合对象、学习前提和课程边界，不使用轻松月入或零门槛变现。购买须知写清更新方式和售后范围，内容授权说明哪些素材可以个人使用、哪些不能二次销售。",
        "最终验收由没有参与制作的人执行。他要按章节随机抽查截图、命令、链接和作业，也要完整走一次综合项目。出现关键事实错误、隐私泄漏或无法复现的步骤就直接不通过，不能用大多数章节没问题来抵消。",
        "这份计划最后请整理成目标、章节结构、制作排期、角色分工、素材规则、质量检查和发布边界几个部分。不要压成十几行摘要，也不要把我中间解释为什么改顺序的过程原样留下，只保留最终决定及必要理由。",
        "直播答疑不是主课的替代品。每次直播前从作业和群问题里归纳主题，直播中演示可公开的通用案例，涉及学员公司数据时改用脱敏样本。直播录像在四十八小时内上传，问题索引同步到对应章节。",
        "课程社区也要有运营规则。鼓励学员分享不同做法，但禁止公开 API Key、客户数据和付费素材。助教回答先引用课程位置，再补充针对性建议；遇到产品价格或规则变化时不要凭记忆回答，先查官方来源。",
        "无障碍和可读性不能到发布前才补。截图标注要有足够对比度，重要操作不能只靠颜色区分；字幕与口播同步，命令和路径使用等宽样式。视频里快速闪过的设置要在文档中提供文字步骤。",
        "素材备份分三层：原始录屏和音频只读保存，项目文件每天增量备份，最终导出按章节和版本归档。替换音频或截图前先复制，不能直接覆盖唯一源文件；外部硬盘和云盘至少保留一个离线副本。",
        "版权检查单独走一遍。自制截图确认不含真实用户信息，第三方图片记录授权页面，音乐保留许可凭证，引用文字控制在必要范围并标明来源。学员提交的优秀作业要获得明确授权后才能放进后续宣传。",
        "课程版本使用主版本点次版本，例如 1.0 和 1.1。小的界面变化更新图文说明，流程或能力边界改变才重录视频。每次更新写明受影响章节、更新时间和旧版学员是否需要重新学习。",
        "结课标准不能只看视频播放完成。学员需要提交综合项目、来源记录和自查清单，证明结果可复现且没有泄露敏感信息。没有通过的学员可以按反馈修改一次，助教只指出问题，不代替完成作品。",
        "为了避免课程只在制作团队电脑上可用，发布前请找一台从未安装相关软件的 Windows 设备和一台全新 macOS 账户重新走流程。任何依赖旧缓存、已有登录或隐含权限的步骤都要补进教程。",
        "正式上线当天不要同时更换全部素材和支付页面。先冻结课程包，核对下载链接、试看权限、购买流程和售后入口，再逐步开放。涉及真实付款由负责人手动完成，自动化只检查不提交订单。",
        "上线后一周做第一次复盘，分别看完课率、作业提交率、最常卡住的章节和售后问题，但不把这些数字直接解释为教学质量。结合学员访谈判断原因，再决定是重录、补文档还是调整作业。",
        "课程页面还要提供可搜索的文字目录和每节时长，学员能直接跳到需要复习的位置。章节标题使用任务语言，不写第一讲第二讲这种只有顺序没有信息的名称。",
        "下载素材按章节分文件夹，文件名包含日期和用途，避免素材一、最终版二。压缩包解压后不依赖制作者电脑上的绝对路径，Windows 和 macOS 都能打开。",
        "如果产品界面在录制后变化，先判断是否影响任务路径。只改颜色和图标时更新截图说明即可；按钮位置、权限流程或能力边界变化时才安排重录，避免无意义地追逐每次小改版。",
        "课程数据只用于改进教学，公开案例前做聚合和脱敏。学员要求删除作业或群内内容时按约定处理，不把课程社区当作可以永久保存的素材库。",
        "最后为每个章节指定维护人和复查日期，不能上线后就没人负责。发现链接失效、价格变化或步骤不再可复现时先标记影响范围，再决定补充说明还是重录。",
        "正式录制前安排一次讲师彩排。彩排不只计时，还要记录哪些地方需要临时找文件、切窗口或等待下载；这些停顿说明教程路径还不够完整。每节开头先展示最终要完成的结果，结尾用同一个样本核对是否达成，避免学员学完一堆按钮却不知道产物应该是什么样。",
        "课程里的示例项目要贯穿始终。研究章节收集的来源继续用于文案，文案中的数据再进入表格和幻灯片，自动化章节最后把这些资产整理归档。每一章都提供上一章的标准起点，学员中途加入时可以继续，不必因为早期一步失败就重做全部内容。",
        "练习数据分为公开样本和个人替换模板。公开样本要小而完整，能够在十分钟内下载，字段说明和许可一并提供；个人模板明确哪些位置可以换成自己的公司或客户资料。任何需要真实业务数据的练习都先教脱敏，不鼓励把完整合同、通讯录或销售明细上传。",
        "助教值班需要统一处理边界。账号登录、产品 Bug、课程理解和个性化咨询分别标记，能引用官方帮助的先给来源，无法复现的问题收集系统版本、步骤和脱敏截图。助教不能索要密码或远程控制验证码，也不能为了尽快结单替学员直接完成作业。",
        "每周答疑前先发布问题清单，让学员知道哪些会在直播演示、哪些只在文档补充。直播过程中如果产品界面和课程截图不同，先说明版本差异再操作，不把临时探索包装成标准流程。演示失败也保留真实排查过程，但整理后的章节只留下确认可复现的步骤。",
        "学习节奏要给出建议而不是强制。普通职场人可以每周完成两个章节，创作者也可以按研究、内容、自动化三个任务路径选择。每个路径都标明前置知识、预计时间和完成产物；没有时间看完整视频的人可以先读文字步骤，再回到对应时间点查看演示。",
        "评分别只看成品好不好看。研究作业先看来源是否可追溯，文案先看事实和个人表达，表格先看字段和计算，自动化先看人工确认点与异常处理。统一量表分为可直接使用、少量修改、重大修改和不可用，评分人必须写出具体证据，不能只留一个分数。",
        "同伴互评只开放经过脱敏的内容。学员提交时勾选是否愿意公开，默认仅讲师和助教可见；同意公开也只代表用于本期学习，不自动获得后续宣传授权。评论规则要求针对任务与证据，不评价个人能力，争议案例由助教及时隐藏并复核。",
        "课程要兼顾听觉和视觉障碍。所有视频提供准确字幕与文字稿，截图箭头之外还写出菜单和按钮名称，颜色差异附文字说明。快捷键演示同时说明菜单路径，无法使用鼠标或听不到提示音的学员仍能完成任务；文档结构使用真实标题层级，方便屏幕阅读器导航。",
        "多语言材料只在确有需求时制作。中文主课中的英文界面保留原按钮名并补中文解释，不自行翻译产品名；英文帮助文档的关键结论给中文摘要和原链接。未来若制作英文版，应重新录制与校对，不把机器翻译字幕直接当正式课程。",
        "课程版本更新建立影响矩阵。价格变化只更新价格页与相关字幕，权限流程变化影响安装和自动化章节，模型能力变化还要重跑示例。每次更新先列受影响的课程、作业、参考答案和下载素材，再决定局部修订或整体重录，避免只改视频却留下旧文档。",
        "售后入口要让学员容易找到，但不能承诺无限支持。常见问题按安装、账号、模型、文件和作业分类，先提供自助排查，再提交工单。工单回复说明预计下一次进展时间，而不是随口承诺解决日期；属于第三方服务的问题明确边界，并持续更新已确认状态。",
        "支付和退款说明使用当前实际规则，展示前由负责人核对平台页面。优惠、名额和截止日期必须有真实依据，不能用永久倒计时制造紧迫。用户到付款、实名或签署协议步骤时，教程停在确认页，由本人操作；录屏不得捕获银行卡、身份证或真实订单信息。",
        "市场宣传与课程内容采用同一份能力清单。宣传案例必须能在课程提供的环境里复现，不能拿内部高级配置的效果代表零基础默认体验。学员评价需要获得单独授权并保留原意，不能截取半句话改变态度；没有验证的未来章节只写计划，不写即将上线的确定日期。",
        "开课第一周安排轻量诊断问卷，了解设备、系统、已有工具和目标任务，但不收集公司机密。问卷只用于推荐学习路径，不把新手自动判断为低能力。学员可以跳过问题并手动选择路径，之后也能随时切换，不因第一次选择锁定全部内容。",
        "学习数据仪表盘只使用完成进度、作业提交和自愿反馈。播放次数、停留时间和点击率只能提示可能的卡点，不能直接判断学员认真程度。分析结果按群体汇总，老师查看具体作业时遵循最小权限；导出报表前再次移除姓名、邮箱和自由文本中的敏感信息。",
        "遇到大范围产品故障时启用课程事件说明。先标明受影响章节和临时替代路径，确认原因后再更新教程；如果没有安全替代方案，就暂停相关作业截止时间。事件结束后记录发生日期、恢复时间、修订内容和仍需观察的问题，不悄悄替换文件让学员猜变化。",
        "讲师和助教离开团队时要完成交接。账号权限、素材位置、维护章节、未解决工单和下一次复查日期都有明确接收人；离职账号及时撤销，不共享个人密码。课程源文件至少两人知道恢复方法，但编辑权限只给当前负责人，避免没人能维护或所有人都能覆盖。",
        "年度复盘不以新增章节数量作为成绩。重点检查学员是否真正完成目标任务、哪些流程因产品变化失效、哪些内容重复或可以归档。对已经不再推荐的工具说明原因并保留迁移路径；删除整章前先通知受影响学员，旧版资料按约定时间提供下载。",
        "不同期开班不能直接复制上一期日历。先核对节假日、讲师时间、产品版本和作业工作量，再确定直播与截止日期。人数超过助教容量时先增加支持资源或拆班，不通过压缩答疑时间解决。每期保留独立班级空间，旧学员资料只读归档，避免新通知覆盖历史记录。",
        "入学前提供环境自检页，检查操作系统版本、磁盘空间、浏览器、网络和必要账号，但不要求安装所有工具。检查失败时给出可执行的替代路径，例如先使用网页版本或下载离线素材；确实无法满足前提的课程要在购买前说清，不能付款后才发现设备不支持。",
        "云端模型费用要用可控样本演示。课程说明哪些请求可能计费、如何查看余额和设置限额，不提供共享 API Key。练习默认使用短输入，长文和批量任务先估算成本再执行；价格页面变化时及时更新截图和文字，不引用旧视频里的金额继续做承诺。",
        "社区内容定期整理但不随意删除。高频问题沉淀到 FAQ，已经过时的回答标注适用版本，重复讨论可以合并链接。涉及人身攻击、广告或隐私泄漏的内容先隐藏并保留处理记录；普通不同意见不得因为和讲师结论不一致就删除，课程也要允许学员提出反例。",
        "讲师培训包含一次完整的零基础试讲。旁听者只能按课程提供的信息操作，讲师不能用未写进教材的经验替他补步骤。试讲结束记录误解点、术语门槛和等待时间，优先改材料再训练讲师口头补充，避免课程只能依赖某个人现场救场。",
        "可访问性还要在发布包上实测，而不是只检查稿件。使用 VoiceOver 顺序读一节文档，放大到百分之二百检查截图标注，关闭声音完成视频任务，并用纯键盘提交作业。发现问题要记录受影响章节、临时方案和修复日期，不能只在声明里写支持无障碍。",
        "课程源文件恢复演练每季度做一次。从只读原始素材、项目备份和最终导出各抽一个章节，确认能在另一台电脑打开，字体、链接和媒体没有丢失。云盘同步不是唯一备份，误删除和勒索风险需要离线副本；恢复步骤写入教师手册并指定负责人。",
        "结课证书只证明完成约定任务，不宣称职业资质。发证前核对综合项目、来源记录和安全自查都已通过，姓名由学员本人确认。证书编号和验证页只展示必要信息，撤回或更正有清晰流程，不能为了营销给未提交作业的人自动发证。",
        "结课问卷同时收集最有帮助、最难理解和仍未解决的问题，并允许匿名。满意度只作为一个信号，要和作业表现、工单及访谈一起解释。负面反馈原样保留核心意思，不挑选好看的句子做总结；需要联系回访时由学员主动留下方式。",
        "下一阶段路线图先写问题和证据，再写候选方案。是否新增模型、移动端或高级自动化，要看现有学员任务是否被阻塞，而不是追逐新功能。每个候选项标明负责人、验证方法和决定日期，未通过验证就保持计划状态，不进入宣传页面或销售承诺。",
        "工具选择保持厂商中立。课程可以用当前产品演示，但每个关键能力都解释输入、输出和判断标准，学员以后换工具仍能迁移。涉及赞助、分成或合作关系时在对应章节明确披露，评价不因为商业关系改变；没有完整比较过的产品不做最好或最差的结论。",
        "离线学习包要包含文字稿、必要截图、练习数据和校验值，但不打包受限制的软件或付费素材。下载后在断网环境抽查能否打开，外部链接另存清单供联网时访问。更新包只提供变化文件和说明，学员不必每次重新下载全部视频，也能确认本地文件版本。",
        "讲师发布新章节前也走双人复核。一人核对事实、来源、数字和产品边界，另一人按学员路径执行全部步骤；作者不能独自批准自己的内容。紧急修正可以先发布醒目标记和临时步骤，但二十四小时内补齐复核记录，不能让临时说明永久悬空。",
        "跨时区班级的直播时间同时标明时区和本地日期，夏令时变化前重新确认。无法参加直播的学员通过录像、问题索引和异步答疑获得同等核心内容；作业截止按学员所在时区展示，并保留短暂宽限，不能让服务器时区差异造成误判逾期。",
        "结课后的校友更新只发送学员明确订阅的内容。重要安全变更或课程材料失效可以发一次服务通知，营销活动与学习更新分开退订。校友资源标明适用版本和最后复查日期，旧讨论区保持只读；需要重新购买的新产品不能伪装成原课程免费更新。",
        "课程还要讨论负责任使用。研究时不伪造来源，内容生产不冒充真实人物，自动化不绕过权限或平台规则，生成图片和声音说明授权边界。遇到可能影响就业、医疗、法律或财务的重要决定时，课程要求核对专业来源和人工复审，不把模型回答当最终判断。",
        "综合项目答辩重点让学员解释过程而不是做漂亮展示。每人用十分钟说明目标、来源、关键选择、失败处理和最终产物，再回答一个可复现问题。答辩可以录屏供本人复盘，但默认不公开；评分人若发现结果来自模板却无法解释，就要求补充过程证据，而不是只看表面完成度。",
        "下载资源设置生命周期。每个压缩包标创建日期、适用章节、版本和维护人，季度检查链接、格式和授权。被新资源替代的旧包先标归档并保留迁移说明，确认没有课程仍引用后再下线；学员本地文件不受远程删除影响，重要更新通过明确通知而不是悄悄替换同名文件。",
        "课程团队每月抽查一条完整学习路径，从购买前说明、环境自检、章节学习、作业提交到售后回复全部走完。抽查使用普通账号和新设备，不借助管理员权限。发现跨系统差异时记录真实截图和复现步骤，分配负责人和截止日期，下一次抽查先验证旧问题是否关闭。",
        "最后建立课程决策记录。章节增删、工具替换、价格调整、作业延期和规则变化都写明提出日期、证据、参与人、最终决定及复查时间；讨论中的临时方案标为未采纳，不能混进正式说明。决策记录和更新日志互相链接，学员只看到与学习相关的结果，团队仍能追溯为什么变化。若后来事实改变，就新增一条更正并指出受影响材料，不覆盖旧记录假装从未发生。",
        "教师手册最后附一页发布前停步清单：涉及真实付款、账号权限、外部发送、批量删除、公开发布或学员隐私时，自动流程必须停下等待负责人确认。清单同时写出取消后的恢复方式，确保操作者拒绝继续不会损坏素材、重复收费或留下半完成状态。",
        "课程上线后每季度做一次内容可用性抽样。抽样不只检查视频能播放，还要用普通学员账号重新下载素材、打开示例、提交作业并收到售后回复。任何依赖管理员权限或内部缓存才能完成的步骤都算失败，修复记录要注明影响章节、负责人和复查日期。",
        "企业学员与个人学员使用同一事实标准，但数据边界不同。企业案例只能使用已获授权并完成脱敏的材料，合同、通讯录、客户名称和内部指标不得进入公开课堂。需要团队协作时先说明角色权限，再演示共享，不能用讲师的全局管理员账号代替普通成员路径。",
        "每次大版本更新前保留一套旧版回归课件。新版截图、命令和下载包验证通过后再切换入口，旧版先进入只读归档并提供迁移说明。若新版发布后出现阻断问题，应能恢复旧入口，而不是临时删除学员已经依赖的资料或覆盖同名文件。",
        "最终运营复盘要把教学问题与产品故障分开统计。课程解释不清、作业设计过难、第三方服务中断和学员设备不兼容分别记录，不能用一个满意度数字掩盖原因。改进项必须写出证据、负责人、预期验证方式和决定日期，没有验证结果就继续保持待确认。",
    ]
    course_reference = [
        "课程目标：面向具备基本电脑操作能力、希望稳定使用 AI 的普通职场人和个体创作者。结课后，学员应能独立完成一次资料研究、一篇可发布文案和一个简单自动化流程。课程不承诺自动赚钱，不宣称任何模型永久最好，并在首次实操前说明错误、价格变化和敏感信息边界。",
        "章节结构：\n一、账号与环境。\n二、提出好问题。\n三、资料研究。\n四、语音输入与文字整理，覆盖口吃、改口、长文本、上下文纠错和原文回退。\n五、内容生产。\n六、表格与文档。\n七、知识库。\n八、自动化与 Agent。语音输入最终放在第四章。",
        "演示规范：Windows 与 macOS 分开，移动端说明能力边界。真实截图来自当前版本，操作前后分别保留状态并标注关键位置。示例账号、邮箱、订单号和验证码使用假数据，API Key 仅显示少量首尾字符；购买、实名、密码和验证码由操作者本人完成。",
        "内容规范：官方来源保留链接、发布日期和访问日期；冲突信息并列说明。研究结论区分已确认、合理推断和待实测。个人文案不改成营销腔，不编造数据；首次出现 B-roll 时说明它是辅助讲解的补充画面。",
        "知识与自动化：Obsidian 中一个笔记聚焦一个主题，重要概念建立双向链接，零散灵感按 idea 保存。自动化从低风险本地任务开始；发送、发布、删除、付费、权限和生产环境保留人工确认点，并验证普通用户路径。",
        "作业与分工：每章设置小任务，最终综合研究、文案、表格和自动化。参考答案给成功标准与常见错误，但允许不同实现。我负责课程结构和口播终稿，小林负责事实核查，小陈负责真实截图与标注，设计组负责章节封面，剪辑组负责画面与字幕，助教组负责作业试做与常见问题。",
        "制作排期：9 月 10 日完成主课录制，9 月 12 日完成字幕和截图复核，9 月 15 日仅向内部学员开放试看，并非正式公开发布。",
        "质量检查：先逐句核对事实、数字、路径和命令，再由零基础学员视角完整走查。示例文件、链接和普通浏览器路径必须真实可用。独立验收者随机抽查并完成综合项目；关键事实错误、隐私泄漏或步骤无法复现时直接不通过。",
        "发布边界：发布页只写已验证能力、适合对象、学习前提和课程边界，不使用“轻松月入”或“零门槛变现”。购买须知说明更新和售后范围，内容授权区分个人使用与禁止二次销售。",
        "直播与社区：直播主题来自作业和群问题，公开演示使用脱敏案例，录像 48 小时内上传并建立章节索引。社区禁止公开 API Key、客户数据和付费素材；价格或规则变化先核对官方来源。",
        "可访问性与备份：标注具备足够对比度，重要操作不只依赖颜色；字幕同步，命令与路径使用等宽样式，快速设置另附文字步骤。原始素材只读保存、项目每日增量备份、导出按版本归档，并保留离线副本。",
        "版权与版本：第三方图片、音乐和引用分别保留授权或来源；学员作业用于宣传前取得明确授权。课程使用 1.0、1.1 等版本号，更新记录受影响章节、日期和旧学员是否需重学。",
        "结课与上线：结课需提交综合项目、来源记录和自查清单，可按反馈修改一次。发布前在全新 Windows 设备和全新 macOS 账户走查。上线当天先冻结课程包并核对链接、试看、购买与售后；真实付款由负责人手动完成。上线一周后结合数据与访谈复盘，不用单一指标代替教学质量判断。",
        "学习体验：课程页提供可搜索目录和每节时长，标题描述具体任务。下载素材按章节、日期和用途命名，解压后不依赖绝对路径并兼容 Windows 和 macOS。界面小变化更新图文，流程或能力边界变化才重录。课程数据仅用于教学改进，公开前聚合脱敏，并按约定处理学员删除请求。",
        "维护责任：每章指定维护人与复查日期；链接、价格或步骤变化时先标明影响范围，再决定补充说明或重录。",
        "录制与示例：正式录制前完成讲师彩排，记录找文件、切窗口和下载等待等路径缺口。每节用同一样本展示目标与结果。示例项目贯穿研究、文案、表格、幻灯片和自动化，并为中途加入者提供标准起点。",
        "练习与助教：公开样本应能在十分钟内下载，并附字段说明和许可；个人模板先教脱敏。助教按登录、Bug、课程理解和咨询分类处理，只收集系统版本、步骤和脱敏截图，不索要密码、验证码，也不代做作业。",
        "答疑与节奏：直播前公布问题清单，界面差异先说明版本，失败演示只在确认可复现后写入教程。提供每周两个章节及研究、内容、自动化三条建议路径，标明前置知识、时间和完成产物。",
        "评估与互评：研究看来源，文案看事实与个人表达，表格看字段计算，自动化看确认点和异常。统一使用直接使用、少量修改、重大修改、不可用四档并写证据。互评默认不公开，单独授权后才展示，评论只针对任务。",
        "可访问性与语言：视频提供准确字幕和文字稿，截图同时写菜单与按钮名，快捷键附菜单路径，文档使用真实标题层级。英文界面保留原按钮名并补中文解释；英文版需重新录制校对，不直接使用机器翻译字幕。",
        "更新与售后：建立课程、作业、答案和素材的影响矩阵。常见问题按安装、账号、模型、文件和作业分类；工单说明下一次进展时间，不随意承诺解决日期，第三方问题明确边界。",
        "支付与宣传：付款、实名和协议步骤由本人操作，录屏不含银行卡、身份证或订单信息。优惠和截止日期必须真实；宣传与课程共用能力清单，案例可在默认环境复现，学员评价需单独授权。",
        "路径与数据：开课问卷只收集设备、系统和目标任务，不收集公司机密，可跳过或更换路径。仪表盘使用汇总进度、作业和自愿反馈，导出前移除姓名、邮箱和自由文本敏感信息。",
        "事件与交接：大范围故障标明受影响章节、临时路径和恢复时间，无安全替代时顺延作业。团队交接包含账号权限、素材、维护章节、工单和复查日期，离职账号及时撤销。年度复盘以任务完成和流程有效性为准，并为下线工具保留迁移路径。",
        "开班与环境：每期重新核对日历、讲师、版本和助教容量，人数超出时增加资源或拆班。购买前提供操作系统、磁盘、浏览器、网络和账号自检，并为可替代场景给出网页或离线路径；设备硬性不支持必须提前说明。",
        "费用与社区：云端请求说明计费、余额与限额，不共享 API Key；长文和批量任务先估算成本。社区高频问题进入 FAQ，旧答案标版本，隐私和攻击内容按规则处理，不因不同意见删除反例。",
        "教学与无障碍：讲师完成零基础试讲，材料补齐所有隐含步骤。发布包使用 VoiceOver、200% 放大、静音与纯键盘真实走查，问题记录章节、临时方案和修复日期。",
        "恢复与证书：每季度从原始素材、项目备份和导出中抽样恢复，保留离线副本并指定负责人。证书只证明完成约定任务，发证前核对项目、来源与安全自查，姓名、编号和更正流程使用最少必要信息。",
        "反馈与路线图：问卷收集帮助点、难点和未解决问题并允许匿名，满意度结合表现、工单与访谈解释。路线图从问题证据出发，候选项标负责人、验证方法和决定日期，未验证能力不进入宣传或销售承诺。",
        "中立与离线：关键能力解释输入、输出和判断标准，商业合作明确披露，未完整比较的产品不作极端结论。离线包只含可授权的文字、截图和练习数据，断网抽查可用性，更新包提供变化文件、版本和校验说明。",
        "复核与时区：新章节由事实复核者和学员路径执行者双人批准，紧急修正 24 小时内补记录。直播同时标时区与本地日期，录像、索引和异步答疑覆盖缺席者，截止时间按学员时区显示并设置合理宽限。",
        "校友与责任：学习更新与营销分别订阅，安全变更可发送一次服务通知，资源标适用版本与复查日期。课程要求不伪造来源、不冒充人物、不绕过权限；高影响医疗、法律、财务等决定必须核对专业来源并人工复审。",
        "答辩与资源：每人用十分钟说明综合项目的目标、来源、选择、失败处理和产物，默认不公开录屏，无法解释模板结果时补过程证据。下载包标日期、章节、版本与维护人，旧包归档并保留迁移说明，确认无引用后再下线。",
        "月度路径抽查：使用普通账号和新设备走完购买说明、环境自检、学习、提交和售后，不借助管理员权限。系统差异保留截图与复现步骤，指定负责人和截止日期，下次抽查优先验证旧问题。",
        "决策记录：章节、工具、价格、作业和规则变化写明日期、证据、参与人、最终决定与复查时间，未采纳方案不得进入正式说明。记录与更新日志互链；事实变化时新增更正并标出受影响材料，不覆盖历史。",
        "停步清单：真实付款、账号权限、外部发送、批量删除、公开发布和学员隐私操作必须等待负责人确认，并写明取消后的恢复方式，避免素材损坏、重复收费或半完成状态。",
    ]
    # 两条超长样本都把旧事实和最终改口放在预期的不同内部切片中；其中产品
    # 复盘还叠加安全近期上下文的 Dal 专名纠正。最终由 Swift 回归测试按
    # 实际 chunker 断言，避免只凭总长度声称覆盖了跨片改口。
    product_segments[10] += "质量修复重试次数先按三次记录。"
    product_segments[20] = product_segments[20].replace("Dal 进程", "缪斯进程")
    product_segments[23] = (
        "前面质量修复的重试次数我说错了，最终最多两次。" + product_segments[23]
    )
    course_segments[14] += "另外，课程资料复核先安排三轮。"
    course_segments[30] = (
        "前面的课程资料复核轮次不对，课程资料复核最终安排两轮。" + course_segments[30]
    )

    # 超长边界样本的参考成稿必须接近完整来源，不能再用摘要型参考文本。
    # 产品复盘原段落已经可直接发送，参考成稿只补自然段落；课程计划只清理
    # 两处明确改口和一段写法元指令，其余独立约束逐段保留。
    product_full_reference = list(product_segments)
    course_full_reference = list(course_segments)
    product_full_reference[10] = product_full_reference[10].replace(
        "质量修复重试次数先按三次记录。", ""
    )
    product_full_reference[20] = product_full_reference[20].replace("缪斯进程", "Dal 进程")
    product_full_reference[23] = product_full_reference[23].replace(
        "前面质量修复的重试次数我说错了，最终最多两次。",
        "质量修复重试次数最终最多两次。",
    )
    course_full_reference[14] = course_full_reference[14].replace(
        "另外，课程资料复核先安排三轮。", ""
    )
    course_full_reference[30] = course_full_reference[30].replace(
        "前面的课程资料复核轮次不对，课程资料复核最终安排两轮。",
        "课程资料复核最终安排两轮。",
    )
    course_full_reference[5] = (
        "第四部分进入语音输入和文字整理，并最终放在第四章。很多学员打字慢，"
        "先解决输入效率，后面写文案和做研究都会受益。这里要演示口吃、改口、"
        "长文本、上下文纠错和原文回退。"
    )
    course_full_reference[11] = (
        "九月十日完成主课录制，九月十二日完成字幕和截图复核，九月十五日只"
        "开放给内部学员试看，不是正式公开发布。"
    )
    course_full_reference[12] = (
        "制作分工：\n"
        "1. 我负责课程结构和口播终稿。\n"
        "2. 小林负责事实核查。\n"
        "3. 小陈负责真实截图与标注。\n"
        "4. 设计组负责章节封面。\n"
        "5. 剪辑组负责画面和字幕。\n"
        "6. 助教组负责作业试做与常见问题。\n"
        "任何人遇到阻塞都要写明真实原因，不能默认由别人补齐。"
    )
    course_full_reference = [
        block for index, block in enumerate(course_full_reference)
        if index != 17
    ]
    return [
        natural_long_case(
            case_id="natural-long-09",
            scene="document",
            title="超长自然产品全链路复盘",
            segments=product_segments,
            reference_blocks=product_full_reference,
            required=["快捷键", "流式字幕", "终包", "SenseVoice", "Qwen3 ASR", "127.0.0.1", "个人词库", "Typeless", "VoicePolishPipeline", "WorkBuddy", "密码框", "近期", "改口", "公开勘误", "真的真的很好", "行行行", "长文本", "token", "负责人", "截止时间", "codesign", "Esc", "P50", "P95", "独立 Agent", "direct send", "零回退", "质量修复重试次数最终最多两次"],
            forbidden=["质量修复重试次数先按三次", "缪斯"],
            min_paragraphs=7,
            context=context_fixture(
                "recent_safe", "metadataOnly", "safe",
                recent=[
                    "Dal 的候选构建正在验收。",
                ],
            ),
            context_forbidden=[],
            cross_segment_correction=True,
            strict_claims=True,
            min_source_length_ratio=0.82,
        ),
        natural_long_case(
            case_id="natural-long-10",
            scene="document",
            title="超长自然课程生产总计划",
            segments=course_segments,
            reference_blocks=course_full_reference,
            required=["普通职场人", "个体创作者", "资料研究", "可发布文案", "自动化流程", "Windows", "macOS", "API Key", "官方来源", "第四章", "语音输入", "B-roll", "Obsidian", "idea", "Agent", "人工确认", "小林", "小陈", "设计组", "剪辑组", "助教组", "真实截图", "零基础学员", "内部学员", "购买须知", "内容授权", "最终验收", "课程资料复核最终安排两轮"],
            forbidden=[
                "九月三日", "9 月 3 日", "第七章", "我改一下",
                "这份计划最后请整理成", "不要压成十几行摘要",
                "旧日期不要出现在最终计划里",
                "课程资料复核先安排三轮",
                "王小明", "海棠路八号",
            ],
            required_groups=[
                ["九月十日", "9 月 10 日", "9月10日"],
                ["九月十二日", "9 月 12 日", "9月12日"],
                ["九月十五日", "9 月 15 日", "9月15日"],
            ],
            fact_groups=[
                assignment("事实核查", "小林"),
                assignment("真实截图", "小陈", action="标注"),
                assignment("章节封面", "设计组"),
                assignment("画面", "剪辑组", action="字幕"),
                assignment("作业", "助教组", action="常见问题"),
            ],
            min_paragraphs=8,
            context=context_fixture(
                "unknown_blocked", "nearbyText", "unknown",
                before="未知控件里显示王小明住在海棠路八号。",
            ),
            context_forbidden=["王小明", "海棠路八号"],
            cross_segment_correction=True,
            strict_claims=True,
            min_source_length_ratio=0.82,
        ),
    ]


def legacy_automatic_checks(
    *,
    case_id: str,
    test_input_id: str,
    spoken: str,
    reference: str,
    preserve: list[str],
    remove: list[str],
    preconditions: list[str],
) -> dict:
    """为旧母集补上可重复、低误报的字面硬检查。

    旧 must_preserve 同时混有“最终时间是……”这类语义说明，不能一律当成
    字面断言。这里只使用参考成稿中真实出现的短语；禁含项也必须同时满足
    “原口述中存在、参考成稿中不存在”，避免把说明性文字误当模型输出。
    """
    required = [claim for claim in preserve if claim in reference]
    for precondition in preconditions:
        if "→" not in precondition:
            continue
        canonical = precondition.split("→", 1)[1].strip()
        if canonical and canonical in reference:
            required.append(canonical)
    required.extend(LEGACY_REQUIRED_OVERRIDES.get(case_id, []))
    required.extend(VARIANT_REQUIRED_OVERRIDES.get(test_input_id, []))
    forbidden = [
        claim for claim in remove
        if claim in spoken and claim not in reference
    ]
    forbidden.extend(VARIANT_FORBIDDEN_OVERRIDES.get(test_input_id, []))
    for tokens in VARIANT_FACTOR_FORBIDDEN_OVERRIDES.get(test_input_id, {}).values():
        forbidden.extend(tokens)
    checks = {
        "required_substrings": list(dict.fromkeys(required)),
        "forbidden_substrings": list(dict.fromkeys(forbidden)),
        "forbidden_context_substrings": [],
    }
    if groups := LEGACY_REQUIRED_GROUP_OVERRIDES.get(case_id):
        checks["required_substring_groups"] = groups
    item_count = len(re.findall(
        r"(?m)^\s*(?:\d{1,3}[.)、）]|[一二三四五六七八九十]{1,3}[、.)）]|[-*•])\s*",
        reference,
    ))
    if item_count >= 2:
        checks["minimum_list_item_count"] = item_count
    return checks


def sentence_count(text: str) -> int:
    return max(1, len([
        part for part in re.split(r"[。！？!?；;]+", text)
        if part.strip()
    ]))


def factor_assertions_for_variant(item: dict, reference: str) -> dict:
    """把每个压力因素绑定到本条输入真正执行的机器断言。"""
    checks = item["automatic_checks"]
    factors = item["input_factors"]
    removal_factors = {factor for factor in factors if factor in {
        "filler_words", "lexical_repetition", "semantic_repetition",
        "self_correction", "false_start", "unfinished_fragment",
        "explicit_aside", "meta_instruction", "stutter_repetition",
    }}
    forbidden = checks["forbidden_substrings"]
    assertions: dict[str, dict] = {}
    for factor in factors:
        assertion: dict = {"requires_transformation": True}
        factor_forbidden = VARIANT_FACTOR_FORBIDDEN_OVERRIDES.get(
            item["id"], {}
        ).get(factor, [])
        if factor_forbidden:
            assertion["forbidden_substrings"] = factor_forbidden
        elif factor in removal_factors:
            # 清理类因素不得再从总 forbidden 数组按位置猜测。若没有显式绑定，
            # 数据集验证器会拒绝该变体，迫使新增样本同时写清真实清理目标。
            pass
        elif factor in {"missing_punctuation", "wrong_punctuation", "wrong_sentence_boundary"}:
            reference_sentence_count = sentence_count(reference)
            if reference_sentence_count >= 2:
                assertion["minimum_sentence_count"] = reference_sentence_count
            else:
                assertion["requires_terminal_punctuation"] = True
        elif factor == "list_count_change":
            assertion["minimum_list_item_count"] = checks.get(
                "minimum_list_item_count",
                len(re.findall(
                    r"(?m)^\s*(?:\d{1,3}[.)、）]|[一二三四五六七八九十]{1,3}[、.)）]|[-*•])\s*",
                    reference,
                )),
            )
        elif factor == "provider_segment_collapse":
            assertion["minimum_reference_length_ratio"] = checks.get(
                "minimum_reference_length_ratio", 0.65
            )
        else:
            required = [token for token in checks["required_substrings"] if token in reference]
            if required:
                assertion["required_substrings"] = required
            if forbidden:
                assertion["forbidden_substrings"] = forbidden

        override = VARIANT_FACTOR_ASSERTION_OVERRIDES.get(item["id"], {}).get(factor)
        if override:
            assertion.update(override)
        assertions[factor] = assertion
    return assertions


def enrich_source_dataset(document: dict) -> tuple[list[dict], list[dict]]:
    cases = []
    for original in document["cases"]:
        item = copy.deepcopy(original)
        if item["id"] in LEGACY_REFERENCE_OVERRIDES:
            item["reference_output"] = LEGACY_REFERENCE_OVERRIDES[item["id"]]
            item["must_remove"] = [
                claim for claim in item["must_remove"]
                if claim != "目前不是坏了"
            ]
            item["must_preserve"] = list(dict.fromkeys(
                item["must_preserve"] + ["并非故障"]
            ))
        item["length_bucket"] = length_bucket(item["spoken_input"])
        item["context_type"] = "none"
        item["quality_dimensions"] = common_dimensions(item)
        item["requires_transformation"] = True
        item["segment_texts"] = [item["spoken_input"]]
        item["automatic_checks"] = legacy_automatic_checks(
            case_id=item["id"],
            test_input_id=item["id"],
            spoken=item["spoken_input"],
            reference=item["reference_output"],
            preserve=item["must_preserve"],
            remove=item["must_remove"],
            preconditions=item.get("preconditions", []),
        )
        cases.append(item)

    variants = []
    base_by_id = {item["id"]: item for item in cases}
    for original in document["stress_variants"]:
        item = copy.deepcopy(original)
        if item["id"] == "code-01-noise-01":
            # 原样本里的中英文空格均属正常分词。显式注入一个词内断空格，
            # 让 accidental_space 标签和机器禁含断言都有真实输入证据。
            item["spoken_input"] = item["spoken_input"].replace(
                "Voice Polish Pipeline", "Voice Pol ish Pipeline", 1
            )
        item["input_factors"] = VARIANT_FACTOR_OVERRIDES.get(
            item["id"], item["input_factors"]
        )
        base = base_by_id[item["base_case_id"]]
        item["length_bucket"] = length_bucket(item["spoken_input"])
        item["context_type"] = "none"
        item["quality_dimensions"] = sorted(set(common_dimensions(item) + base["quality_dimensions"]))
        item["requires_transformation"] = True
        item["segment_texts"] = [item["spoken_input"]]
        item["automatic_checks"] = legacy_automatic_checks(
            case_id=item["base_case_id"],
            test_input_id=item["id"],
            spoken=item["spoken_input"],
            reference=base["reference_output"],
            preserve=base["must_preserve"],
            remove=base["must_remove"],
            preconditions=base.get("preconditions", []) + item.get("preconditions", []),
        )
        item["factor_assertions"] = factor_assertions_for_variant(
            item,
            base["reference_output"],
        )
        variants.append(item)
    return cases, variants


def provider_segment_collapse_variants(cases: list[dict]) -> list[dict]:
    """同一长文模拟 Provider 只回 1～2 个 segment，验证布局与完整度不变。"""
    base_by_id = {item["id"]: item for item in cases}
    specs = [
        ("natural-long-01", 1, False),
        ("natural-long-05", 2, False),
        ("natural-long-09", 1, True),
        ("natural-long-10", 2, True),
    ]
    result = []
    for base_id, target_count, asr_dirty in specs:
        base = base_by_id[base_id]
        source_segments = list(base["segment_texts"])
        dirty_forbidden: list[str] = []
        if asr_dirty:
            # 模拟真实超长 ASR：多数 segment 缺少标点，部分语义边界被粘连，
            # 并散布重复起步、半句话和明确改口。原始独立信息一个不删，便于
            # 继续沿用逐 claim 与 0.82 来源完整度硬门槛。
            source_segments = [
                segment.rstrip("。") if index % 3 == 0 else
                segment.translate(str.maketrans("，。；：！？、", "       "))
                for index, segment in enumerate(source_segments)
            ]
            if base_id == "natural-long-09":
                source_segments[0] = (
                    "嗯先从录音这一段说 不是先别从这里说还是从整个流程开始 "
                    + source_segments[0]
                )
                source_segments[8] = (
                    "这个这个长文本我刚才先说成只是速度慢 撤回刚才这句主要是等完又回来原文 "
                    + source_segments[8]
                )
                source_segments[-1] += " 还有日志那块呃后面那个"
                dirty_forbidden = [
                    "嗯", "先从录音这一段说", "不是先别从这里说", "这个这个",
                    "只是速度慢", "撤回刚才这句", "呃", "后面那个",
                ]
            else:
                source_segments[0] = (
                    "啊先从第七章讲 不对先把总目标说清楚 " + source_segments[0]
                )
                source_segments[24] = "我们我们" + source_segments[24]
                source_segments[-1] += " 还有助教那块呃后面再补"
                dirty_forbidden = [
                    "啊", "先从第七章讲", "不对", "我们我们", "呃后面再补",
                ]
        spoken_input = "".join(source_segments)
        if target_count == 1:
            collapsed = [spoken_input]
        else:
            split_index = max(1, len(source_segments) // 2)
            collapsed = [
                "".join(source_segments[:split_index]),
                "".join(source_segments[split_index:]),
            ]
        dimensions = [
            dimension for dimension in base["quality_dimensions"]
            if dimension != "multi_segment"
            and not (target_count == 1 and dimension == "cross_segment_correction")
        ]
        if target_count > 1:
            dimensions.append("multi_segment")
        dimensions.append("segment_boundary_robustness")
        if asr_dirty:
            dimensions.extend(["disfluency_cleanup", "correction_resolution"])
        variant_id = (
            f"{base_id}-asr-dirty-segments-{target_count}"
            if asr_dirty else f"{base_id}-segments-{target_count}"
        )
        for tokens in VARIANT_FACTOR_FORBIDDEN_OVERRIDES.get(variant_id, {}).values():
            dirty_forbidden.extend(tokens)
        input_factors = ["provider_segment_collapse"]
        if asr_dirty:
            input_factors += [
                "filler_words", "stutter_repetition", "false_start",
                "self_correction", "unfinished_fragment", "missing_punctuation",
                "wrong_sentence_boundary",
            ]
            if base_id == "natural-long-10":
                input_factors += ["fact_correction", "meta_instruction"]
        automatic_checks = copy.deepcopy(base["automatic_checks"])
        automatic_checks["forbidden_substrings"] = list(dict.fromkeys(
            automatic_checks["forbidden_substrings"] + dirty_forbidden
        ))
        variant = {
            "id": variant_id,
            "base_case_id": base_id,
            "input_factors": input_factors,
            "spoken_input": spoken_input,
            "length_bucket": base["length_bucket"],
            "context_type": base["context_type"],
            "quality_dimensions": sorted(set(dimensions)),
            "requires_transformation": base["requires_transformation"],
            "segment_texts": collapsed,
            "automatic_checks": automatic_checks,
        }
        if asr_dirty:
            variant["stutter_form"] = "word_or_phrase"
        variant["factor_assertions"] = factor_assertions_for_variant(
            variant,
            base["reference_output"],
        )
        collapse_assertion = {
            "requires_transformation": True,
            "maximum_input_segment_count": target_count,
        }
        if base["length_bucket"] == "ultra_long_3001_8000":
            collapse_assertion["minimum_internal_chunk_count"] = 2
        variant["factor_assertions"]["provider_segment_collapse"] = collapse_assertion
        if "context_fixture" in base:
            variant["context_fixture"] = copy.deepcopy(base["context_fixture"])
        result.append(variant)
    return result


def main() -> None:
    source = json.loads(SOURCE_PATH.read_text(encoding="utf-8"))
    cases, variants = enrich_source_dataset(source)
    cases.extend(short_cases())
    cases.extend(context_cases())
    cases.extend(long_cases())
    cases.extend(natural_long_cases())
    variants.extend(provider_segment_collapse_variants(cases))

    factor_definitions = copy.deepcopy(source["input_factor_definitions"])
    factor_definitions["provider_segment_collapse"] = "Provider 将同一长语音压成一个或两个 segment"
    factor_acceptance_rules = copy.deepcopy(source["factor_acceptance_rules"])
    factor_acceptance_rules["provider_segment_collapse"] = "成稿布局、事实与完整度不得依赖 segment 数量"
    factor_coverage_requirements = copy.deepcopy(source["factor_coverage_requirements"])
    factor_coverage_requirements["filler_words"] = 4
    factor_coverage_requirements["provider_segment_collapse"] = 4

    document = {
        "schema_version": 7,
        "name": "Dal 语音润色多维产品质量测试集 V3.2",
        "created_at": "2026-08-17",
        "language": "zh-CN",
        "source_dataset": SOURCE_PATH.name,
        "north_star_metric": "direct_send",
        "acceptance_thresholds": {
            "baseline_direct_send_minimum": 0.85,
            "baseline_direct_or_minor_minimum": 0.95,
            "stress_direct_send_minimum": 0.85,
            "stress_direct_or_minor_minimum": 0.95,
            "critical_fact_intent_entity_errors": 0,
            "long_context_major_or_unusable": 0,
            "long_text_fallbacks": 0,
        },
        "rating_scale": source["rating_scale"],
        "case_count": len(cases),
        "stress_variant_count": len(variants),
        "total_input_count": len(cases) + len(variants),
        "length_bucket_definitions": {
            "micro_1_15": "1～15 字，验证最小必要修改与不过度改写",
            "short_16_80": "16～80 字，验证日常消息成稿",
            "medium_81_300": "81～300 字，验证多句与轻结构",
            "long_301_1000": "301～1000 字，验证完整长消息",
            "very_long_1001_3000": "1001～3000 字，验证多主题长文",
            "ultra_long_3001_8000": "3001～8000 字，验证超长成稿与不截断",
        },
        "length_bucket_coverage_requirements": {
            "micro_1_15": 8,
            "short_16_80": 25,
            "medium_81_300": 20,
            "long_301_1000": 8,
            "very_long_1001_3000": 8,
            "ultra_long_3001_8000": 4,
        },
        "context_type_definitions": {
            "none": "不提供正文上下文",
            "nearby_safe": "安全输入框附近文字",
            "selected_safe": "用户明确选中的安全文字",
            "recent_safe": "同一应用近期 Dal 输入",
            "conflicting_safe": "授权上下文存在冲突，不得猜测",
            "irrelevant_safe": "上下文含无关事实，不得注入正文",
            "secure_blocked": "安全字段正文必须被清空",
            "unknown_blocked": "未知控件正文必须被清空",
        },
        "context_type_coverage_requirements": {
            "none": 77,
            "nearby_safe": 6,
            "selected_safe": 5,
            "recent_safe": 4,
            "conflicting_safe": 1,
            "irrelevant_safe": 1,
            "secure_blocked": 2,
            "unknown_blocked": 2,
        },
        "quality_dimension_definitions": {
            "final_intent": "最终意图唯一且正确",
            "fact_preservation": "来源事实完整保留",
            "no_invention": "不新增无来源内容",
            "direct_send": "成稿可直接发送",
            "minimal_edit": "短文本只做必要修改",
            "tone_preservation": "保留语气与力度",
            "deliberate_repetition_preservation": "保留有意重复",
            "contextual_typo_correction": "利用授权上下文纠正错词",
            "context_non_leakage": "上下文无关内容不进入正文",
            "terminology": "专名和中英混排正确",
            "long_content_completion": "长文不摘要、不截断、不回退",
            "semantic_layout": "按语义分段或列点",
            "multi_segment": "真实多 ASR segment",
            "cross_segment_correction": "跨 segment 只保留最终事实",
            "segment_boundary_robustness": "布局与完整度不依赖 Provider 的 segment 切分",
            "independent_constraint_preservation": "独立事项和约束逐项保留",
            "correction_resolution": "改口正确收口",
            "disfluency_cleanup": "口吃和机械重复清理",
            "prompt_not_execution": "AI Prompt 只整理不执行",
        },
        "quality_dimension_coverage_requirements": {
            "minimal_edit": 8,
            "tone_preservation": 8,
            "deliberate_repetition_preservation": 2,
            "contextual_typo_correction": 21,
            "context_non_leakage": 21,
            "long_content_completion": 20,
            "semantic_layout": 20,
            "multi_segment": 20,
            "cross_segment_correction": 7,
            "segment_boundary_robustness": 4,
        },
        "input_factor_definitions": factor_definitions,
        "factor_acceptance_rules": factor_acceptance_rules,
        "factor_coverage_requirements": factor_coverage_requirements,
        "stutter_form_definitions": source["stutter_form_definitions"],
        "stutter_form_coverage_requirements": source["stutter_form_coverage_requirements"],
        "cases": cases,
        "stress_variants": variants,
    }
    OUTPUT_PATH.write_text(
        json.dumps(document, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    rows = []
    for item in cases:
        rows.append((item["id"], item["id"], "base", item))
    for item in variants:
        rows.append((item["id"], item["base_case_id"], "stress_variant", item))
    with RUN_PATH.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow([
            "test_input_id", "base_case_id", "input_kind", "length_bucket", "context_type",
            "quality_dimensions", "requires_transformation", "model_output", "fallback_used",
            "validation_codes", "hard_checks", "rating", "reviewer", "notes",
        ])
        for test_id, base_id, kind, item in rows:
            writer.writerow([
                test_id, base_id, kind, item["length_bucket"], item["context_type"],
                "+".join(item["quality_dimensions"]), str(item["requires_transformation"]).lower(),
                "", "", "", "", "", "", "",
            ])

    print(f"生成完成：{len(cases)} 条基准 + {len(variants)} 条变体 = {len(rows)} 次输入")
    print(OUTPUT_PATH)
    print(RUN_PATH)


if __name__ == "__main__":
    main()
