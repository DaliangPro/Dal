# Dal 直出与润色架构方案

更新：2026-09-21。当前目标见[产品需求](2026-08-17-Dal-Voice-Polish-Product-Requirements.md)，执行进度见 [REPAIR_PLAN](../REPAIR_PLAN.md)。以下当前设计取代旧三档目标；后面的历史实验记录保留来源与原结论。

## 1. 模式与配置

ProcessingMode 的活动系统模式为 direct 与 formalWriting；后者沿用原标准 UUID，对用户显示“润色”。VoiceInputModes 仅承担旧轻度 ID 到当前润色的解析。ModeStorage 加载时隐藏旧轻度，保存时从原始文件保留该项，防止编辑其他设置丢失旧内容。自定义名称、要求与已有快捷键保持；补全系统模式时不抢占已有绑定。

PolishModelRole 的活动角色只有 standard，继续使用原存储键与既有凭据回退。light 枚举只为旧配置兼容保留，resolve 一律选择 standard；旧轻度配置不会参与当前任务。模型设置只有一个润色卡片。

## 2. 处理与交付

直出沿用识别和词库纠正链路，零润色调用。润色通过 RecognitionSession.preparePolishRequest 共用分段规范化、词库投影和 EntityResolver 授权纠错，最终 canonical_text 与 additional_requirements 进入 VoicePolishEditingPipeline，一次 voicePolishStructured 请求输出完整正文。

使用明确要求纠错后按事项归拢、枚举逐项换行与自然分段的标准提示词和协议版本 18；先落实普通改口，再把同一事项的全部有效分句归成相邻内容组（包括满足条件后才执行的动作），最后在组内分阶段排版。原句措辞保留不保护废弃口误，也不限制必要重排；不新增标题或上下级子列表，不改变责任归属或逻辑关系。temperature=0、thinking 禁用、文本响应、2,048 输出 tokens、既有 30 秒请求边界。传输失败、空输出、危险字符、过大或截断响应沿用恢复出口；模型成功正文不经第二轮程序改写。UI 显式重试是新的有界请求。

当前模型不消费 StyleProfile，正式停止阶段移除相应历史查询和计算；已授权上下文仍参与本地实体纠错。旧 Fast/Structured/Deep 路由、Intent Ledger 编排及其校验器已于 2026-09-28 删除，录音、预生成、试跑与质量 Runner 均直接使用 VoicePolishEditingPipeline。

## 3. 停顿预生成

PolishPrefetch 由当前润色模式驱动，稳定约 800ms、每会话最多两次、只用于云端。它与正式交付共享上下文读取和 preparePolishRequest；预生成保留录音开始时的上下文捕获，正式交付核对最新近期输入的实际纠错结果。

候选键包含最终正文和附加要求 UTF-8、模型/端点/凭据/Provider/thinking、提示协议版本，缓存以会话隔离。正文变化、模式切换或取消使候选失效；只消费完整匹配且已成功的结果，不等待未完成请求。预生成调度数与复用标记独立保存，不将其误称为成功 Provider 调用数。

## 4. 入口、记录与验收

设置、快捷键、试跑、录音均使用同一模式语义。试跑只提示生成状态、次数与耗时，不将输入推断的版式当作实际输出，也不将传输检查称为内容校验通过。新记录写直出或润色，历史模式与报告保持真实来源。质量 Runner 必须显式指定 direct 或 standard，旧 light 参数作为 standard 别名解析，实际报告记录 standard；旧自动路径已随 legacy_automatic 删除。

按产品需求完成配置兼容、并发/取消/末尾改口/上下文变化、单次请求与其他模式回归，运行全量测试与两类构建，再进行独立真实输出与候选来源验收。通过后按项目默认授权复用原签名部署并核验安装版。

## 10. 历史受控实验记录

以下保留当时输入、模型、代码与结果，供定位问题和比较方案使用。后续开发目标与测试范围以第 1～4 节及产品需求文档为准，历史实验不能替代当前验收。

