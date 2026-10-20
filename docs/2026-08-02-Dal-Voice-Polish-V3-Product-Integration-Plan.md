# Dal 语音润色 V3 产品整合实施方案

文档状态：工程主体已实施；真实线上指标与同音频人工盲测待验收

适用仓库：`DaliangPro/Dal`

编制日期：2026-08-02

前序记录：`docs/2026-07-31-Dal-Voice-Polish-V2-Implementation-Plan.md`

目标：在保留现有输入模式、用户可编辑 Prompt、ASR/LLM Provider、快捷键、历史记录和文本注入能力的前提下，把 Voice Polish V2 已完成的工程能力整合成用户可发现、可理解、会学习、低等待感的完整产品。

当前实施结论（2026-08-02）：L4–L7 的代码、确定性测试和界面整合已完成；普通模式与 Voice Polish 已共用 canonical 术语纠正，并按录音开始时冻结的应用作用域隔离。L8 的 Prompt、路由、Provider 能力适配、阶段反馈、诊断、canonical 退出和真实分母性能看板已完成。L9 的评测工具已收紧真实音频、证据防篡改、类别覆盖与匿名随机门槛，但真实请求率/延迟指标及 100 条同音频 Typeless 人工盲测尚未执行，因此当前只确认工程主体完成，不声明“已经比肩 Typeless”。

---

## 0. 最终结论

V3 不是 Dal 全量重写，也不推翻现有输入模式架构。

V3 只重构 Voice Polish 周围的四个边界：

1. **术语边界**：个人词典、实体类热词和实体类错词纠正合并为一个事实来源。
2. **处理边界**：原始识别、确定性术语纠正、LLM 成稿和结果校验职责分离。
3. **产品边界**：术语、润色设置、纠正学习和真实链路测试拥有明确入口。
4. **性能边界**：默认一次 LLM 成稿；Deep 只处理真正复杂的表达。

以下能力明确保留：

- `ProcessingKind` 与现有输入模式体系。
- Voice Polish 独立管线和安全回退。
- 用户自由编辑 `mode.prompt`。
- 自定义输入模式和各模式独立 Prompt。
- 当前 ASR、LLM Provider 与模型配置。
- 快捷键、历史记录、试跑、文本注入和原文保底。
- 现有热词、Snippet、PersonalLexicon 和纠正记录数据。

用户 Prompt 的定位保持不变：它继续控制语气、简洁度、格式和个人表达要求；专有名词正确性、事实保护、隐私与安全回退由系统负责。

---

## 1. 当前产品问题

### 1.1 同一项能力存在三个入口和三个数据源

当前用户面对：

- `常用词 → 识别热词`
- `常用词 → 错词纠正`
- `输入模式 → 语音润色 → 润色设置 → 个人词典`

对应三个文件：

- `hotwords.json`
- `snippets.json`
- `voice-polish-lexicon.json`

`PersonalLexiconStorage` 保存后又把 canonical 复制到 HotwordStorage、把 aliases 复制到 SnippetStorage。这是同步，不是统一事实来源，会产生入口割裂、删除后复活、反向修改不同步和作用域不清等问题。

### 1.2 Voice Polish 丢弃了已经执行的完整错词纠正结果

`RecognitionSession.postProcessRecognizedText` 先执行 `SnippetStorage.applyEffective(to:)`，进入 Voice Polish 分支后又把 `finalText` 重置为 `rawText`。随后 `EntityResolver` 只读取用户 snippets，而不是完整 effective snippets。

结果可能是：普通模式能命中的内置纠正规则，在 Voice Polish 中失效。

### 1.3 实体解析无法覆盖典型语音错词

当前 `EntityResolver` 的主要限制：

- 只按空格和标点切 token。
- 不做跨 token 字符范围匹配。
- 不统一内部空格、常见连字符和大小写变体。
- 主要依赖固定编辑距离阈值。
- 不具备英文发音或中文拼音通道。
- 低置信实体只能保留原文，LLM 又被禁止开放式猜测。

因此 `Type less → Typeless`、`type list → Typeless`、中文音译或错词嵌入连续中文句子时都可能失败。

### 1.4 明确纠正不能立即形成术语

当前词典候选算法要求：

- 纠正前后 token 数量相同。
- 同一映射至少出现两次。

这会直接跳过 `Type less` 两个 token 改成 `Typeless` 一个 token 的典型情况。用户已经明确确认的纠正还要重复出现，违背“纠正一次、下次变好”的产品预期。

