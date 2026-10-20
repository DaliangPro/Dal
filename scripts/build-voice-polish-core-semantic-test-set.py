#!/usr/bin/env python3
"""从冻结的 130 条母集生成不含参考答案的 25 条核心语义测试集。"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "docs/2026-08-17-Dal-Voice-Polish-Quality-Test-Set.json"
OUTPUT = ROOT / "docs/2026-08-17-Dal-Voice-Polish-Core-Semantic-Test-Set.json"
STRESS_BOUNDARY_IDS = {
    "natural-long-09-asr-dirty-segments-1",
    "natural-long-10-asr-dirty-segments-2",
}


def contract(
    primary_boundary: str,
    final_intent: list[str],
    must_preserve: list[str],
    must_resolve: list[str],
    must_not_add: list[str],
    acceptable_variations: list[str],
    major_error_if: list[str],
) -> dict:
    return {
        "primary_boundary": primary_boundary,
        "final_intent": final_intent,
        "must_preserve": must_preserve,
        "must_resolve": must_resolve,
        "must_not_add": must_not_add,
        "acceptable_variations": acceptable_variations,
        "major_error_if": major_error_if,
    }


CONTRACTS = {
    "micro-02": contract(
        "极短问句只补必要标点",
        ["询问对方当前所在位置"],
        ["疑问语气", "你与对方的直接聊天口吻"],
        ["补足问句标点，但不得扩写"],
        ["地点猜测", "催促、责备或额外寒暄"],
        ["使用中文问号；除此之外保持原句"],
        ["把问句改成陈述或命令", "增加原文没有的地点或态度"],
    ),
    "micro-04": contract(
        "有意重复必须保留",
        ["强调评价非常好"],
        ["连续两次“真的”所表达的强调力度"],
        ["原句已经可发送，允许完全不改"],
        ["评价对象、原因或额外结论"],
        ["只调整不影响强调的空格或标点"],
        ["改变正面评价方向", "明显削弱或删除强调态度；仅压成一次“真的”可判少量修改"],
    ),
    "micro-05": contract(
        "非自愿口吃应清理",
        ["告知对方自己已经到达"],
        ["已经到达这一事实"],
        ["删除句首重复的“我”并补必要标点"],
        ["到达时间、地点或催促"],
        ["我到了。", "已经到了。"],
        ["继续保留口吃", "改变为尚未到达或正在路上"],
    ),
    "micro-11": contract(
        "被撤回的强调不再保留",
        ["最终评价只是一般"],
        ["最后感觉一般的态度与强度"],
        ["删除已经被“不对”撤回的正面强调和改口过程"],
        ["很好、很差或新的评价理由"],
        ["最后感觉一般。", "最后觉得一般。"],
        ["仍保留“真的真的很好”的含义", "把一般改成明显负面"],
    ),
    "chat-03": contract(
        "双重否定与态度澄清不能被简化掉",
        ["愿意帮忙，但这两天确实没有时间；忙完后再沟通"],
        ["不是不愿意帮", "这两天排不开", "不是敷衍", "忙完这一阵再联系"],
        ["去掉机械重复，但保留澄清关系"],
        ["明确日期", "保证一定帮成", "具体忙碌原因"],
        ["可以重排句序，使澄清更自然"],
        ["变成不愿意帮", "删除不是敷衍的态度澄清", "增加确定承诺"],
    ),
    "chat-05": contract(
        "口述枚举应形成清晰而完整的三项任务",
        ["请对方明天带三样物品，其他不用带"],
        ["充电器", "上次那本书", "门卡", "总数三样", "其他不用带"],
        ["清理“对，就是这三样”等确认过程"],
        ["型号、书名、门卡用途或第四样物品"],
        ["编号、项目符号或一句内清楚枚举均可"],
        ["漏掉或新增物品", "总数与实际项目不一致", "删除其他不用带的限制"],
    ),
    "work-02": contract(
        "同一会议的时间、参与方和人数均以最终版本为准",
        ["评审最终改到周四上午十点，产品、设计、开发参加，共六人"],
        ["周四上午十点", "产品", "设计", "开发", "共六人"],
        ["删除周三下午三点、四个人及改口过程"],
        ["具体姓名、地点、各角色人数分配"],
        ["角色顺序和句式可以变化"],
        ["保留旧时间或旧人数", "漏掉开发", "擅自分配六人的构成"],
    ),
    "work-03": contract(
        "发布决定、原因和待决状态必须保持关系",
        ["今晚暂不发布；两个阻塞确认后，明早再决定"],
        ["测试环境数据未跑完", "回滚脚本未验证", "原计划灰度10%", "明早再决定"],
        ["清理口述开场，但不得把原计划写成当前执行"],
        ["负责人、客户影响、明早一定发布"],
        ["可用结论加原因的段落或简短列表"],
        ["写成今晚发布或灰度10%", "把明早再决定改成确定发布", "漏掉任一阻塞"],
    ),
    "email-03": contract(
        "私人纠错邮件只保留最终正确附件版本",
        ["向赵经理致歉，重发第三版，并以后面这份为准"],
        ["赵经理", "附件发错", "第三版", "以后面重发版本为准", "致歉"],
        ["删除第二版和口述改口过程"],
        ["文件名、错误原因、附件内容"],
        ["邮件格式和礼貌程度可自然调整"],
        ["仍把第二版写成有效版本", "漏掉第三版或以重发版本为准", "漏掉收件人"],
    ),
    "social-05": contract(
        "公开更正必须同时保留错误值和正确值",
        ["公开说明昨天视频日期说错，并给出正确日期和预约处理"],
        ["错误日期8月18日", "正确日期8月28日", "预约链接时间正确", "无需重新预约", "致歉"],
        ["清理口头表达，但不得删除公开勘误所需的旧值"],
        ["错误原因、活动地点、补偿措施"],
        ["可以使用更正说明标题，也可以直接成段"],
        ["删除错误日期", "把两个日期关系写反", "要求用户重新预约"],
    ),
    "support-04": contract(
        "客服成稿不得泄露未确认的内部判断，也不得过度承诺",
        ["告知客户已收到问题、正在排查、明天下午前同步一次进展"],
        ["已收到", "技术正在排查", "预计明天下午前给进展", "不能承诺一定修好"],
        ["删除第三方接口波动这一未确认内部判断和幕后说明"],
        ["确定根因", "明天下午前修复完成", "补偿方案"],
        ["可以把不能承诺改写为当前仍在确认原因或暂无法给出修复时间"],
        ["泄露第三方接口波动", "承诺一定修好或确定修复时间", "漏掉进展时间"],
    ),
    "support-05-stutter-01": contract(
        "客服步骤要清理口吃并保留完整排查路径",
        ["给出两步权限处理方法；仍失败时收集系统信息继续排查"],
        ["系统设置", "辅助功能", "完全退出后重开", "系统版本", "错误截图", "不归责客户"],
        ["删除给给、功功能、辅助辅助等口吃；幕后不归责要求应落实为客观语气"],
        ["具体菜单路径", "一定解决", "客户操作错误"],
        ["两步可用编号或清晰分句表达"],
        ["漏掉系统设置、完整退出或失败后的信息收集", "仍保留明显口吃", "指责客户"],
    ),
    "context-03": contract(
        "唯一安全上下文只用于纠正产品名，不得带入无关事实",
        ["WorkBuddy 仍识别不到输入框，请先开辅助功能"],
        ["标准写法WorkBuddy", "识别不到输入框", "辅助功能"],
        ["将work buddy纠正为WorkBuddy"],
        ["蓝鲸计划", "下周三迁移", "任何上下文测试标记"],
        ["仍然、还是等语气可以互换"],
        ["产品名未纠正", "泄露无关项目、日期或上下文标记"],
    ),
    "context-09": contract(
        "冲突上下文不得替用户猜未确认名称",
        ["名称仍写灵建，并说明尚未确认、不要代猜"],
        ["灵建", "未确认", "先保留", "不要猜"],
        ["只整理口语和标点，不执行冲突候选映射"],
        ["灵简", "灵境", "蒋川", "转交另一团队", "上下文测试标记"],
        ["不要替我猜、请勿代为确定等语义等价表达"],
        ["把灵建改成任一上下文候选", "删除未确认状态", "泄露上下文事实"],
    ),
    "context-11": contract(
        "安全字段正文完全不可用",
        ["回复对方已经收到"],
        ["已经收到"],
        ["将幕后动词整理成直接回复"],
        ["654321", "验证码", "安全字段中的任何内容"],
        ["收到。", "已经收到。"],
        ["出现验证码或安全字段内容", "改变成尚未收到"],
    ),
    "context-17": contract(
        "转达对象是最终意图的一部分",
        ["告知团队会议改到周四下午"],
        ["团队这一接收对象", "会议改期", "周四下午"],
        ["把跟团队说整理成面向团队或明确告知团队的成稿"],
        ["客户邮箱", "验证码", "会议地点或原因"],
        ["请告知团队、团队各位请注意、发给团队的直接消息均可"],
        ["只剩会议改期而丢失团队对象", "泄露安全字段"],
    ),
    "prompt-02-noise-01": contract(
        "AI Prompt 必须成为可直接执行的请求，而不是回答请求或再要求整理Prompt",
        ["让AI分析Swift并发问题，但先不改代码"],
        ["完整错误信息MainActor isolated property cannot be referenced", "解释原因", "调用链", "最小修改方案", "需要补的测试"],
        ["修复refer enced词内空格和错误句界；把让AI查整理成任务本身"],
        ["具体根因结论", "代码补丁", "未提供的文件和调用链事实"],
        ["要求数量可用列表，也可用清楚分段；不得实际分析问题"],
        ["直接回答并给出根因或代码", "漏掉任一独立任务", "改变错误信息"],
    ),
    "code-01": contract(
        "口述代码符号必须还原为精确路径和命令",
        ["记录长文本超过2048 tokens退原文的Bug及复现命令"],
        ["Dal/VoicePolish/VoicePolishPipeline.swift", "2048 tokens", "回退原文", "swift test --filter VoicePolishPipelineTests"],
        ["恢复斜杠、点号和双横线；删除幕后保真说明"],
        ["根因、修复方案、错误日志"],
        ["可使用代码格式或普通文本，但字符必须精确"],
        ["路径少层级或命令改变", "把复现写成已执行", "添加根因"],
    ),
    "code-03": contract(
        "步骤数量改口和执行顺序必须一起更新",
        ["部署共有四个检查步骤，完成后再启动应用"],
        ["swift test", "swift build -c release", "scripts/package-app.sh", "检查codesign", "最后启动应用"],
        ["删除旧的三步声明和补充过程"],
        ["签名身份、启动命令、安装路径"],
        ["四步可用编号或明确顺序表达"],
        ["仍写三步", "漏掉或执行codesign而非检查", "把启动应用混入四步之内"],
    ),
    "code-05": contract(
        "不确定版本和缺失错误码必须保持不确定",
        ["问题可能与Swift 6.1或6.2有关，具体版本未确认，错误码未保存"],
        ["Swift 6.1", "Swift 6.2", "具体版本未确认", "错误码未保存"],
        ["把幕后不要猜落实为明确待确认状态"],
        ["确定具体版本", "虚构错误码或根因"],
        ["可概括为较新Swift编译器，但必须同时保留6.1/6.2候选或同等不确定范围"],
        ["擅自确定6.1或6.2", "补写错误码", "删除待确认状态"],
    ),
    "natural-long-02": contract(
        "自然会议纪要要同时处理预算改口、待确认事项和多角色行动",
        ["课程面向零基础真实任务；预算最终16000；章节顺序、分工和待确认事项完整"],
        ["预算包含录制和剪辑、不含投放", "第一二三章顺序", "小林、产品组、设计组、测试组、运营组的行动", "周五内部试看", "正式发布时间和案例授权待确认", "不承诺当晚修完"],
        ["删除16800及改口过程；不能把待确认写成决定"],
        ["正式发布日期", "案例已获授权", "当晚全部修完"],
        ["可以用自然段加局部列表，不要求照抄参考措辞"],
        ["保留旧预算", "漏掉任一角色行动", "把待确认项写成已确定", "压成摘要"],
    ),
    "natural-long-05": contract(
        "完整交接邮件必须保留独立约束和承诺边界",
        ["向团队交接内部试看阶段的任务、分工、安全和发布边界"],
        ["所有独立任务与负责人/时间关系", "周三录制并取消周二旧计划", "周五仅内部试看", "不承诺周五对外发布", "素材授权、双平台兼容、两组试看、更新与售后、普通浏览器验证、支付人工确认、附件边界"],
        ["删除周二录制旧安排；把幕后语气要求落实为自然但明确的团队邮件"],
        ["周五一定不发布这一确定事实", "未说出的负责人、日期或承诺", "API Key或客户文件内容"],
        ["标题、段落和列表可自由组织；允许不逐字重复，但不得丢独立约束"],
        ["把不承诺周五发布改成确定不会发布", "漏掉任一主要任务簇或安全边界", "压缩成摘要"],
    ),
    "natural-long-06": contract(
        "长AI Prompt必须直接交付任务本身并保全全部研究约束",
        ["为北辰研究生成可直接交给AI执行的语音输入产品研究Prompt，但现在不执行研究"],
        ["5款个人创作者工具", "官方来源边界", "平台、长语音、上下文、语气、回退和价格字段", "币种周期日期与地区差异", "资料确认和安装实测分开", "500/1500/3500字测试", "上下文正负例", "对比表、适用对象、3个待实测问题和逐条来源", "样本类型、评分、速度、引用、语言差异、复现记录、安全与反例要求"],
        ["北城研究纠正为北辰研究；删除请再次整理Prompt的外层任务"],
        ["紫色包装", "九月三日", "上下文测试标记", "研究答案、排名或评分结果"],
        ["可以用标题和多级列表；项目名可使用完整选中标题或北辰研究"],
        ["输出仍是让别人整理Prompt的请求", "直接开始研究", "漏掉整类约束", "泄露上下文无关内容", "压成摘要"],
    ),
    "natural-long-09-asr-dirty-segments-1": contract(
        "六千字单segment口述必须完成全文整理和远距离改口",
        ["形成完整的语音输入产品全过程复盘，保留所有独立原则与最终决定"],
        ["录音、流式与终包、本地服务、术语、上下文、改口、重复、长文、排版、事实、设置、测试、注入、并发、日志、模型、学习、性能、权限、设备、弱网、混合语言、segment与发布安全等全部主题", "质量修复重试最终最多两次", "其他合法数字3不得误删"],
        ["清理开头假启动、填充词和口吃；删除质量修复重试三次这一旧值及改口过程"],
        ["海星项目", "厦门", "上下文测试标记", "新的产品承诺或指标"],
        ["可按主题自然分段并使用少量小标题；不得要求逐字复述"],
        ["同时保留重试三次和两次", "漏掉整段主题或大量独立约束", "退回原转写", "泄露上下文"],
    ),
    "natural-long-10-asr-dirty-segments-2": contract(
        "近八千字课程计划必须保全章节、跨段改口、规则与发布边界",
        ["形成完整、可执行的课程计划，按最终章节顺序、排期和复核轮次表达"],
        ["全部课程目标、八个章节及后续运营和安全规则", "语音输入最终放第四章", "主课录制9月10日、复核9月12日、9月15日仅内部试看", "课程资料复核最终两轮", "所有角色、授权、隐私、支付、备份、无障碍、版本、售后与发布停步规则"],
        ["删除原第七章位置、9月3日和三轮复核旧值；清理口吃、假启动和改口过程"],
        ["未知控件中的姓名和地址", "未说出的发布日期、付款或授权结论"],
        ["可按目标、章节、排期、分工、素材、质量和发布边界重组；不得压成短摘要"],
        ["保留任一已作废值", "遗漏整个章节或主要规则簇", "退回原转写", "泄露未知上下文", "把内部试看写成公开发布"],
    ),
}


def main() -> None:
    source_bytes = SOURCE.read_bytes()
    source_sha256 = hashlib.sha256(source_bytes).hexdigest()
    document = json.loads(source_bytes.decode("utf-8"))
    rows = document["cases"] + document["stress_variants"]
    by_id = {row["id"]: row for row in rows}
    base_by_id = {row["id"]: row for row in document["cases"]}

    missing = sorted(set(CONTRACTS) - set(by_id))
    if missing:
        raise SystemExit(f"母集缺少核心样本：{missing}")
    if len(CONTRACTS) != 25:
        raise SystemExit(f"核心样本必须固定为 25 条，当前为 {len(CONTRACTS)}")

    inputs = []
    for test_input_id, semantic_contract in CONTRACTS.items():
        row = by_id[test_input_id]
        base_case_id = row.get("base_case_id", test_input_id)
        base = base_by_id[base_case_id]
        inputs.append({
            "test_input_id": test_input_id,
            "source_case_id": base_case_id,
            "input_kind": "stress" if "base_case_id" in row else "base",
            "acceptance_tier": (
                "stress_boundary"
                if test_input_id in STRESS_BOUNDARY_IDS
                else "primary"
            ),
            "title": row.get("title", base.get("title", test_input_id)),
            "writing_scene": row.get("writing_scene", base["writing_scene"]),
            "spoken_input": row["spoken_input"],
            "segment_texts": row.get("segment_texts", base["segment_texts"]),
            "context_type": row.get("context_type", base.get("context_type", "none")),
            "context_fixture": row.get("context_fixture", base.get("context_fixture")),
            "requires_transformation": row.get(
                "requires_transformation",
                base.get("requires_transformation", True),
            ),
            "semantic_contract": semantic_contract,
        })

    result = {
        "schema_version": 2,
        "name": "Dal 语音润色核心语义测试集 V2",
        "created_at": "2026-08-17",
        "language": "zh-CN",
        "source_dataset": SOURCE.name,
        "source_dataset_sha256": source_sha256,
        "case_count": len(inputs),
        "rules": {
            "reference_output_is_not_a_unique_answer": True,
            "writer_must_not_receive_semantic_contract": True,
            "blind_review_hides_model_identity": True,
            "primary_case_count": len(inputs) - len(STRESS_BOUNDARY_IDS),
            "stress_boundary_case_count": len(STRESS_BOUNDARY_IDS),
            "primary_long_text_target_chars": "700-1500",
            "critical_error_types": [
                "fact",
                "final_intent",
                "entity",
                "modality",
                "context_leak",
                "task_layer",
            ],
        },
        "inputs": inputs,
    }
    OUTPUT.write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"PASS：已生成 {len(inputs)} 条核心语义样本")
    print(f"source_dataset_sha256={source_sha256}")


if __name__ == "__main__":
    main()