### 10.1 实验边界

- 实验完全位于 Dal 正式 Pipeline 之外，没有改动、打包或安装生产应用；
- 25 条核心集不向模型提供参考答案、`semantic_contract` 或自动评分字段；
- 凭证只通过标准输入进入进程，报告与模型输入中不保存 API Key；
- 当前模型为 `deepseek-v4-flash`，更强对照为 `deepseek-v4-pro`；
- 候选隐藏模型名称后，由未参与实现的独立 Agent 评分。

证据目录：

- AI Prompt 定向对照：`build/voice-polish-architecture-targeted-span-v5/`
- 6K 长文最终定向对照：`build/voice-polish-architecture-6k-final-span-v6/`

### 10.2 已被证实有效的结构

1. `Intent Ledger → Writer → 冷 Reviewer → 局部 Repair → Confirm` 可以在失败时返回显式 `unavailable`，不再静默退回原文；
2. 6,179 字单 segment 长文可切成 14 个带范围和哈希的 source spans，并在 8～11 次有界调用内完成；
3. 全文改口投影和旧位置门禁已把“重试三次 → 最多两次”收口为：旧值为零、最终值只出现一次；
4. 高置信残缺尾句“还有日志那块呃后面那个”被删除，没有被擅自补成待确认事项；
5. AI Prompt 的任务层硬检查已删除“不要开始研究，只整理任务”等当前编辑指令，并阻止把“整理 Prompt”再次交给下游 AI。

### 10.3 模型不是单一强弱关系

独立盲评结果：

| 场景 | `deepseek-v4-flash` | `deepseek-v4-pro` |
|---|---|---|
| AI Prompt（约 1,000 字） | `unusable`，安全退出 | `direct_send` |
| 6K 单 segment 长文 | `minor_edit` | `major_error` |

这批历史样本只说明不同任务上的模型表现存在差异，不能据此决定全部输入统一换模。它曾留下以下待研究问题；是否继续研究须服从当前直出与润色目标及千字内测试范围：

- AI Prompt 等任务层复杂输入是否稳定需要 Pro；
- 普通长文 Writer 是否由 Flash 更稳；
- Reviewer 是否应使用与 Writer 不同的模型，减少同模型盲点。

### 10.4 新发现的架构缺口

更强模型在 6K 长文中把：

> 独立 Agent 未明确通过时，不更新修复台账，也不覆盖安装。

错误写成：

> 只有独立 Agent 明确通过后，才更新修复台账，也不覆盖安装。

定位结果显示错误已经出现在局部 Intent Ledger，Writer 只是照写，Reviewer 又因为看到同一份错误 Ledger 而放行。根因不是措辞，而是 `final_meaning + modality` 无法表达条件、否定范围与多个共同后果。

下一版 Ledger 必须增加结构化条件规则，而不是继续增加中文正则：

```json
{
  "conditionals": [
    {
      "condition": {
        "subject": "独立 Agent",
        "predicate": "明确通过",
        "polarity": false,
        "source_spans": ["s006"]
      },
      "consequences": [
        {"action": "更新修复台账为完成", "polarity": false},
        {"action": "覆盖安装正式应用", "polarity": false}
      ]
    }
  ]
}
```

Reviewer 必须对照原始 source spans 独立重建这类高风险条件，不能只检查 Writer 是否遵守 Planner。上下文实体统一也仍有缺口：两个 6K 候选均混用 `Dal` 与“达尔进程”；实验解析器选择不猜是安全的，但在进入生产前应复用经过正反例验证的确定性 EntityResolver。

### 10.5 约 1K 主场景验证

用户确认日常长文本一般约 1,000 字后，实验改用 1,028 字课程交接邮件验证 typed conditional Ledger。两种模型都完成 3 个高置信条件关系的结构化建模，且均在 `Planner → Writer → Reviewer` 三次调用内返回成稿，无 repair、无 fallback：