### 1.5 上下文能力被高估但没有被解释清楚

默认上下文为 `metadataOnly`。正文授权后读取的仍只是：

- 当前焦点输入控件的选中文本；或
- 当前输入控件光标前后各最多 400 字。

它不等于完整 ChatGPT、Codex 或网页会话历史，WebArea 和未知控件默认也不会读取正文。UI 必须如实表达这一边界。

### 1.6 Prompt 偏重安全，缺少正向成稿标准

V2 已建立事实安全、改口处理和结构化校验，但 Prompt 对以下目标定义不足：

- 像用户认真打字后的成品。
- 主动修复口语句法和拖沓表达。
- 根据聊天、工作沟通、邮件、AI Prompt 等场景调整表达。
- 在不扩写事实的前提下，让内容清晰、自然、可直接发送。

结果可能“安全但不够好写”。

### 1.7 默认路径容易进入多次串行调用

当前 Balanced 可能因长度、多个 segment、一次改口等进入 Structured；Deep 会串行执行 Analyze、Render，必要时再 Repair，且 Render 再次嵌套完整原 Payload。

这会同时增加：

- 首字等待时间。
- 输入 token。
- JSON 失败和 Repair 概率。
- 用户对“润色中”无反馈等待的焦虑。

### 1.8 核心设置不可发现且可能不可达

Voice Polish 设置只在选中该模式时显示小按钮。该模式当前可删除，而 ModeStorage 只保证真正的内置模式恢复；删除后可能连设置入口一起失去。

### 1.9 当前试跑不能复现真实问题

文字试跑不经过麦克风和 ASR，且默认场景、正文上下文与正式链路不同。它不能验证：

- ASR 实际把专有名词识别成什么。
- 术语纠正是否命中。
- 当前应用上下文是否可用。
- 从停止录音到完成注入的总耗时。

---

## 2. 产品目标与非目标

### 2.1 产品目标

用户只需形成一个心智：

> 识别错了，纠正一次；Dal 会明确告诉我记住了什么，并在下一次的识别、纠错和润色三个环节共同生效。

目标体验：

1. 添加一个 `Typeless` 术语，自动服务全部相关链路。
2. 用户纠正一次 `Type less → Typeless`，下一次确定命中。
3. 普通短输入默认一次 LLM 调用，快速生成可发送成稿。
4. 用户继续自由编辑附加润色要求。
5. 用户能看到本次使用了什么术语、上下文、路由以及耗时。
6. 系统不能为了“聪明”而开放式猜测人名、品牌和项目名。

### 2.2 明确非目标

本方案不包含：

- 重写 Dal 全部输入模式。
- 取消或限制用户自定义 Prompt。
- 自动监控用户在目标 App 中的后续编辑。
- 默认抓取完整网页、聊天历史、联系人、文件系统或网络搜索结果。
- 新增 ASR 厂商或替换现有 Provider。
- 把整句快捷替换发送给 ASR 当热词。
- 为追求速度取消事实校验和原文回退。
- 删除真实用户旧数据或手工修改 `~/Library/Application Support/Muse/`。

---

## 3. 目标信息架构

### 3.1 设置侧栏

建议顺序：

```text
概览与记录
语料资产
术语与纠错
语音润色
输入模式
模型配置
关于
```

“常用词”改名为“术语与纠错”。“语音润色”成为一级页面，不再依赖模式选择后的小弹窗。

### 3.2 术语与纠错页面

页面包含四个区域：

#### A. 我的术语

每个词条表现为一个完整对象：

```text
标准写法：Typeless
可能识别成：Type less、Type list、泰普勒斯
状态：已启用
来源：手动添加 / 从纠正中记住
生效范围：识别增强、自动纠正、语音润色
```

默认不暴露 Provider 技术细节。展开“生效状态”后可看到：

- ASR 已接收热词。
- Provider 不支持请求级热词，已使用本地纠正兜底。
- Voice Polish 实体保护已启用。
- 同步失败及可执行修复动作。

#### B. 待确认发现

展示自动发现但尚未由用户确认的术语候选：

- 错误写法 → 建议标准写法。
- 证据次数和最近出现时间。
- 确认、编辑后确认、忽略。
- alias 冲突时显示两个候选，禁止静默覆盖。

自动推断候选可以要求多次证据；用户在“纠正”流程中明确确认的映射只需一次。

#### C. 固定替换

保留现有 Snippet 能力，用于：

- 邮箱、地址和固定短语。
- 整句快捷替换。
- 不适合作为 ASR 术语的宽泛规则。

固定替换与术语在数据和执行上保持分离。

#### D. 内置术语

只读展示 Dal 内置的技术词和常见错听形式。允许单项停用，不直接修改内置资源文件。

### 3.3 语音润色页面

页面按用户价值排序：

1. **我的附加润色要求**
   - 继续编辑现有 `mode.prompt`。
   - 明确说明它控制语气、简洁度和格式。
   - 支持恢复默认和文字预览。

2. **响应方式**
   - 快速。
   - 标准（推荐）。
   - 深度整理。
   - 文案只解释适用场景和等待差异，不展示 Structured/Deep 等工程术语。

3. **上下文**
   - 不读取正文。
   - 只参考用户选中的文字。
   - 参考当前输入框附近文字。
   - 可选“参考 Dal 在当前应用中的最近输入”。
   - 显示当前应用本次是否支持、实际捕获类型和隐私说明。

4. **学习我的表达**
   - 与术语学习分开授权。
   - 显示学习样本数、当前偏好摘要、纠正记录管理和重置。

5. **模型与速度**
   - 默认跟随全局 LLM。
   - 可选 Voice Polish 专用快速模型。
   - 显示最近 P50/P95、回退率和 Repair 率，只有足够样本时才展示统计。

6. **真实链路测试**
   - 文字测试：只验证 LLM 成稿。
   - 麦克风测试：验证 ASR → 术语 → 上下文 → LLM → 校验的完整链路。

### 3.4 输入模式页面的职责

输入模式继续负责：

- 模式选择。
- 快捷键和按键方式。
- 自定义模式 Prompt。

官方 Voice Polish 的附加要求在“语音润色”一级页面作为唯一编辑入口；输入模式中的 Voice Polish 详情展示摘要和“前往语音润色设置”链接，避免两个编辑器产生入口冲突。

Voice Polish 改为官方系统模式：可以关闭快捷键或隐藏，但不能删除其稳定 ID、设置和学习数据。

---

## 4. Prompt 架构

V3 保留用户自由编辑 Prompt，并明确分成四层：

```text
Dal 核心安全规则
  ↓
Voice Polish 默认成稿策略
  ↓
场景、术语与授权上下文
  ↓
用户附加润色要求（现有 mode.prompt）
```

### 4.1 Dal 核心安全规则

不可由用户 Prompt 覆盖：

- 保留最终事实、数字、日期、金额、版本和受保护实体。
- 明确改口以最终确认版本为准。
- 不凭空增加事实、理由、承诺或结论。
- 不读取未授权正文。
- 失败时返回安全 canonical transcript。

### 4.2 默认成稿策略

版本化维护以下正向目标：

- 输出像用户认真打字后的成品。
- 删除无意义停顿和机械重复。
- 修复口语句法、拖沓和断裂表达。
- 保留用户态度、力度和个人声音。
- 不把长内容压缩成摘要。
- 只有原文确有枚举关系时使用列表。
- 根据应用场景调整正式度、段落和节奏。
- 输出可直接发送，不附加解释。

### 4.3 场景、术语与上下文

作为结构化数据字段传入，不拼接到用户 Prompt：

- `required_entity_edits`：本地已确认，模型必须执行。
- `allowed_entity_candidates`：来自用户术语或授权上下文，模型可在白名单内结合语义选择。
- `unknown_entities`：禁止开放式猜测。
- `writing_scene`：聊天、工作沟通、邮件、AI Prompt 等。
- `authorized_context`：只包含本次授权允许的数据。

### 4.4 用户附加润色要求

继续允许用户自由表达：

- “更口语化，但不要油腻。”
- “尽量简短，不要随便列点。”
- “工作消息保持直接、友好。”
- “保留我的措辞，不要过度改写。”

用户已有自定义内容原样保留，不迁移、不重写、不静默恢复默认。

---

## 5. 统一术语架构

### 5.1 单一事实来源

新增 `TerminologyRepository`，成为用户术语的唯一事实来源。

建议模型：

```swift
struct TerminologyEntry: Identifiable, Codable, Sendable {
    let id: UUID
    var canonicalText: String
    var aliases: [TerminologyAlias]
    var isEnabled: Bool
    var origin: TerminologyOrigin
    var scope: TerminologyScope
    var createdAt: Date
    var updatedAt: Date
}

struct TerminologyAlias: Codable, Sendable {
    var text: String
    var source: TerminologyAliasSource
    var evidenceCount: Int
    var lastSeenAt: Date?
}
```