- 临时改口时只同步最新版本，并在标题标注日期；
- 无法按时完成时写明真实原因，只调整受影响部分，不默认整期延期；
- 素材可下载不等于可进入付费课程，版权依据仍须核对。

独立 Agent 在隐藏模型映射的情况下评分：`deepseek-v4-flash` 为 `minor_edit`，唯一问题是把“语气不用催”这类风格要求写进正文；`deepseek-v4-pro` 为 `direct_send`，把该要求自然落实为收件人可读的语气。没有候选出现事实、条件、改口或不承诺边界错误。

这说明 typed conditional 已解决本轮 1K 样本的主要语义风险，但 Ledger 还必须增加 `delivery_role`，把 `recipient_content`、`style_directive` 和 `editor_directive` 分开。风格与编辑要求只执行、不照抄；该结构完成小批量回归前，仍不进入生产。

### 10.6 首批核心回归与跨模型复核

在 6 条核心样本上进行双模型盲测后，发现同模型 Writer 与 Reviewer 会共享盲点：Flash 漏掉“团队”接收对象且自审放行；Pro 漏掉“原定周二录制已经取消”且自审放行。单纯交换 Reviewer 模型仍无法稳定抓住收件人遗漏，因此模型互审不能替代可证明的本地边界。

随后增加两项 typed 义务：

- `correction.rendering_policy = final_only | announce_change`：区分当前口误只留最终值，与旧安排已经对外、必须明确通知取消/变更；
- `audience.surface_tokens`：Planner 已从 source spans 识别出的收件人称谓，最终成稿至少命中一个，否则只修复收件人。

最终定向回归结果：

- 1,028 字交接邮件的两个模型候选均为 `direct_send`；周二取消、周三录制、三组条件关系、发布承诺和全部主要任务簇完整；
- 收件人样本的两个候选均不再出现重大遗漏，独立 Agent 仅判“团队，会议改到……”称呼略生硬，为 `minor_edit`；
- 本轮 `major_error = 0`、`unusable = 0`，且没有原文 fallback。

由此确定：确定性门禁只负责收件人、精确事实、上下文安全等可证明义务；中文称呼是否自然仍交给 Reviewer 与独立 Agent，不能为了消灭一个轻微措辞问题继续扩大本地中文规则。

### 10.7 建议语气、技术标识与模型边界

对“当前故障现象 + 建议下一步”的短文本增加 `advice/recommended` 后，两个模型都能保留现状并把“开启辅助功能”写成建议，没有再升级成“开启后一定恢复”。独立 Agent 对两个候选均判定为 `direct_send`。这证明建议与确定事实必须在 Ledger 中分开，不能只靠 Prompt 中一句“不要承诺”。

技术错误信息暴露了另一条第一性边界：ASR 将 `MainActor` 写成 `Main Actor` 后，原始声音已经丢失了技术标识的字符边界。没有代码上下文、已授权术语或其他权威证据时，模型只能猜。

两轮盲测出现了反转：

- 严格要求“每条映射只恢复一个技术标识”时，Flash 输出精确错误信息并获 `direct_send`，Pro 因无法给出合法映射而安全返回 `unavailable`；
- 临时允许模型用整句映射选择性删除空格后，Pro 获 `direct_send`，Flash 仍输出 `Main Actor`，被独立 Agent 判为 `major_error`。

因此不保留整句映射放宽。正式设计应按以下顺序恢复技术标识：已授权个人术语或选中上下文、产品内置且可审计的技术词典、单个标识的高置信空格删除；三者都没有证据时显式标记无法确认。模型可以提出候选，但不能单独成为技术 token 的事实来源。

这也回答了模型选择问题：模型会影响一次成稿率和安全退出率，但本轮同一用例已经出现模型间反转，不能把“换成 Pro”当作功能修复。决定产品是否可靠的是 typed Ledger、证据来源、独立 Reviewer 和显式失败；模型只是在该架构内影响成功概率。

实验工具同时增加了 Provider 请求的绝对墙钟超时。socket 持续收到分块数据但响应始终不结束时，也会在上限内写入失败审计，不再无限等待。