首版 `scope` 至少支持全局；按应用作用域可以先保留模型字段、后续开放 UI，不应阻塞本轮核心闭环。

### 5.2 三种运行时投影

统一词条不是让底层只剩一个算法，而是由同一数据源生成三种投影：

```text
TerminologyRepository
├─ ASRHotwordProjection
│  └─ canonicalText
├─ DeterministicCorrectionProjection
│  └─ alias → canonicalText
└─ VoicePolishEntityProjection
   └─ canonical、aliases、来源、置信度和证据
```

用户只维护一次，底层在不同处理阶段使用不同投影。

### 5.3 固定替换保持独立

以下规则不进入术语库：

- 整句替换。
- 带换行的模板。
- 邮箱、地址和长文本快捷输入。
- 宽泛匹配或可能误伤普通语句的规则。

这些内容继续由 `SnippetStorage` 或后续 `FixedReplacementRepository` 管理。

### 5.4 Provider 能力适配

新增可审计的 ASR 术语能力：

```swift
struct ASRTerminologyCapabilities {
    let supportsRequestHotwords: Bool
    let supportsAliasCorrections: Bool
    let supportsRemoteVocabularySync: Bool
    let requiresLocalCorrectionFallback: Bool
}
```

无论 Provider 是否支持热词或 correction words，本地确定性纠正都作为最终一致性兜底。

---

## 6. 术语匹配与 Voice Polish 正式链路

### 6.1 新链路

```text
ASR 原始 Transcript
  ↓
TerminologyMatcher
  ├─ 原始 segments（审计与回退证据）
  └─ canonical segments（正式成稿输入）
  ↓
WritingContextEnvelope
  ↓
VoicePolishComplexityRouter
  ↓
VoicePolishPipeline
  ↓
事实校验 + 实体白名单校验
  ↓
文本注入或 canonical transcript 回退
```

任何路径都同时保留 raw 与 canonical 版本，不能为了纠正术语丢失原始证据。

### 6.2 确定性匹配优先级

1. 用户明确确认的 exact alias。
2. 用户手动术语的 canonical 和 alias。
3. 内置术语 exact alias。
4. 授权上下文中出现的 exact canonical。
5. 白名单内的高置信模糊候选。

同一 alias 指向多个 canonical 时禁止自动替换，进入待确认冲突。

### 6.3 匹配能力

必须支持：

- Unicode 兼容规范化仅用于比较。
- 大小写、全半角、内部空格和常见连字符变体。
- 基于字符范围的跨 token 滑动窗口。
- 英文编辑距离与发音相似度分通道评分。
- 中文拼音或音节相似度分通道评分。
- 连续中文句子内的英文/音译片段识别。
- 来源优先级、绝对阈值与候选领先幅度。
- 返回字符范围，避免全局字符串替换造成误伤。

低置信候选只进入 `allowed_entity_candidates` 或待确认发现，不自动修改正文。

### 6.4 Validator 规则

- `required_entity_edits` 未执行：Hard Fail。
- 输出出现白名单外的新实体：Hard Fail。
- 多个允许候选之间选择：必须有上下文证据和最低置信度。
- 未知实体保持原表述：允许。
- canonical fallback 必须保留已确认的确定性术语修正。

---

## 7. 纠正与学习闭环

### 7.1 入口

Voice Polish 历史行显示：

- “语音润色”徽标。
- 明确文字按钮“纠正”。
- 已纠正状态和撤销入口。

浮动条完成状态可以提供短时“纠正结果”入口，但不得阻塞正常注入。

### 7.2 确认界面

用户编辑最终结果后，本地 diff 提取：

- 术语变化。
- 风格变化。
- 结构变化。

界面分开确认：

```text
检测到术语修改：Type less → Typeless
[✓] 以后自动纠正

[ ] 同时学习我的表达习惯
```

术语记忆与风格学习是两个独立授权，不再互相依赖。

### 7.3 学习规则

- 用户明确勾选并确认：一次立即写入术语库。
- 自动发现但未确认：至少两次独立证据后进入待确认列表。
- diff 使用字符范围或序列对齐，支持一对多、多对一和中英混排。
- 不要求纠正前后 token 数量相同。
- 不监控目标 App 的后续编辑。
- 每次学习都可查看、编辑、撤销和导出。

### 7.4 完成反馈

确认后明确提示：

> 已记住 Typeless。下次将同时用于识别增强、自动纠正和语音润色。

不得只显示“保存成功”而不说明学到了什么、在哪里生效。

---

## 8. 上下文设计

### 8.1 保留现有隐私底线

- 默认仍为 metadata only。
- secure、unknown、WebArea 和读取失败时不读取正文。
- 不读取剪贴板。
- 日志只记录上下文类型和字符数量，不记录正文。
- 用户关闭授权后，后续请求立即停止携带相应正文。

### 8.2 UI 如实区分四种上下文

1. 应用与控件场景。
2. 用户明确选中的文字。
3. 当前输入框光标附近文字。
4. Dal 自己在当前应用中的近期输入。

“附近文字”不得描述成“完整聊天上下文”。

### 8.3 Dal 近期输入

为了支持连续表达中的术语和指代，可增加本地短期上下文：

- 只保存 Dal 自己最近完成的输入，不抓取第三方页面内容。
- 按应用或可确认的窗口标识隔离。
- 默认仅驻留内存，不写历史正文副本。
- 数量和时效均有上限，例如最近 3 次或 15 分钟。
- UI 可关闭，并显示本次是否使用。

这能帮助同一应用中连续出现 `Typeless`，但不能替代完整对话读取。完整第三方会话适配不属于本方案。

---

## 9. 成稿质量与性能重构

### 9.1 用户档位

| 用户档位 | 适用场景 | 默认调用策略 |
|---|---|---|
| 快速 | 短句、即时聊天 | 一次纯文本成稿 |
| 标准（推荐） | 大多数消息、邮件和 Prompt | 一次轻量结构化成稿；只有 Hard Fail 才允许一次 Repair |
| 深度整理 | 多次跨段改口、乱序、多主题、明确排除 | Analyze + Render；最多一次 Repair |

UI 不显示 Fast/Structured/Deep 内部名，只在诊断中显示。

### 9.2 路由调整

以下因素本身不得单独触发 Deep：

- 单纯文字较长。
- Provider 把同一句切成多个 segment。
- 一次普通即时改口。
- 一个简单列表。

Deep 只由真正需要跨段规划的信号触发：

- 两次以上或延迟改口。
- 多主题乱序。
- 明确排除型旁注。
- 数量和最终决定存在跨段冲突。
- 复杂 AI Prompt 同时存在多类约束。

### 9.3 请求瘦身

- 不同时重复发送 segments、provider final、punctuated text 的等价全文。
- Render 只接收必要原文片段、已验证 Plan、事实和实体，不再嵌套完整原 Payload 字符串。
- 按 Provider 能力真正启用 JSON Mode、低 temperature 和输出 token 上限。
- Fast、标准和 Render 关闭推理；只有 Deep Analyzer 可按能力开启低档推理。
- Voice Polish 可选择专用快速模型，默认仍跟随全局配置。

### 9.4 可提前完成但不提前猜正文的工作

录音期间允许并行：

- 捕获元数据和已授权上下文。
- 加载模型配置和能力缓存。
- 加载术语投影。
- 预热网络连接或本地模型。

不得在 final transcript 形成前发送会产生正文的 speculative Voice Polish 请求。

### 9.5 等待反馈

HUD 最少显示：

- 正在识别。
- 正在纠正术语。
- 正在生成文本。
- 正在安全检查。
- 已等待时间。

超过产品阈值后提供“立即使用识别结果”。该结果应为 canonical transcript，不是未纠正的 raw ASR 文本。

---

## 10. 数据迁移与兼容

### 10.1 迁移原则

- 不删除旧文件。
- 不手工修改真实用户目录。
- 使用 App 内版本化迁移器和独立 manifest。
- 迁移失败不推进 schema version，也不覆盖恢复源。
- 迁移前后支持导出和回滚。

真实用户数据结构迁移在实施前仍须按项目规则取得单独授权。

### 10.2 导入来源

首次迁移只读导入：

1. PersonalLexicon canonical + aliases。
2. 用户 Snippet 中符合实体条件的短映射。
3. 用户 Hotword 中尚未存在的 canonical。
4. 内置短实体映射作为只读内置术语。

不符合实体条件的 Snippet 保留在固定替换。

### 10.3 冲突优先级

```text
用户明确确认的术语
> 用户手动 PersonalLexicon
> 用户错词纠正
> 用户热词
> 内置术语
> 授权上下文候选
```

同一 alias 指向不同 canonical 时进入冲突列表，禁止静默覆盖。