### 10.8 日常 1K 长文的模型分工证据

最后使用 1,003 字的真实 AI Prompt 场景做停止前检查。输入要求把一段研究口述直接整理成可执行 Prompt，同时保留来源边界、价格字段、三档长文本测试、上下文正负例、评分口径、引用规则、安全要求和反例检查，并使用安全选中标题把“北城研究”纠正为“北辰研究”。

结果：

- Pro 经一次定向修复后生成完整可执行 Prompt，12 类约束、项目名和安全边界均保留；没有开始执行研究，也没有泄漏选中上下文中的包装、日期或测试标记。独立 Agent 盲评为 `direct_send`；
- Flash 的首稿与修复稿仍残留“整理为 Prompt”的外层任务。Confirm Reviewer 拒绝后返回 `unavailable`，没有把错误候选或原转写冒充成功。独立 Agent 对空候选判为 `unusable`，与系统显式失败状态一致。

结合 1,028 字普通交接邮件中两个模型均可直接发送，这批历史实验中 Pro 在该复杂 AI Prompt 样本上更稳；该结果只适用于当时样本与配置，不代表三档产品的模型选择已经确定。当前依三档目标分别验证工程路径与模型表现，无法完成时须明确提示，不能静默回原文并宣称成功。

### 10.9 第二批核心关系回归

第二批先用 `chat-03`、`work-02`、`work-03`、`code-03`、`code-05` 检查承诺、负责人关系、延期状态、口述技术符号和不确定版本。首轮没有出现危险成稿，但暴露出三项 schema 缺口：已经作出的联系承诺没有 `promised`，建议动作可能自然建模为 `action/recommended`，中文口述的斜杠和短横线被错误塞进普通技术断词字段。

本轮没有为具体句子增加答案特判，而是做了三项通用改动：

1. `promised` 只保留原文已经作出的承诺，Writer 不得扩大承诺范围；
2. `recommended` 可以修饰 action、advice 或 style，但 advice 必须使用 recommended；
3. 口述符号使用独立 `dictated_symbol_mappings`。路径和文件名只做固定符号替换，命令行选项使用 `spoken_cli_symbols` 恢复参数前的必要空格，非符号字符必须逐字不变。

Planner 偶尔会把恒等命令或口述符号映射重复写进 `technical_token_mappings`。这类字段分类错误不需要再次调用模型：本地清洗器删除恒等项，把能够由固定变换确定证明的条目迁回口述符号字段；无法确定的映射仍然失败，不能猜测。

定向回归证据：

- `build/voice-polish-architecture-core-corrections-v20/`
- `build/voice-polish-architecture-core-relations-v21/`
- `build/voice-polish-architecture-schema-relations-v22/`
- `build/voice-polish-architecture-dictated-symbols-v24/`

独立 Agent 在看不到模型映射的情况下，对更新后的 10 条核心样本、每条两个候选给出：`direct_send = 16`、`minor_edit = 4`、`major_error = 0`、`unusable = 0`。其中 `code-03` 的两个候选都精确保留四步、`swift test`、`swift build -c release`、`scripts/package-app.sh`、codesign 检查和最后启动顺序。

4 个轻微问题集中在两个通用边界：公开改口成稿仍会残留已作废的“第二版”，未确认版本成稿仍会照抄“不要替我确定”这类幕后措辞且缺少自然的后续确认表达。下一批只处理 correction rendering 与 editor directive 的语义边界，不扩大到完整 130 条，也不据此接入生产。

### 10.10 完整核心集盲测与模型决策

25 条核心语义集完成双模型、隐藏模型名称的独立盲评，共产生 192 次真实 Provider 调用。解封模型映射后的结果为：

| 模型 | `direct_send` | `minor_edit` | `major_error` | `unusable` |
|---|---:|---:|---:|---:|
| `deepseek-v4-pro` | 23 | 1 | 1 | 0 |
| `deepseek-v4-flash` | 19 | 2 | 1 | 3 |