### 10.4 兼容窗口

至少保留一个稳定版本的 read-through + dual-write：

- 新 Repository 是 UI 和运行时主入口。
- 继续投影到旧 HotwordStorage 和 SnippetStorage，保证现有 ASR 服务兼容。
- PersonalLexiconStorage 变为兼容适配器，不再作为独立 UI 数据源。
- 验证稳定后停止旧数据写入，但仍保留只读回滚能力。

### 10.5 Prompt 与模式迁移

- 用户 `mode.prompt` 原样保留。
- Voice Polish 稳定 ID 保留。
- 快捷键和按键方式保留。
- Voice Polish 从可删除模式升级为系统模式时，只改变删除策略，不改变用户配置。

---

## 11. 分期实施

实现前必须把以下任务补入 `REPAIR_PLAN.md`，建议编号 L4–L9；每卡按项目规则认领、验证、销账和原子提交。

### L4：修复当前正确性断点

范围：

1. Voice Polish 不再丢弃 `SnippetStorage.applyEffective` 的有效结果。
2. 对每个 segment 生成 raw 与 canonical 两份表示。
3. Voice Polish 使用完整 built-in + user terminology/correction 结果。
4. Fallback 返回 canonical transcript。
5. 修复 exact alias 的大小写、空格、跨 token 与字符范围匹配。
6. 修复一对多、多对一纠正无法提取的问题。
7. Voice Polish 稳定 ID 不可删除，或删除后必定恢复且设置入口永久可达。

验收：

- 已知 exact alias 纠正率 100%。
- `Type less / type list / TypeLess → Typeless` 表驱动测试全部通过。
- 普通模式与 Voice Polish 使用相同的确定性纠正结果。
- LLM 失败时仍输出已纠正的 canonical transcript。
- 其他模式零回归。

### L5：建立统一术语 Repository 与迁移器

范围：

1. 建立 TerminologyEntry、Repository、Matcher 和三种 Projection。
2. 分类导入 PersonalLexicon、Hotword、Snippet 和内置规则。
3. 建立冲突列表、manifest、read-through 和 dual-write。
4. 增加 ASR 术语能力描述和本地兜底。
5. PersonalLexiconStorage 降级为兼容适配器。

验收：

- 非破坏迁移与幂等迁移测试通过。
- 同一数据重复迁移不产生重复词条。
- 冲突不静默覆盖。
- 迁移失败不推进版本号、不损坏旧文件。
- 各 ASR Provider 的最终本地纠正结果一致。

### L6：重构前端信息架构

范围：

1. “常用词”升级为“术语与纠错”。
2. 新增“我的术语、待确认发现、固定替换、内置术语”。
3. 新增一级“语音润色”页面。
4. 把附加润色要求、响应方式、上下文、学习、模型与测试集中呈现。
5. 输入模式中的 Voice Polish 只保留快捷键和设置跳转。
6. 补空状态、冲突、同步失败、Provider 不支持、保存成功和撤销状态。

验收：

- 用户不进入输入模式也能找到术语和语音润色设置。
- 添加 `Typeless` 一次即可看到三个生效位置。
- 所有按钮支持键盘操作、VoiceOver 标签和明暗模式。
- 文字试跑明确标注“不包含语音识别”。

### L7：打通纠正学习与安全上下文

范围：

1. 历史行增加明确“纠正”按钮和模式徽标。
2. 术语学习与风格学习拆成独立确认项。
3. 用户明确确认后一次写入术语库。
4. 自动候选继续使用多证据门槛。
5. 增加可查看、编辑、撤销和导出。
6. 增加可选的 Dal 近期输入内存上下文。
7. UI 如实显示本次上下文类型和可用状态。

验收：

- `Type less → Typeless` 一次确认后下一次立即生效。
- 关闭风格学习不影响术语记忆。
- 关闭术语记忆不采集术语映射。
- 不监控目标 App 后续编辑。
- 近期输入不跨应用泄漏、不默认持久化。

### L8：提升成稿质量与速度

范围：

1. Prompt 升级为“安全核心 + 正向成稿策略 + 场景 + 用户附加要求”。
2. 补聊天、工作沟通、邮件、AI Prompt 等场景规则和 few-shot。
3. 标准档默认一次轻量请求。
4. Deep 移除单纯长度和 segment 数触发。
5. Render Payload 去重。
6. 真正按能力启用 JSON Mode、temperature、token 限制和 reasoning control。
7. 支持 Voice Polish 专用快速模型。
8. 增加阶段耗时、TTFT、Repair 和 fallback 诊断，不记录正文。
9. HUD 增加阶段、等待时间和 canonical 原文出口。

验收目标：

- 至少 85% 的真实请求只调用一次 LLM。
- Repair 触发率不高于 2%。
- 超时或 fallback 不高于 1%。
- Fast：停止录音到完成注入 P50 ≤ 1.5 秒、P95 ≤ 3 秒。
- 标准：P50 ≤ 2.5 秒、P95 ≤ 5 秒。
- Deep：P50 ≤ 5 秒、P95 ≤ 8 秒。

上述是发布目标，不是当前已经达到的数据。未完成真实测量时不得声称通过。

### L9：真实评测、部署与产品验收

范围：

1. 建立至少 100 条真实同音频样本，覆盖专名、改口、旁注、乱序、列表、数字、中英混排和 AI Prompt。
2. 同一音频分别运行 Dal 与 Typeless。
3. 输出匿名随机左右排列。
4. 记录质量、专名、事实、可发送程度和延迟。
5. 执行 Debug/Release 构建、全量测试、健康检查、打包部署和签名核验。

产品验收目标：

- 已确认 alias 的确定性纠正率 100%。
- 白名单外实体幻觉 0。
- 关键数字、日期、金额、版本保留率 100%。
- Dal 在人工盲测中的获胜或打平比例 ≥ 85%。
- Dal 明显落后比例 ≤ 15%。
- 双方都不可用比例 ≤ 1%。

工程实现完成与产品效果验收必须分开记录。没有 Live Provider 和人工盲测结果时，只能声明工程完成，不能声明“比肩 Typeless”。

---

## 12. 测试策略

### 12.1 Terminology 单元测试

- canonical/alias 清理、去重和大小写规则。
- exact alias、跨 token、连字符和内部空格。
- 中英混排与连续中文片段。
- 英文发音、拼音候选和歧义保留。
- 同 alias 多 canonical 冲突。
- 字符范围替换不误伤其他相同子串。
- 固定替换不会进入热词投影。
- Provider 能力和本地兜底。

### 12.2 迁移测试

- 只有 PersonalLexicon。
- 只有 user hotwords。
- 只有 user snippets。
- 三者重复。
- 同 alias 冲突。
- 损坏文件和恢复文件。
- 中途失败、再次启动和幂等重试。
- 旧版本回读兼容。

### 12.3 Pipeline 测试

- raw/canonical segments 同时保留。
- canonical transcript 进入 LLM。
- required entity edit 必须执行。
- allowed candidate 只能在白名单内选择。
- 未知实体不猜测。
- LLM 失败回退 canonical transcript。
- Fast/标准/Deep 调用预算。
- Payload 不重复携带等价全文。
- Provider JSON/Reasoning 能力降级。

### 12.4 学习测试

- 一对一、一对多、多对一。
- `Type less → Typeless`。
- 中文音译 → 英文品牌。
- 明确确认一次立即生效。
- 未确认候选不自动写入。
- 术语与风格授权互不依赖。
- 撤销后 Projection 同步更新。

### 12.5 UI 与可访问性测试

- 从侧栏直接进入术语与 Voice Polish。
- 空、加载、成功、失败、冲突、部分同步状态。
- 键盘导航、VoiceOver、焦点和明暗模式。
- Voice Polish 模式不可误删。
- 文字测试与麦克风测试边界说明。
- HUD 超时原文出口。

### 12.6 回归测试

- Direct、Smart Direct、Translate、Prompt Optimize、Command 和 Custom。
- 当前快捷键和按键方式。
- ASR streaming/batch fallback。
- 历史保存、复制、删除和注入。
- 用户自定义 Prompt 原样保留。
- Thinking 探测和 Provider 配置。

---

## 13. 建议文件边界

建议新增：

```text
Dal/Terminology/TerminologyModels.swift
Dal/Terminology/TerminologyRepository.swift
Dal/Terminology/TerminologyMatcher.swift
Dal/Terminology/TerminologyProjections.swift
Dal/Terminology/TerminologyMigration.swift
Dal/Terminology/ASRTerminologyCapabilities.swift

Dal/UI/Settings/TerminologySettingsTab.swift
Dal/UI/Settings/VoicePolishSettingsTab.swift
Dal/UI/Settings/TerminologyCorrectionComponents.swift
```

建议修改：