Pro 的一次成稿率为 92%，`direct_send + minor_edit` 为 96%；Flash 分别为 76% 和 84%。这证明模型选择确实影响成功率，但 Flash 的安全退出与两种模型各自出现的语义错误也再次证明：不能用单纯换模型代替证据清单、冷 Reviewer 和确定性门禁。

生产链第一次 25 条真实跑测又给出了更直接的边界：用户选择 Flash 时，系统内部把 Planner 静默切到 Pro，连续 7 条请求在 51～59 秒内未得到成功响应；撤掉换模后仍有结构化 Planner 请求耗尽阶段预算。进一步对照发现，架构实验对这类 JSON 任务显式关闭 thinking，而生产 Ledger 使用 `.low` 实际开启了 thinking；Fast 成功响应大多只需 0.6～2 秒。模型确实影响质量与延迟，但隐藏换模和不必要的推理开关都会制造日常 1K 文本失败。因此正式链路始终尊重用户当前模型，并对 Planner、Writer、Reviewer、Repair 的来源约束 JSON 任务关闭 thinking；“冷 Reviewer”只表示隔离调用和独立 Prompt，不再暗中改用另一模型。模型能力不足时由确定性门禁和显式失败兜底，而不是替用户做不可见的模型选择。

## 11. 历史生产候选记录（2026-08-18）

本节保留旧候选的代码、实验规模和结果，供追溯使用。以下路由、预算、Prompt 版本和测试数字均属于当时状态，不是当前三档候选的运行策略或验收结论；本轮实现与停止线以第 1～9 节为准。

用户于 2026-08-18 补充确认：日常长文本一般约 1,000 字，6K 并非常规输入。当时的生产候选让 80 字以下继续走一次 Fast 成稿与本地硬门禁，80～279 字仅在出现改口、上下文实体、显式结构等风险时升级 Ledger，280～1,800 字统一走 Ledger 主链；6K/8K 曾作为旧有界分片链路的压力边界。此处仅保留历史策略，不安排本轮超长测试。

当时生产候选的实现与测试记录：

1. `Evidence spans → typed Intent Ledger → structured Writer → cold Reviewer → targeted Repair → Confirm` 正式接入 `VoicePolishPipeline`；
2. 每个 Writer fragment 必须绑定交付 unit，确定性门禁检查来源事实、收件人、任务层、上下文映射、条件 cue、技术映射、文本完整度和仍未清理的高置信口述残片；
3. 单次运行共享 120 秒总预算，自动调用最多 6 次，Repair 只改 Reviewer 指向的 fragment；
4. Ledger 不读取原始安全上下文，只接收由本地 `EntityResolver` 证明的 canonical mapping；excluded/style/editor 内容不会反向强制写回正文；
5. 失败不再静默注入原文。Session 保留当前转写供用户重新润色；Esc取消当前输入，重试成功后才交付结果；
6. Prompt v25 已把条件方向固化为本地 `operator_kind`（区分 `only_if` 与 `if_then`）。技术断词与口述符号不再信任 Planner 自报 mapping，而由本地从对应来源 span 机械推导；`Swift 6`、`Node 20` 等版本名不会被并写，路径与命令 canonical 也不能跨 span 扇出。普通数字允许中文与阿拉伯数字互换，但不得补原文没有的量词、单位或币种；
7. 质量 Runner 已把“预算调用尝试”与“成功 Provider 调用”分开记录：超时或本地失败仍计入尝试次数，但只有完成 HTTP 200 解析并落盘审计回执的请求才计入成功调用，避免把正常超时误报为审计链路丢失；
8. 约 1K 多约束文本的 Planner 与唯一一次 Planner Repair 使用 8,192 token 受控输出预算；初次瞬时网络失败与 schema repair 共用一个恢复槽，任何路径总尝试仍不超过 6 次，不切换用户选择的模型；
9. Reviewer 可用 `wrong_role` 明确阻断 Planner 将真实收件人正文误标为编辑指令、排除内容或删除项；这种错误只能进入有证据的局部修复或显式失败，不能因为每个 source span 都“形式上被引用”而假装润色成功；
10. 冻结候选 `bfa249a` 已完成 25/25 核心集，48 次成功 Provider 调用与 48 条外部回执一一对应；19 条生成合格成稿，6 条显式失败，没有把原文或不合格草稿伪装成润色成功。失败集中在技术 mapping 顺序、普通数字格式化、同段反向改口、AI Prompt 编辑指令和近 8K 压力样本的跨片旧值处置；
11. 针对这 6 条，Prompt v25 与本地证据层改为：忽略模型自报技术 mapping 并从来源机械推导；把无单位中文数字安全格式化为等值裸数字；只在同一 segment 有明确历史与取消证据时接受反向改口；把“先别开始研究，只整理任务”从 AI Prompt 收件人结构中移除；用明确对象“课程资料复核轮次不对”跨过无关的“最终决定”字样，精确作废三轮，同时保留其他仍有效的数字 3。该轮 46 项 Ledger、57 项 Core 与 3 项参考链，共 106 项定向回归全部通过；全量 Swift 测试 1,265 项通过、6 项条件跳过、0 失败。当时仍须完成全新签名候选与真实核心集复测后才能判断该轮是否收口。

该轮记录的停止线如下；本轮当前停止线见第 9 节：

1. 从冻结提交打包未安装签名候选；
2. 先跑不超过 1,000 字的无答案核心回归集，经正式 Swift 生产链路核对 Provider 回执、所选模型一致性、显式失败与逐条语义质量；
3. 核心集通过后再运行不超过 1,000 字的完整验收子集；
4. 最终由未参与实现的独立 Agent 复核冻结提交、候选、真实 Provider 输出和人工评分；
5. 独立 Agent 未明确通过时，L15 保持进行中，不安装候选，也不声称完成。


v9只纠正轻度职责范围，标准生成及两类复核提示保持与v8逐字相同。新的轻度范围补充独立保存，历史契约与评级不变；v9已通过179定向、1577全量（8跳过0失败）、Debug/Release与独立审查，但真实轻度20条仍有7条轻改，产品质量未通过。标准完整成稿基线6次为2直接/4轻改；后续6次段落修正均空补丁，没有收益。

同一c01c219隔离探针完成[轻度完整文本请求实验](../build/2026-09-10-three-mode-implementation/light-fulltext-experiment-05/unblinded-comparison.md)，20次请求后独立判读为原13条11直接/2轻改、额外7条全直接。初始盲包遗漏实际source_segments，在初始评分冻结后追加完整来源并另存判读；长例的四处指代连属仍未决。它同时改变任务表达与输出方式等条件，不能当纯格式因果结论或正式管线验收。

v10据此接入轻度完整候选：低风险且严格机械变化可直接输出；其他情况须用原文局部证据核对完整目标稿，并证明剩余差异只含机械变化。目标稿有修复时第三次确认实际修后稿。编辑权限不放宽，不由通用diff猜语义证据，继续20秒/最多三调用。运行检查发现并修复700字递归匹配栈溢出；1609全量（8条件跳过、0失败）、Debug/Release、183项Python、33份旧报告202条回放及独立复核通过。随后须重新跑同组20条正式生产链路；标准提示与路由保持，完整验收及真实录音尚未完成。

轻度后续真实评分采用已独立批准的[范围补充](../build/2026-09-10-three-mode-implementation/light-scope-v2/2026-09-11-Dal-轻度范围验收补充.md)，绑定JSON SHA `f7d6ebf7f941d5f842a7bdf3d5078a0c03fa35c28ec170d966e33719467f2fbf`；[独立批准记录](../build/2026-09-10-three-mode-implementation/light-scope-v2/independent-light-scope-review-2026-09-11.md)说明依据与不变的事实门槛。原13与补充7分开报告，不能重评旧结果后声称代码改善。