```text
Dal/Session/RecognitionSession.swift
Dal/VoicePolish/EntityResolver.swift
Dal/VoicePolish/PersonalLexicon.swift
Dal/VoicePolish/VoicePolishLearning.swift
Dal/VoicePolish/VoicePolishPrompts.swift
Dal/VoicePolish/VoicePolishComplexityRouter.swift
Dal/VoicePolish/VoicePolishPipeline.swift
Dal/VoicePolish/VoicePolishValidator.swift
Dal/VoicePolish/WritingContextCapture.swift

Dal/Services/HotwordStorage.swift
Dal/Services/SnippetStorage.swift
Dal/Services/ModeStorage.swift

Dal/UI/Settings/SettingsTab.swift
Dal/UI/Settings/VocabularyTab.swift
Dal/UI/Settings/ModesSettingsTab.swift
Dal/UI/Settings/VoicePolishSettingsSheet.swift
Dal/UI/Settings/VoicePolishCorrectionSheet.swift
Dal/UI/Settings/ModeTrialCard.swift
Dal/UI/Settings/GeneralRecentHistorySection.swift
Dal/UI/FloatingBar/FloatingBarView.swift
```

文件名是职责建议，不是必须机械照搬。优先复用现有组件，避免为了“新架构”制造空壳层。

---

## 14. 发布与回滚

### 14.1 发布顺序

1. 先发布 L4 正确性修复，不等待 UI 全部重构。
2. L5 Repository 与迁移器通过后启用 dual-write。
3. L6/L7 UI 与学习闭环一起开放。
4. L8 性能策略先小样本真实观察，再设为默认。
5. L9 通过后才宣称 V3 产品验收完成。

### 14.2 回滚能力

- 旧数据文件保留。
- 迁移 manifest 可定位由新系统拥有的投影。
- 新 matcher 和新路由在观察期保留内部回退开关。
- 回滚不得删除用户在新版本新增的术语，应支持导出或反向投影。
- Prompt 和模式配置不参与不可逆迁移。

### 14.3 部署

按项目既有授权：相关测试、构建与真实必要检查通过后，可打包、复用现有签名、覆盖安装并重启 `/Applications/Dal.app`；仍须核验 Bundle、严格签名、进程和本次修复标识。

用户数据迁移、权限变化、系统设置和签名身份变化仍需单独授权。

---

## 15. 完成定义

### 15.1 工程完成

- L4–L8 任务卡全部销账。
- Debug/Release 构建、全量测试、健康检查通过。
- 数据迁移、冲突、回滚和 Provider 差异均有测试。
- 用户 Prompt、快捷键、历史和其他模式无回归。
- 已部署并完成签名与运行核验。

### 15.2 产品验收完成

- L9 真实同音频评测和人工盲测执行完毕。
- 专名、事实、成稿质量和延迟达到第 11 节目标。
- 用户能够在不理解技术术语的情况下完成“添加术语”和“纠正一次并记住”。
- 没有未关闭的 P0/P1 回归。

### 15.3 “比肩 Typeless”的声明边界

只有同时满足工程完成与产品验收，才能说 Dal Voice Polish 已在本方案定义的专名准确性、成稿质量、纠正学习和延迟指标上达到“比肩 Typeless”的目标。

没有同音频对照和盲测时，不得用内部测试数量代替产品效果结论。

---

## 16. 最终禁止事项

1. 禁止把 V3 简化成“再改一版 Prompt”。
2. 禁止删除或覆盖用户现有 Prompt。
3. 禁止让用户继续在三个页面重复维护同一个术语。
4. 禁止把所有 Snippet 无差别迁入术语库。
5. 禁止把整句固定替换发送给 ASR 当热词。
6. 禁止丢弃 raw transcript 或 canonical correction 证据。
7. 禁止在 LLM 失败时回退到未纠正的 raw ASR 文本。
8. 禁止让 LLM 在白名单外猜测专有名词。
9. 禁止因为单纯长度或 segment 数进入 Deep。
10. 禁止默认抓取完整聊天、网页、剪贴板或未知控件正文。
11. 禁止监控目标 App 中用户后续编辑来自动学习。
12. 禁止在日志中记录语音正文、上下文正文、术语内容或完整 Prompt。
13. 禁止在没有真实数据时声称延迟、回退率或盲测达标。
14. 禁止把工程完成写成“已经比肩 Typeless”。
15. 禁止在实施时绕过 `REPAIR_PLAN.md` 的认领、验证、销账和提交规则。
