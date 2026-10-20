# Dal 修复执行日志

## 执行基线

- 执行日期：2026-07-20（PDT）
- 审查基线：`7144781af818fd188eff0e67215b63deddcce660`
- 工作分支：`codex/dal-hardening-v1`
- 开始前工作区：仅有用户既有未跟踪文件 `CODEX_REPAIR_PLAN.md`；执行过程中不覆盖、不修改、不纳入提交。
- 真实用户数据目录：见下方 2026-07-21 审计更正；DAL-160 隔离修复完成后的测试不再触碰真实 Dal 目录或系统钥匙串。
- 自动更新开关：`UpdateChecker.updateChannelEnabled = false`，保持关闭。

### 2026-07-21 真实数据测试隔离审计更正

- DAL-160 期间静态审计发现，既有 `AssetExtractionLowValueFilterTests` 使用默认 `AssetExtractionService()`，会在此前完整测试中打开默认 `history.db` / `language-assets.db`；既有 `KeychainServiceTests` 会访问真实系统钥匙串、`credentials.json` 与标准 UserDefaults。
- 因而本日志在 DAL-160 之前各任务中“完整测试未访问真实用户数据”的表述不准确，以本更正为准。相关测试通常在 teardown 恢复临时写入，但未再次读取真实目录或钥匙串核验持久影响，实际影响无法确认。
- `b48b180` 已将低价值过滤测试改用内存数据库，并让 XCTest 下的 Keychain、遗留凭据 JSON、Provider 偏好和 debug log 使用进程内隔离；修复后的 467 项完整测试经独立静态复审，未发现默认路径继续访问真实 Dal 目录或系统钥匙串。

### 基线验证

| 命令 | 结果 |
|---|---|
| `swift build` | 通过；首次沙箱内尝试因 Swift/Clang 用户缓存无写权限失败，获准在真实环境重跑后通过。 |
| `swift test` | 通过；260 项测试，5 项按环境条件跳过，0 失败。 |
| `swift build -c release` | 通过。 |
| `bash scripts/health-check.sh` | `HEALTH_CHECK_RESULT: PASS`；debug/release 构建、全量测试、Shell 语法和两个 Python 服务语法均通过。 |

基线环境限制：`shellcheck`、`swiftlint`、`periphery` 未安装，健康检查按设计标记为 `SKIP`；未安装任何工具，也未降低核心测试标准。

## 批次 A

| 任务 | 状态 | 提交 | 备注 |
|---|---|---|---|
| DAL-010 | ✅ 完成 | `7ea2cb5` | 硬超时工具与三处调用统一完成。 |
| DAL-020 | ✅ 完成 | `b2d5cd0` | 会话资源所有权与 7 条竞态回归测试完成。 |
| DAL-030 | ✅ 完成 | `f396df3` | 火山连接生命周期与会话事件流已分离。 |
| DAL-040 | ✅ 完成 | `05227b5` | Apple Speech 会话令牌与可靠截止时间已完成。 |
| DAL-050 | ⚠️ 自动验收完成，人工项部分跳过 | `43c58b1` | AirPods、内置麦克风通过；USB 双声道声卡与聚合设备由用户明确跳过。 |
| DAL-060 | ✅ 完成 | `0239544` | 本地双引擎会话流、终态和迟到终校隔离完成。 |

### DAL-010：建立真正的硬超时工具

- 状态：✅ 完成。
- 提交：`7ea2cb5`（`修复: 建立不依赖子任务取消协作的硬超时工具`）。
- 测试优先：先新增 6 条 throwing timeout 回归测试；修复前执行 `swift test --filter AsyncTimeoutTests` 明确失败，原因为 `AsyncTimeout` 尚无 `throwingValue`。
- 修改：新增一次性完成闸门；operation、计时器和外部取消只允许一个终态；计时器胜出后立即恢复调用方并取消 detached operation，不等待底层任务退出。提炼请求、Apple Speech `endAudio`、RecognitionSession 批量兜底统一使用该工具。
- 验证：
  - `swift test --filter AsyncTimeoutTests`：10 项，0 失败。
  - `swift test --filter 'AssetExtractionRetryTests|RecognitionSessionTests'`：23 项，0 失败。
  - `swift test`：266 项，5 项按环境条件跳过，0 失败。
  - `swift build`：通过。
  - `git diff --check`：通过。
- 遗留风险：Apple Speech 的完整会话令牌、迟到回调隔离和可注入 timeout 属 DAL-040；本任务只替换其阻塞式 Task Group 超时。自动更新开关仍为 `false`。

### DAL-020：修复 RecognitionSession 跨会话资源竞态

- 状态：✅ 完成。
- 提交：`b2d5cd0`（`修复: 将录音资源绑定会话身份并阻断迟到任务`）。
- 测试优先：先新增 `RecognitionSessionRaceTests` 的 7 条竞态用例；修复前执行 `swift test --filter RecognitionSessionRaceTests` 明确编译失败，原因为缺少会话 ID、依赖注入接口及测试读取 API，证明新测试未被既有实现满足。
- 修改：
  - 将 `SpeechRecognizer` 限定为引用类型，以对象身份校验 ASR client 所有权。
  - 为 ASR client、事件消费任务、音频上传管线、音频采集、录音开始时间、当前配置和 speculative LLM 任务显式绑定 `RecognitionSessionID`。
  - 连接失败、事件晚到、事件任务退出和 stop 收尾均先核对会话 ID；清理 client 时同时核对局部对象身份。
  - `forceReset` 改为同步摘除共享引用：先使旧 ID 失效，再取消局部旧任务，并仅用 detached 任务断开旧 client；清理期间无 actor suspension。
  - 增加最小 ASR factory、音频采集和文本注入依赖接口；全部会话测试改用内存历史库，未访问真实用户数据。
- 验证：
  - `swift test --filter RecognitionSessionRaceTests`：7 项，0 失败。
  - `swift test --filter RecognitionSessionTests`：19 项，0 失败。
  - `swift test --filter 'RecognitionSession(Race)?Tests'`：26 项，0 失败。
  - `swift test`：273 项，5 项按环境条件跳过，0 失败。
  - `swift build`：通过。
  - `git diff --check`：通过。
- 遗留风险：本任务以可控 fake 验证跨会话所有权和迟到回调隔离，未执行真实云端 ASR 或麦克风人工录音；各 ASR client 自身的事件流生命周期分别由 DAL-030、DAL-040、DAL-060 继续加固。自动更新开关仍为 `false`。

### DAL-030：修复火山 ASR 重连后事件流永久关闭

- 状态：✅ 完成。
- 提交：`f396df3`（`修复: 分离火山连接生命周期与识别事件流生命周期`）。
- 测试优先：先新增 `VolcASRReconnectTests` 的 6 条生命周期用例；修复前执行 `swift test --filter VolcASRReconnectTests` 明确编译失败，缺少可注入拨号资源、连接退出诊断和 terminal helper 测试入口，证明现实现不具备所需连接身份与终态边界。
- 修改：
  - 每次拨号生成独立 `connectionID`，receive loop 固定捕获本地 WebSocket task 与该 ID，不再逐轮读取共享 task。
  - 重连和断开均先使旧 ID 失效、摘除共享引用，再取消局部旧 task 与 URLSession；旧 loop 的消息、错误和退出无法触碰新连接。
  - transient receive error 只发送 `.streamingInterrupted`，保留会话级事件流，后续 send 失败仍可触发一次重连。
  - 事件流只在 `disconnect`、`emitCompletedOnce`、`emitTerminalError` 三条路径结束；terminal helper 统一去重、发送终态、结束流并清理 continuation。
  - 增加可控 WebSocket 拨号抽象，覆盖旧 loop 先结束、旧 loop 晚到退出、terminal 去重、disconnect 收流及重连文本前缀拼接。
- 验证：
  - `swift test --filter VolcASRReconnectTests`：6 项，0 失败。
  - `swift test --filter VolcProtocolTests`：19 项，0 失败。
  - `swift test`：279 项，5 项按环境条件跳过，0 失败。
  - `swift build`：通过。
  - `git diff --check`：通过。
- 遗留风险：测试使用可控 WebSocket fake，未连接真实火山服务执行断网/重连人工验收；服务端关闭帧的具体时序仍需日常网络波动场景观察。自动更新开关仍为 `false`。

### DAL-040：修复 Apple Speech 超时和迟到回调污染

- 状态：✅ 完成。
- 提交：`05227b5`（`修复: 为 Apple Speech 增加会话令牌和可靠截止时间`）。
- 测试优先：先新增 `AppleASRClientLifecycleTests` 的 6 条生命周期用例；修复前执行 `swift test --filter AppleASRClientLifecycleTests` 明确编译失败，缺少识别会话抽象、回调封装、可注入截止时间与 waiter 诊断入口，证明旧实现不具备所需会话隔离边界。
- 修改：
  - 每次 `connect` 生成唯一 `sessionID`，Apple callback 固定捕获该 ID；处理回调和结束事件流前均先核对当前会话。
  - `disconnect` 与重连先同步使会话失效、摘除 continuation 和识别引用，再取消局部旧 Apple task；迟到 transcript/error 无法结束新流。
  - `endAudio` 使用可注入 duration 的 `AsyncTimeout.throwingValue`；截止时间到期后取消对应识别任务、将最新 partial 发送为 fallback final、恢复 waiter 并立即返回。
  - 将单一 finish waiter 与 `sessionID` 绑定，对重复 waiter 增加明确断言与日志；`completed` 与 continuation 恢复均做单次终态保护。
  - 增加最小 Apple recognition session 注入边界，生产实现仍将 Speech framework 请求、追加音频和取消限定在 MainActor。
- 验证：
  - `swift test --filter AppleASRClientLifecycleTests`：6 项，0 失败。
  - `swift test`：285 项，5 项按环境条件跳过，0 失败。
  - `swift build`：通过。
  - `git diff --check`：通过。
- 遗留风险：回归测试使用可控 Apple recognition fake，未在真实麦克风与 Apple Speech 服务上人工验收授权、系统服务不可用及真实 5 秒超时时序。自动更新开关仍为 `false`。

### DAL-050：修复 CMSampleBuffer 多声道内存越界风险

- 状态：⚠️ 实现与自动验收完成；AirPods 与内置麦克风人工录音通过，USB 双声道声卡与聚合设备由用户明确跳过。
- 提交：`43c58b1`（`修复: 按 AudioBufferList 安全转换采集音频`）。
- 测试优先：先新增 `AudioCaptureBufferConversionTests` 的 9 条用例；修复前执行 `swift test --filter AudioCaptureBufferConversionTests` 明确编译失败，原因是生产端只有 `Data` 重载，且没有安全的 CMSampleBuffer 转换与可测重采样入口。
- 修改：
  - 删除将整个 `CMBlockBuffer` 复制到第 0 声道的逻辑，改用 `CMSampleBufferCopyPCMDataIntoAudioBufferList`。
  - 按交错/非交错格式核对目标 buffer 数量，逐 buffer 检查 `mData`、`mDataByteSize` 与每帧字节数；检查 data-ready 状态和 CoreMedia copy OSStatus，失败时记录帧数、采样率、声道数、每帧字节与 flags 后丢弃。
  - 覆盖 mono/stereo、Int16/Float32、interleaved/non-interleaved 五种布局，并保持 ASR 输出为 16 kHz、mono、Int16、interleaved。
  - 重采样 frame capacity 改为 `ceil(sourceFrames * 16000 / sourceRate) + 1`，对 44.1/48 kHz 与奇数帧留出安全余量。
- 验证：
  - `swift test --filter AudioCaptureBufferConversionTests`：9 项，0 失败。
  - `swift test --filter AudioCaptureEngineTests`：10 项，0 失败。
  - `swift test --sanitize address --filter AudioCaptureBufferConversionTests`：9 项，0 失败，未报告内存越界。
  - `swift test`：294 项，5 项按环境条件跳过，0 失败。
  - `swift build`：通过。
  - `git diff --check`：通过。
- AirPods 人工验收（2026-07-20 PDT）：
  - 当前默认输入为“听”，Bluetooth、1 声道、24 kHz、Float32；无需切换系统输入。
  - 经用户明确授权后，使用直接编译生产 `AudioCaptureEngine` 的临时程序执行 5 秒内存采集；音频未保存、未上传，也未访问用户数据目录。
  - 成功产生 22 个音频块、136,298 字节；最大绝对采样值 13,544，最大归一化电平 0.6825921；0 个 `CMSampleBuffer` 转换失败或被丢弃。
  - 转换结果保持 16 kHz、mono、Int16、interleaved，验收程序返回 `ACCEPTANCE_RESULT=PASS`。
  - 验收后 `swift test --filter 'AudioCaptureBufferConversionTests|AudioCaptureEngineTests'`：19 项，0 失败；`swift test`：299 项，5 项按环境条件跳过，0 失败。
- 内置麦克风人工验收（2026-07-20 PDT）：
  - 经用户明确授权，将默认输入从 AirPods“听”（CoreAudio ID 267）临时切换至“MacBook Pro麦克风”（ID 104）；测试结束后立即恢复 ID 267，并再次读取确认恢复成功。
  - 使用同一临时程序执行 5 秒内存采集；输入为 44.1 kHz、1 声道，音频未保存、未上传，也未访问用户数据目录。
  - 成功产生 25 个音频块、155,486 字节；最大绝对采样值 1,903，最大归一化电平 0.31228927；0 个 `CMSampleBuffer` 转换失败或被丢弃。
  - 转换结果保持 16 kHz、mono、Int16、interleaved，验收程序返回 `ACCEPTANCE_RESULT=PASS`。
  - 验收后 `swift test --filter 'AudioCaptureBufferConversionTests|AudioCaptureEngineTests'`：19 项，0 失败；`swift test`：299 项，5 项按环境条件跳过，0 失败。
- USB 双声道声卡人工验收：用户于 2026-07-20 明确指示跳过；未切换至 USB 输入、未录音，不计为通过。跳过后复核发现 AirPods 已离线，系统默认输入自行回落至内置麦克风，并非本次操作切换。
- 聚合音频设备人工验收：用户于 2026-07-20 明确指示停止并跳过剩余音频测试；未创建聚合设备、未切换输入、未录音，不计为通过。
- 硬件盘点：当前可见 AirPods“听”（1 声道/24 kHz）、MacBook Pro 内置麦克风（1 声道/44.1 kHz）、Maono USB 双声道输入（48 kHz）、Maono AI USB 双声道输入（48 kHz）及多个虚拟多声道设备；未确认聚合音频设备。
- 遗留风险：AirPods 与内置麦克风已通过；USB 双声道声卡和聚合音频设备均被明确跳过且未通过，DAL-050 不具备完整四设备人工验收结论。自动更新开关仍为 `false`。

### DAL-060：修复 SenseVoiceWSClient 中断后终校事件丢失

- 状态：✅ 完成。
- 提交：`0239544`（`修复: 保持本地双引擎会话流直至终校完成`）。
- 测试优先：先新增 `SenseVoiceWSLifecycleTests` 的 5 条生命周期用例；修复前执行 `swift test --filter SenseVoiceWSLifecycleTests` 明确编译失败，缺少可注入 WebSocket/Qwen 边界、连接身份与迟到循环诊断入口，证明旧实现不具备所需的会话/连接所有权。
- 修改：
  - 每次识别会话生成 `sessionID`，每次 SenseVoice 连接生成 `connectionID`；receive loop 固定捕获局部 socket 与双 ID，旧 loop 的消息、错误和退出均无法触及新会话。
  - 删除 receive loop 退出时无条件 `finish()` 会话流的逻辑；传输中断只发送 `.streamingInterrupted`，Qwen final 继续在同一事件流中发送 final transcript 和 completed。
  - completed/error helper 统一执行会话校验、单次终态、发送事件、finish 流和清理 continuation。
  - `disconnect` 先使 session/connection ID 失效、摘除共享引用，再取消旧 receive、WebSocket、URLSession 和 Qwen debounce 资源。
  - Qwen 投机与 final 的快照、HTTP 返回、确认 offset 和 `resetQwen3State` 均核对原会话；旧 `endAudio` 返回后不能发布迟到文本，也不能清空新会话已累积音频。
  - 将本地服务解析、WebSocket 拨号和 Qwen transcriber 提炼为最小可注入边界，生产默认行为仍使用现有 server manager 和 localhost HTTP/WebSocket。
- 验证：
  - `swift test --filter SenseVoiceWSLifecycleTests`：5 项，0 失败。
  - `swift test --filter 'AudioChunkUploadPipelineTests|RecognitionSessionTests'`：21 项，0 失败。
  - `swift test`：299 项，5 项按环境条件跳过，0 失败。
  - `swift build`：通过。
  - `swift build -c release`：通过。
  - `git diff --check`：通过。
- 遗留风险：生命周期测试使用可控 WebSocket 与 Qwen transcriber fake，未启动真实 SenseVoice/Qwen Python 服务执行断连后终校人工验收；将在批次 A 汇报中明确列为待办。自动更新开关仍为 `false`。

## 批次 A 收口

- 代码任务：DAL-010 至 DAL-060 已按依赖顺序实施，每项均先红灯、再修复、跑定向与全量测试、最后独立提交。
- 当前代码 HEAD：`023954481fb45ec0898811b3c94caf19d00ce1e5`。
- 自动更新：`UpdateChecker.updateChannelEnabled = false`，未改动。
- 真实用户数据：未访问、未修改 `~/Library/Application Support/Muse/`。
- 收口自动验收：`bash scripts/health-check.sh` 返回 `HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建通过，全量 `swift test` 执行 299 项、5 项按环境条件跳过、0 失败，Shell 语法与两个 Python 服务语法检查通过。
- 收口环境限制：`shellcheck`、`swiftlint`、`periphery` 未安装，健康检查按设计标记为 `SKIP`；未安装工具，也未降低构建或测试门槛。
- 音频人工验收豁免：用户于 2026-07-20 明确要求停止并跳过剩余音频测试；USB 双声道声卡与聚合设备未通过，批次 A 仅按显式豁免继续推进，不代表原四设备门槛全部满足。
- 待人工项：DAL-030 真实火山断网/重连；DAL-040 真实 Apple Speech 超时；DAL-060 真实 SenseVoice 中断后 Qwen 终校。

## 批次 B

| 任务 | 状态 | 提交 | 备注 |
|---|---|---|---|
| DAL-070 | ✅ 完成 | `b387d76` | 本地服务进程级 token 鉴权与 HTTP、LLM、WebSocket 输入边界完成。 |
| DAL-080 | ✅ 完成 | `aad11af` | 本地服务进程身份校验、可靠停止和增量端口解析完成。 |
| DAL-090 | ✅ 完成 | `aa2d925` | 火山协议 Header、未对齐长度读取及压缩/JSON 资源边界完成。 |
| DAL-100 | ✅ 完成 | `4e18a03` | 进程级剪贴板租约、代际恢复闸门与并发注入事务完成。 |

### DAL-070：给本地 ASR 和 LLM 服务增加鉴权与输入上限

- 状态：✅ 完成。
- 提交：`b387d76`（`修复: 为本地推理服务增加会话鉴权和请求边界`）。
- 测试优先：
  - 先新增 `LocalServiceAuthTests`；修复前运行 `swift test --filter LocalServiceAuthTests` 明确失败，编译器报告找不到 `LocalServiceAuth`。
  - 先新增 Python 共用安全合同与真实路由接线测试；修复前运行 `python3 -m unittest discover -s local-service-shared -p 'test_*.py'` 明确失败，报告缺少 `local_service_security` 模块。
- 修改：
  - Swift 使用 `SecRandomCopyBytes` 每进程生成 32 字节随机 token，编码为 base64url；token 仅保存在内存，经 `MUSE_LOCAL_AUTH_TOKEN` 传入 SenseVoice、Qwen 子进程，不持久化、不写日志。
  - 为 `/ws`、两处 `/health`、`/transcribe`、`/llm/load`、`/llm/unload` 和 localQwen 的 `/v1/chat/completions` 补 `X-Muse-Local-Token`；Ollama 与云端请求不携带该 Header。
  - 两套 Python 服务使用 `hmac.compare_digest` 校验 HTTP/WS token；WS 在 `accept` 前鉴权，继续执行原 Host/Origin 防护和单活动连接约束；主入口缺 token 时在模型加载前退出。
  - 共用校验模块限制 HTTP PCM 为 octet-stream、偶数字节、最大 60 MB；LLM JSON 最大 2 MB，并统一校验 messages、总 content、temperature、max_tokens；WS 单帧最大 1 MB、累计音频最大 30 分钟，Qwen 越界帧仅追加剩余容量。
  - 两份 PyInstaller 脚本加入共享模块搜索路径；健康检查新增 Python 语法与 12 项 unittest 的强制步骤。
- 验证：
  - `swift test --filter 'LocalServiceAuthTests|SenseVoiceWSLifecycleTests|DoubaoChatClientTests'`：11 项，0 失败。
  - `python3 -m unittest discover -s local-service-shared -p 'test_*.py'`：12 项，0 失败。
  - `swift test`：304 项，5 项按环境条件跳过，0 失败。
  - `swift build`、`swift build -c release`：通过。
  - `bash scripts/health-check.sh`：`HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建、全量 Swift 测试、Shell/Python 语法和 Python 服务测试全部通过。
  - `git diff --check`：通过。
- 遗留风险：测试通过 FastAPI TestClient、stub 模型和可控 WebSocket 验证，不加载真实 ASR/LLM 模型；当前环境未安装 PyInstaller，未执行冻结制品导入冒烟。启动 gate 以当前打包入口 `main()` 为边界，未来若改用 `uvicorn module:app` 需同步迁移到 lifespan/startup gate。`shellcheck`、`swiftlint`、`periphery` 未安装，按健康检查既有规则标记为跳过。未执行任何麦克风或音频设备测试。自动更新开关仍为 `false`。

### DAL-080：修复本地服务 PID 误杀、停止泄漏和端口解析

- 状态：✅ 完成。
- 提交：`aad11af`（`修复: 校验本地服务进程身份并可靠回收子进程`）。
- 测试优先：
  - 先新增进程身份与端口解析回归测试；修复前运行 `swift test --filter 'ServerProcessIdentityTests|ServerPortParserTests'` 明确编译失败，报告缺少 `ServerProcessController`、`ServerProcessIdentity`、`ServerProcessIdentityLedger`、`PortLineParser` 与 `ServerPortReader`。
  - 补充“台账中的进程已退出”用例后，该用例先得到错误的 `.refused`；随后将身份校验改为区分进程不存在、读取失败和身份不匹配，红灯转绿。
- 修改：
  - PID 台账改为 JSON 身份记录，保存服务类型、PID、真实可执行路径和进程启动时间；旧纯文本或损坏台账只记录安全日志，不据此发送信号。
  - 使用 `proc_pidpath` 与 `proc_pidinfo` 在发信号前后核对进程仍存活、路径、启动时间和服务类型；身份不一致时拒绝终止并保留未确认台账，避免 PID 复用导致误杀。
  - 主动停止与孤儿清理统一先移除 Pipe handler、发送 TERM、等待约 3 秒，再重新校验身份并按需发送 KILL；只有确认进程退出后才清除 actor 状态与台账。
  - 为 `Process` 安装永久退出闩锁，等待采用独立 continuation 与硬截止时间，不阻塞 manager actor；并发停止复用同一进程身份与退出闩锁。
  - 端口读取改为增量解析，只处理换行完成的日志行；支持标记跨 2/3/4 个数据块，并在成功、EOF 或超时后移除 `readabilityHandler`。
- 验证：
  - `swift test --filter 'ServerProcessIdentityTests|ServerPortParserTests'`：18 项，0 失败。
  - `swift test`：322 项，5 项按环境条件跳过，0 失败。
  - `swift build`、`swift build -c release`：通过。
  - `bash scripts/health-check.sh`：`HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建、322 项 Swift 测试、Shell/Python 语法和 12 项 Python 服务测试全部通过。
  - `git diff --check`：通过。
- 遗留风险：进程测试只终止测试自身创建的 `/bin/sleep` 与忽略 TERM 的 Python fixture，未启动真实 ASR/LLM 模型，也未读取或迁移真实用户数据目录中的既有 PID 台账；Python 服务类型属于 manager 持有的逻辑身份，操作系统层仅能再次证明解释器路径。`proc_pidinfo` 复核与 `kill` 之间仍存在极小的系统调用竞态窗口，当前实现已按任务要求在每次信号前重复校验。按用户指示未执行任何麦克风、音频设备或真机音频测试。自动更新开关仍为 `false`。

### DAL-090：加固火山二进制协议解析

- 状态：✅ 完成。
- 提交：`aa2d925`（`修复: 为火山协议解析增加对齐安全和大小上限`）。
- 测试优先：先扩充 `VolcProtocolTests`；修复前运行 `swift test --filter VolcProtocolTests` 明确编译失败，报告缺少 `unsupportedVersion`、`invalidHeaderSize`、`truncatedSequence`、`payloadTooLarge`、utterance/文本上限错误、协议大小常量及带 `maximumOutputBytes` 的解压 API。
- 修改：
  - Header 解码只接受 v1，要求 `headerSize >= 1` 且声明的 Header 字节数不超过输入；序列号分支统一使用 `flags.hasSequence`，不足 4 字节时给出明确错误。
  - payload 长度改为逐字节大端组合，不再对可能未对齐的 Data slice 使用 `load(as:)`；边界判断使用减法，避免偏移与长度相加溢出。
  - gzip 线缆 payload 上限为 4 MiB，解压后及未压缩 JSON payload 上限为 16 MiB；流式解压在每次 append 前检查 `maximumOutputBytes`，无进展或损坏流立即失败。
  - JSON 解析前再次核对大小；utterance 最多 10,000 条，主文本和每条 utterance 文本最多 1 MiB。
  - server error 的 JSON 与 gzip 兼容保持不变，进入日志/UI 的错误消息按 UTF-8 安全截断至 4 KiB；非 JSON 错误正文同样有限。
- 验证：
  - `swift test --filter VolcProtocolTests`：32 项，0 失败。
  - `swift test --filter 'VolcProtocolTests|VolcASRReconnectTests|VolcReconnectMergeTests'`：42 项，0 失败。
  - `swift test --sanitize address --filter VolcProtocolTests`：32 项，0 失败，未报告未对齐或内存访问问题。
  - `swift test`：335 项，5 项按环境条件跳过，0 失败。
  - `swift build`、`swift build -c release`：通过。
  - `bash scripts/health-check.sh`：`HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建、335 项 Swift 测试、Shell/Python 语法和 12 项 Python 服务测试全部通过。
  - `git diff --check`：通过。
- 遗留风险：回归测试使用合成二进制、固定 zlib fixture 与本地 Compression API，未连接真实火山服务验证线上异常帧；4 MiB、16 MiB、10,000 条、1 MiB 和 4 KiB 均为任务卡要求或其“有限长度”要求的明确本地策略，若服务端协议未来提高合法上限需同步调整并补兼容测试。`shellcheck`、`swiftlint`、`periphery` 未安装，健康检查按既有规则跳过。按用户指示未执行任何麦克风、音频设备或真机音频测试。自动更新开关仍为 `false`。

### DAL-100：修复连续剪贴板注入丢失原剪贴板

- 状态：✅ 完成。
- 提交：`4e18a03`（`修复: 用剪贴板租约协调连续文本注入`）。
- 测试优先：
  - 先新增连续注入、第三方复制、迟到旧恢复、空原内容、图文多类型和粘贴事件失败用例，并把既有恢复测试迁移到唯一命名 pasteboard；修复前运行 `swift test --filter 'TextInjectionClipboardRestoreTests|TextInjectionOverlapTests'` 明确编译失败，报告缺少 `ClipboardLeaseCoordinator`、可取消恢复调度边界、可注入 pasteboard/粘贴模拟器和可测剪贴板注入入口。
  - 再新增两个 engine 真并发用例；未加进程级注入事务门时，该测试明确失败：第二个 engine 在第一轮 Cmd+V 完成前进入并把剪贴板改成第二段文本，且只注册到一个恢复任务。
  - 再新增“永久复制与活跃租约文本相同”用例；原实现因缺少原子 `writeTextPermanently` 接口而编译失败，随后补齐永久写入与租约失效的一体化边界。
- 修改：
  - 新增进程级 `ClipboardLeaseCoordinator.shared`；第一次注入只捕获一份原始 snapshot，后续重叠注入复用它、递增 generation、取消旧任务，并更新最新文本与 changeCount。
  - 只有 pasteboard 名称和 generation 同时匹配的最后恢复任务可以执行；恢复成功、第三方内容导致放弃、不可恢复快照或粘贴失败后均清理租约。
  - 用独立状态锁保护 snapshot/generation/任务，用进程级递归事务锁串行化“临时写入 → Cmd+V → 注册恢复”；调度器和任务取消均在状态锁外调用，避免同步回调重入死锁。
  - `simulatePaste()` 改为返回 Bool；CGEvent 创建失败时不再误报 inserted，而是保留带 transient type 的识别文本、返回 `.copiedToClipboard`，且不安排恢复。
  - 剪贴板 snapshot 支持注入命名 pasteboard 与 logger；新增测试全部使用 `NSPasteboard.withUniqueName()`，不接触系统通用剪贴板。
  - 引擎显式复制、无目标/不保留路径以及 AppState、资产库、最近记录三个 UI 永久复制入口统一经协调器原子失效租约，防止迟到恢复覆盖主动复制。
- 验证：
  - `swift test --filter 'TextInjectionClipboardRestoreTests|TextInjectionOverlapTests'`：14 项，0 失败。
  - `swift test --filter 'AppStateTests|TextInjectionEngineIntegrationTests'`：17 项，4 项既有 UI 真机门控测试按环境条件跳过，0 失败。
  - `swift test --sanitize thread --filter TextInjectionOverlapTests`：9 项，0 失败，未报告数据竞争。
  - `swift test`：344 项，5 项按环境条件跳过，0 失败。
  - `swift build`、`swift build -c release`：通过。
  - `bash scripts/health-check.sh`：`HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建、344 项 Swift 测试、Shell/Python 语法和 12 项 Python 服务测试全部通过。
  - `git diff --check`：通过。
- 遗留风险：第三方恰好复制与当前注入完全相同的字符串时，无法与既有“目标应用改写剪贴板但文本相同”的 J2 兼容场景可靠区分；UI 永久复制若与注入事务正面相撞，主线程最多等待现有约 150 ms 注入窗口；TextEdit、Electron 与 nonactivatingPanel 的真实 UI 注入仍由发布前真机 gate 覆盖，本任务未启用其环境变量。`shellcheck`、`swiftlint`、`periphery` 未安装，健康检查按既有规则跳过。按用户指示未执行任何麦克风、音频设备或真机音频测试。自动更新开关仍为 `false`。

## 批次 B 收口

- 代码任务：DAL-070 至 DAL-100 已按依赖顺序实施，每项均先红灯、再修复、跑定向与全量测试、最后独立提交。
- 当前代码 HEAD：`4e18a03e84b056f26f0e2a13e373641162f1d12c`。
- 自动更新：`UpdateChecker.updateChannelEnabled = false`，未改动；Cloud、Local 双制品签名、SHA256、更新与回滚真机验收尚未完成，因此继续保持关闭。
- 真实用户数据：未访问、未修改 `~/Library/Application Support/Muse/`；DAL-100 新增剪贴板测试全部使用唯一命名 pasteboard。
- 收口自动验收：`bash scripts/health-check.sh` 返回 `HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建通过，全量 `swift test` 执行 344 项、5 项按环境条件跳过、0 失败，Shell/Python 语法和 12 项 Python 服务测试通过。
- 收口环境限制：`shellcheck`、`swiftlint`、`periphery` 未安装，健康检查按设计标记为 `SKIP`；未安装工具，也未降低构建或测试门槛。
- 音频测试：遵照用户指示，本批次未执行任何麦克风、音频设备或真机音频测试。
- 待人工项：DAL-070 冻结后的真实本地 ASR/LLM 制品鉴权与模型加载；DAL-080 真实服务进程停止与既有 PID 台账迁移；DAL-090 真实火山异常帧；DAL-100 TextEdit、微信剪贴板 fallback、Electron 与 nonactivatingPanel 连续注入。以上不影响本批次自动验收结论，仍须在发布前真机 gate 中完成。

## 批次 C

| 任务 | 状态 | 提交 | 备注 |
|---|---|---|---|
| DAL-110 | ✅ 完成 | `ef60ef4` | 候选转资产幂等事务、提炼最终状态原子提交及失败状态独立兜底完成。 |
| DAL-120 | ✅ 完成 | `2c9a716` | 固定版本清单、逐文件 SHA256、ephemeral 下载、staging 原子安装与失败回滚完成。 |
| DAL-130 | ✅ 完成 | `2d9d915` | Provider 级 Endpoint 策略、共享 ephemeral 会话、重定向阻断及有界 SSE 完整性校验完成。 |
| DAL-140 | ✅ 完成 | `df15455` | 显式 schema 迁移、内置文件保护、用户词优先与 100 条严格下发上限完成。 |
| DAL-150 | ✅ 完成 | `a18762d` | Provider 能力统一门控、启动前回退说明与 Release 本地服务路径闭锁完成。 |
| DAL-160 | ✅ 完成 | `b48b180` | JSON 恢复态、数据库 throwing 查询、UI 故障提示、统一日志脱敏与测试数据隔离完成。 |

### DAL-110：让候选入库和提炼提交具备事务性与幂等性

- 状态：✅ 完成。
- 提交：`ef60ef4`（`修复: 原子提交语料候选、资产和提炼运行状态`）。
- 测试优先：
  - 修改前先运行既有相关基线：`swift test --filter 'LanguageAssetStoreTests|AssetExtractionRetryTests|AssetExtractionNormalizerTests'`，32 项、0 失败。
  - 先新增 Candidate 首次入库/重试、更新失败回滚、编辑入库、COMMIT 失败和通知时序，以及提炼第二条结果失败、finished run 失败、配方结果原子提交、action-log prepare 失败等测试；修复前运行 `swift test --filter 'LanguageAssetTransactionTests|AssetExtractionCommitTests'` 明确编译失败，报告缺少可注入 `NotificationCenter`、`commitExtraction` 与 throwing Candidate 入库接口。
  - 独立审查发现 queued 提交和 action log 故障兜底缺口后，再先新增两条服务级失败测试；修复前 `AssetExtractionCommitTests` 明确失败：queued 失败后 job/run 不存在，action-log 不可用时 job/run 仍停在 queued。
- 修改：
  - 新增统一 `BEGIN IMMEDIATE → body → COMMIT` 事务 helper；body 或 COMMIT 任一失败均 ROLLBACK 并透传原始 SQLite 错误，批量 recipe/result/asset/candidate 写入统一复用无事务 row helper。
  - Candidate 转 Asset 在同一事务内读取候选、以 `candidate.id` 执行 `INSERT OR IGNORE`、读取持久化 Asset、更新 Candidate 为 saved 并幂等写入 action log；编辑后的 Candidate、Asset 与状态同样整体提交。
  - 老 `extractAssets` 将 candidates、results、finished job/run 与成功日志一次提交；`extractRecipeResults` 将 kept/rejected results、finished run 与成功日志一次提交，提交成功后才裁剪和通知。
  - queued/running 状态也纳入错误处理；任一数据/状态提交失败后，用独立事务保存 failed。若 action log 自身不可用，自动退化为不含日志的 failed 状态事务，避免任务永久停在 queued/running，并始终向调用方重抛原始错误。
  - `insert(job:)`、`insert(run:)` 与 Candidate 入库接口改为 throwing；UI 捕获并展示错误。Store 支持注入 `NotificationCenter`，事务成功后仅发送一次通知，并启用、校验 SQLite foreign keys 以覆盖真实 COMMIT 失败。
- 修改文件：
  - `Dal/Database/LanguageAssetStore.swift`
  - `Dal/Services/AssetExtractionService.swift`
  - `Dal/UI/Settings/AssetLibraryTab.swift`
  - `DalTests/LanguageAssetStoreTests.swift`
  - `DalTests/LanguageAssetTransactionTests.swift`
  - `DalTests/AssetExtractionCommitTests.swift`
- 验证：
  - `swift test --filter 'LanguageAssetTransactionTests|AssetExtractionCommitTests|LanguageAssetStoreTests|AssetExtractionRetryTests|AssetExtractionNormalizerTests'`：44 项，0 失败。
  - `swift test --sanitize thread --filter 'LanguageAssetTransactionTests|AssetExtractionCommitTests'`：12 项，0 失败，未报告数据竞争。
  - `swift test`：356 项，5 项按既有环境条件跳过，0 失败。
  - `swift build`、`swift build -c release`：通过。
  - `bash scripts/health-check.sh`：`HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建、356 项 Swift 测试、Shell/Python 语法和 12 项 Python 服务测试全部通过。
  - `git diff --check`：通过；独立只读复审未发现 DAL-110 阻断问题。
- 遗留风险：旧版本曾为同一 Candidate 生成随机 Asset UUID，现有历史库没有可靠映射字段，本次不扫描或迁移真实用户数据，因此历史内容级重复无法自动合并；`commitExtraction` 的最终提交显式重放时仍会以 `OR REPLACE` 覆盖后来人工修改的 Candidate/Result 状态并新增一条 action log，正常服务流程不会重放同一 final commit，后续若引入自动重试需增加 run 级提交幂等键；action-log 表损坏时优先保证 failed job/run 落库，因此该次失败可能只有应用日志而没有数据库 action log。测试全部使用临时数据库和 SQLite trigger 注入，未在真实用户库验证迁移或多进程锁竞争。按用户指示未执行任何音频测试。自动更新开关仍为 `false`。

### DAL-120：给模型下载增加固定版本、哈希和原子安装

- 状态：✅ 完成。
- 提交：`2c9a716`（`修复: 固定模型版本并以哈希和原子目录安装`）。
- 开始状态：分支 `codex/dal-hardening-v1`，HEAD `21ec6adff2cfee4aa52084a6ce5eada69c56076c`；保留既有 `REPAIR_EXECUTION_LOG.md` 修改及未跟踪的 `CODEX_REPAIR_PLAN.md`，未覆盖或纳入代码提交。基线 `swift build` 通过；`swift test` 执行 356 项、5 项按既有环境条件跳过、0 失败。
- 测试优先：
  - 先新增模型清单校验和安装事务测试；修复前运行定向测试明确编译失败，报告缺少固定制品清单、逐文件校验、可注入下载边界、归档安全检查和事务安装 API。
  - 再先新增调用方取消、取消后迟到进度、固定 revision 绑定续传、归档链接根目录边界、回滚删除失败及 backup 清理失败用例；各用例修复前分别出现下载未取消且仍安装、迟到进度多回调一次、错误复用 12 字节旧续传、缺少根目录校验 API、正式目录保留 7 字节损坏内容及验证后的新模型因清理错误被错误回滚等红灯，随后逐项修复转绿。
- 修改：
  - 为 5 个模型维护固定 revision 的制品清单，覆盖 17 个文件的固定 URL、精确字节数与 SHA256；拒绝 `resolve/main`、缺少哈希或不完整清单，并使用流式 CommonCrypto SHA256 校验。
  - 下载统一使用不持久化 cookie/缓存的 ephemeral URLSession；续传状态绑定 revision、URL、SHA256 与目标路径，校验响应文件名、Content-Length 或实际字节数，并让调用方取消向下载任务、会话和 UI 进度闸门传播。
  - 多文件、单文件和压缩包均先写入 `Downloads/<model-id>/<uuid>/` staging；全部校验后执行“旧目录 → backup、候选目录 → 正式目录、安装后再校验”，任一运行时失败恢复旧模型，验证成功后才清理 backup。
  - tar 在解压前真实列举条目并拒绝绝对路径、`..` 越界、特殊文件及越界软/硬链接；只解压到 staging，解压前后重验归档 SHA256，并审计解压树中的真实目录、普通文件和符号链接边界。
  - 模型删除先取消进行中的操作；哈希和 tar 工作移出 actor 临界区，operation ID 防止旧任务清理新状态。健康检查新增模型制品策略门，阻止浮动 revision、默认 URLSession 或缺失清单完整性测试回归。
- 修改文件：
  - `Dal/Services/ModelArtifactManifest.swift`
  - `Dal/Services/ModelManager.swift`
  - `DalTests/ModelArtifactVerificationTests.swift`
  - `DalTests/ModelInstallationTransactionTests.swift`
  - `scripts/health-check.sh`
- 验证：
  - `swift test --filter 'ModelArtifactVerificationTests|ModelInstallationTransactionTests'`：29 项，0 失败。
  - `swift test --sanitize=thread --filter 'ModelArtifactVerificationTests|ModelInstallationTransactionTests'`：29 项，0 失败，未报告数据竞争。
  - `swift test`：385 项，5 项按既有环境条件跳过，0 失败。
  - `swift build`、`swift build -c release`：通过。
  - `bash scripts/health-check.sh`：`HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建、385 项 Swift 测试、模型制品策略、Shell/Python 语法和 12 项 Python 服务测试全部通过。
  - `git diff --check`：通过；独立只读复审未发现 DAL-120 的 P0/P1 阻断问题，17 个文件的版本、大小与 SHA256 元数据和官方来源一致。
- 遗留风险：本任务未下载或加载最大约 5.6 GB 的真实模型，因此真实 CDN 重定向后的文件名/Content-Length/续传兼容性、真实 Python 模型加载仍属于发布前人工 gate；进程若恰好在“旧目录 → backup”和“候选目录 → 正式目录”之间崩溃，可能留下隐藏 backup，当前覆盖所有可捕获运行时失败，但尚无安装 journal 或启动恢复；backup 删除若因权限问题在删除前失败，会保留已验证的新正式目录和隐藏 backup 供后续清理；bsdtar 列举、校验和解压是独立进程，虽在解压前后重验归档并审计结果，同用户恶意进程理论上仍可制造本地竞态。`shellcheck`、`swiftlint`、`periphery` 未安装，健康检查按既有规则跳过，未安装工具或降低门槛。未触碰真实用户数据目录，按用户指示未执行任何音频测试。自动更新开关仍为 `false`。

### DAL-130：加固 LLM Endpoint、SSE 和网络会话

- 状态：✅ 完成。
- 提交：`2d9d915`（`修复: 强制安全 LLM 地址并校验流式响应完整性`）。
- 开始状态：分支 `codex/dal-hardening-v1`，HEAD `b81be17c0a0d12616a88bf22e36275aee2f1ddf7`；仅保留既有未跟踪文件 `CODEX_REPAIR_PLAN.md`，未覆盖或纳入提交。基线 `swift build`、`swift build -c release` 通过，`swift test` 执行 385 项、5 项按既有环境条件跳过、0 失败，健康检查通过。
- 测试优先：
  - 先新增云端/本地 URL 策略、凭证规范化、ephemeral 会话、local token、SSE 格式/完整性、响应上限及错误脱敏测试；修复前定向测试明确编译失败，缺少 Endpoint policy 与流式 parser API。
  - 随后依次以失败测试锁定 JSON/Authorization/query 脱敏、IPv6 与 CRLF、无 delta 的 `finish_reason`、空端口、有限读取、重定向、部分传输、取消传播与 parser 错误分类，均先观察红灯再实施修复。
  - 最后一轮先新增超长数字端口、原始 SSE 单行/总量、独立多行 event 包络和默认 session 复用测试；修复前分别因缺少 `SSEByteStreamDecoder`、`maxEventBytes` 与共享 session API 编译失败，实施后转绿。
- 修改：
  - 新增 provider-aware Endpoint policy：云端只允许 HTTPS，Ollama 的 HTTP 仅允许精确回环主机，localQwen 仅允许当前进程端口的 `127.0.0.1/v1`；拒绝 userinfo、fragment、query、空 host、空/越界/超长端口，并使用 URL API 拼接路径。
  - 保存 LLM 凭证前统一 trim、验证和规范化 base URL；localQwen 仅在 Endpoint 精确校验后加入进程级鉴权 Header。
  - 默认 client 与模型列表复用专用共享 ephemeral URLSession，禁用 Cookie、URLCache 和 credential storage，设置 request/resource timeout，并拒绝全部 HTTP 重定向，避免认证 Header 或请求体跨地址转发。
  - SSE 改为逐字节读取：原始总量 16 MiB、单行 4 MiB、单 event 4 MiB、累计文本 2 MiB；支持 `data:`、可选空格、CRLF、空行、多行 event、`[DONE]` 与非空 `finish_reason`，提前断流返回可重试 truncated，取消和既有 parser 错误保持原类型。
  - 非流式响应和预热改为有界读取；错误体有限保留并脱敏 API key、token、Authorization 与 URL query，用户可见错误不再携带原始服务响应。
- 修改文件：
  - `Dal/LLM/ClaudeChatClient.swift`
  - `Dal/LLM/DoubaoChatClient.swift`
  - `Dal/LLM/LLMEndpointPolicy.swift`
  - `Dal/LLM/LLMModelListFetcher.swift`
  - `Dal/LLM/Providers/ClaudeLLMConfig.swift`
  - `Dal/LLM/Providers/LLMBaseURLValidator.swift`
  - `Dal/LLM/Providers/OpenAICompatibleLLMConfig.swift`
  - `Dal/Services/KeychainService.swift`
  - `DalTests/LLMEndpointPolicyTests.swift`
  - `DalTests/LLMStreamingParserTests.swift`
- 验证：
  - `swift test --filter 'LLMEndpointPolicyTests|LLMStreamingParserTests|LLMProviderConfigTests|LLMModelListFetcherTests|LocalServiceAuthTests|DoubaoChatClientTests'`：45 项，0 失败。
  - `swift test`：414 项，5 项按既有环境条件跳过，0 失败。
  - `swift build`、`swift build -c release`：通过。
  - `bash scripts/health-check.sh`：`HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建、414 项 Swift 测试、模型制品策略、Shell/Python 语法和 12 项 Python 服务测试全部通过。
  - `git diff --check`：通过；两轮独立只读复审均未发现剩余 P0/P1。
- 遗留风险：未连接真实云端 LLM 或本地 Qwen 服务进行网络联调，服务商若依赖重定向须把配置改为最终 HTTPS Endpoint；未使用真实 API key，也未读写真实用户数据目录。`shellcheck`、`swiftlint`、`periphery` 未安装，健康检查按既有规则跳过。按用户指示未执行麦克风、AirPods 或其他音频真机测试。Cloud、Local 双制品签名、SHA256、更新与回滚真机验收尚未完成，自动更新开关继续保持 `false`。

### DAL-140：保护词库迁移并严格限制热词下发

- 状态：✅ 完成。
- 提交：`df15455`（`修复: 保留词库文件改动并严格限制下发热词`）。
- 开始状态：分支 `codex/dal-hardening-v1`，HEAD `2e991df0432e3ea19922c4f4122087a4d27145bb`；仅保留既有未跟踪文件 `CODEX_REPAIR_PLAN.md`，未覆盖或纳入提交。基线 `swift build` 通过；`swift test` 执行 414 项、5 项按既有环境条件跳过、0 失败。
- 测试优先：
  - 先新增词库迁移、内置文件保护、用户文件保留、热词去空/去重/截断、Finder 入口、缓存隔离与重载测试；修复前定向测试明确编译失败，报告缺少可注入 `VocabularyStorageContext`、schema 迁移 API、重载 API、Finder 回调和截断结果字段。
  - 再以失败测试锁定旧 v2 完成标记不得复活已删除 legacy 数据、legacy snippet 替换文本须保留大小写、损坏 legacy payload 不得推进 schema，以及用户 `cloudcode` 必须覆盖内置 `Cloud Code`；各项均先观察红灯再修复转绿。
  - 重载测试直接写入临时 user 文件绕过 `save`，证明 snippet 缓存在显式 reload 前保持旧值；所有存储测试均使用临时目录和独立 UserDefaults suite。
- 修改：
  - 新增可注入的 `VocabularyStorageContext`，生产环境保留既有支持目录，测试环境使用临时目录、独立 defaults 和无副作用回调；内置热词与 snippet 仅在文件缺失时 seed，已有空文件、损坏文件或人工修改文件均不覆盖。
  - 新增 `tf_hotwords_schema_version`、`tf_snippets_schema_version` 与逐版本迁移框架；兼容旧 v2 完成标记但不重新导入，legacy key 缺失视为成功空迁移，类型错误、损坏 JSON、非法 snippet 行或未来版本均报错且不推进 schema。
  - 热词选择统一 trim、丢弃空项、大小写不敏感去重、用户优先并严格限制最终 100 条，返回实际用户入选数及截断数；RecognitionSession、请求选项和本地服务派生文件统一复用同一入口，设置页显示未下发数量。
  - snippet 覆盖键与实际匹配语义统一移除全部空白并忽略大小写，保留用户 replacement 原始大小写；缓存按 builtin/user URL 分区并以 generation 防止失效期间写回旧规则。
  - 批量编辑入口仅创建并打开用户自定义文件；snippet 重载只失效缓存并刷新编辑草稿，hotword 重载才同步并重启本地服务，URL command 同步执行对应重载。
- 修改文件：
  - `Dal/ASR/ASRRequestOptionsFactory.swift`
  - `Dal/AppURLCommandHandler.swift`
  - `Dal/Services/HotwordStorage.swift`
  - `Dal/Services/SenseVoiceServerManager.swift`
  - `Dal/Services/SnippetStorage.swift`
  - `Dal/Services/VocabularyStorageContext.swift`
  - `Dal/UI/Settings/VocabularyBuiltInFooter.swift`
  - `Dal/UI/Settings/VocabularyTab.swift`
  - `DalTests/SnippetStorageConcurrencyTests.swift`
  - `DalTests/VocabularyMigrationTests.swift`
- 验证：
  - `swift test --filter 'VocabularyMigrationTests|SnippetStorageConcurrencyTests|VocabularySnippetGroupingTests|VolcProtocolTests|RecognitionSessionTests|RecognitionSessionRaceTests'`：76 项，0 失败。
  - `swift test --sanitize thread --filter 'VocabularyMigrationTests|SnippetStorageConcurrencyTests'`：16 项，0 失败，未报告数据竞争。
  - `swift test`：428 项，5 项按既有环境条件跳过，0 失败。
  - `swift build`、`swift build -c release`：通过。
  - `bash scripts/health-check.sh`：`HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建、428 项 Swift 测试、模型制品策略、Shell/Python 语法和 12 项 Python 服务测试全部通过。
  - `git diff --check`：通过；独立只读终审未发现剩余 P0/P1。
- 遗留风险：未在真实用户词库上执行迁移，未实际点击 Finder/UI 入口，也未联调真实本地 ASR 服务；损坏的现有新版 JSON 文件如何向用户恢复属于 DAL-160 范围。本任务没有访问或修改 `~/Library/Application Support/Muse/`。`shellcheck`、`swiftlint`、`periphery` 未安装，健康检查按既有规则跳过。按用户指示未执行麦克风、AirPods 或其他音频真机测试。Cloud、Local 双制品签名、SHA256、更新与回滚真机验收尚未完成，自动更新开关继续保持 `false`。

### DAL-150：统一 Provider 可用性并封闭正式版开发路径

- 状态：✅ 完成。
- 提交：`a18762d`（`修复: 统一识别引擎可用性并封闭正式版开发路径`）。
- 开始状态：分支 `codex/dal-hardening-v1`，HEAD `cb3ffad7df76cfad75c41a23ba432154e4e3f651`；仅保留既有未跟踪文件 `CODEX_REPAIR_PLAN.md`，未覆盖或纳入提交。基线 `swift build` 通过；`swift test` 执行 428 项、5 项按既有环境条件跳过、0 失败。
- 测试优先：
  - 先扩充 Provider 能力、启动回退和服务入口解析测试；修复前运行 `swift test --filter 'ASRProviderRegistryTests|ServerExecutableResolutionTests'` 明确编译失败，报告缺少 capability 注入重载、启动回退 API、`ServerExecutableResolver`、构建策略、解析结果与错误类型。
  - 随后补齐 Release 忽略显式开发根、DEBUG 无变量/相对变量拒绝、bundle 优先与 fail-closed、服务目录和脚本符号链接逃逸、缺脚本/缺 Python、非可执行或不可信 Python、合法 venv 外链、双服务同根及两 manager 策略一致等边界测试。
- 修改：
  - `ASRProviderRegistry.supports` 先统一检查 capability；不可用 Provider 的直出和自定义模式全部不可选，模式列表为空，`resolvedMode` 回退直出。ProviderEntry 的 UI 可用性也要求 capability 与 client 同时成立。
  - Sherpa capability 同时要求编译支持和共享 resolver 能找到可信服务入口；启动迁移完成后、热键注册、本地服务启动和连通性探测之前，历史不可用选择按显式顺序回退到 Volcano/Apple，并先持久化再显示一次性说明。
  - 新增共享 `ServerExecutableResolver`：bundle 永远优先；候选存在但越界或不可执行时直接失败，不回落开发目录。Release 构建不读取开发变量且只允许 bundle 内入口。
  - DEBUG 仅接受绝对路径 `DAL_DEV_SERVER_ROOT`，不再向上遍历或扫描 `~/dal`、`~/projects/dal`；开发根、服务目录和 `server.py` 必须归当前有效用户，canonical path 不得越界，脚本和 Python 必须为普通文件，Python 目标必须属于当前用户或 root 且可执行。
  - venv Python 可合法链接到开发根之外的可信解释器，避免破坏 Homebrew/uv 创建的真实虚拟环境；SenseVoice 与 Qwen3 统一走相同解析器，ModelManager 的在位判断与 ServerManager 的实际启动结论一致。
- 修改文件：
  - `Dal/ASR/ASRProviderRegistry.swift`
  - `Dal/AppStartupCoordinator.swift`
  - `Dal/DalApp.swift`
  - `Dal/Services/ModelManager.swift`
  - `Dal/Services/SenseVoiceServerManager.swift`
  - `Dal/Services/ServerExecutableResolver.swift`
  - `DalTests/ASRProviderRegistryTests.swift`
  - `DalTests/ServerExecutableResolutionTests.swift`
- 验证：
  - `swift test --filter 'ASRProviderRegistryTests|ServerExecutableResolutionTests'`：25 项，0 失败。
  - `swift test --filter 'ASRProviderRegistryTests|ServerExecutableResolutionTests|AppStateTests|RecognitionSessionTests|RecognitionSessionRaceTests|ModelArtifactVerificationTests|ServerProcessIdentityTests'`：87 项，0 失败。
  - `swift test`：450 项，5 项按既有环境条件跳过，0 失败。
  - `swift build`、`swift build -c release`：通过。
  - `bash scripts/health-check.sh`：`HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建、450 项 Swift 测试、模型制品策略、Shell/Python 语法和 12 项 Python 服务测试全部通过。
  - `git diff --check`：通过；独立只读终审未发现 P0/P1 或阻断性测试缺口，并独立复跑 25 项定向测试与 Release 构建通过。
- 遗留风险：未实际启动开发 Python 服务、未用带本地服务的签名 App bundle 验证包装脚本，也未目视验收启动回退 NSAlert；测试全部使用临时目录与注入的构建/所有者策略，未访问真实用户目录。默认 `scripts/package-app.sh` 构建 Release 且通常不带 `BUNDLE_LOCAL_ASR=1`，收紧后这类包不再执行仓库 venv，这是计划要求；本地制品必须显式打包服务，开发调试必须使用 DEBUG 并设置 `DAL_DEV_SERVER_ROOT`。`shellcheck`、`swiftlint`、`periphery` 未安装，健康检查按既有规则跳过。按用户指示未执行麦克风、AirPods 或其他音频真机测试。Cloud、Local 双制品签名、SHA256、更新与回滚真机验收尚未完成，自动更新开关继续保持 `false`。

### DAL-160：显式传播存储故障并统一日志脱敏

- 状态：✅ 完成。
- 提交：`b48b180`（`修复: 显式传播存储故障并统一日志脱敏`）。
- 开始状态：分支 `codex/dal-hardening-v1`，HEAD `678a2d9a5f2d620c8ed8e728353171db06b38dff`；保留执行日志中的进行中标记及既有未跟踪文件 `CODEX_REPAIR_PLAN.md`，未覆盖或纳入代码提交。基线 `swift build` 通过；`swift test` 执行 450 项、5 项按既有环境条件跳过、0 失败。
- 测试优先：
  - 先新增 `JSONFileStoreRecoveryTests`、`DatabaseFailurePropagationTests`、`LogRedactionTests`；修复前定向测试明确编译失败，报告缺少显式 JSON 读取状态、throwing 查询、共享脱敏器及可注入 debug log writer。
  - 随后以失败测试锁定隔离后恢复 URL 稳定、损坏 builtin 不推进 schema、恢复期间禁止保存、Basic/自定义 URL query/多行与转义 JSON、argv 多词敏感值、既有轮转权限、测试进程禁止写真实 debug.log；均先观察红灯再修复转绿。
  - 独立审计发现结构化 Prompt/Transcript 数组或对象会泄漏后，先新增回归用例并观察 4 项断言失败，再对非字符串正文值执行 fail-closed 脱敏。
  - 独立审计发现旧测试会构造真实数据库和访问系统钥匙串后，先新增 Keychain 隔离断言并观察编译失败，再将测试凭据、遗留 JSON 与 Provider 偏好改为加锁的进程内后端；低价值过滤测试改用两份内存数据库。
- 修改：
  - `JSONFileStore` 以 `missing/value/corrupt` 显式返回读取状态；解码失败串行移动到时间戳 `.corrupt-*` 备份并设为 `0600`，后续读取持续呈现恢复态，读取或隔离失败时也以进程内闸门禁止默认值回写。Mode、Hotword、Snippet 全部使用新状态，迁移不再覆盖损坏文件，设置页提供 Finder 恢复提示。
  - `HistoryStore`、`LanguageAssetStore` 为核心读取增加 throwing API，prepare、step 与数据库不可用均向上传播；提炼服务和设置 UI 改用 throwing 链路，错误时保留旧快照，并分别显示历史库与资产库错误及重试入口。
  - 新增共用 `LogRedactor`，覆盖 Authorization、API/access/local token、Prompt、语音正文、URL query、JSON 字符串/数组/对象及启动参数；`AppLogger` 默认 `.private`，识别日志仅公开固定状态与计数。
  - debug log 写入和轮转提炼为可注入 writer；活动文件与 `.1` 均强制 `0600`，既有轮转文件也会修复权限。XCTest 下静态 debug logger 和 Keychain/credentials/UserDefaults 读写使用无真实目录副作用的隔离路径。
- 修改文件：
  - 存储与数据库：`Dal/Services/JSONFileStore.swift`、`ModeStorage.swift`、`HotwordStorage.swift`、`SnippetStorage.swift`、`StorageRecoveryNotice.swift`、`KeychainService.swift`、`Dal/Database/HistoryStore.swift`、`LanguageAssetStore.swift`。
  - 日志与调用方：`Dal/Services/AppLogger.swift`、`DebugFileLogger.swift`、`LogRedactor.swift`、`AssetExtractionService.swift`、`ModelManager.swift`、`SenseVoiceServerManager.swift`、`Dal/LLM/LLMEndpointPolicy.swift`、`Dal/ASR/AppleASRClient.swift`、`Dal/Session/RecognitionSession.swift`、`Dal/DalApp.swift`。
  - UI：`Dal/UI/AppState.swift`、`Settings/AssetLibraryDataSnapshot.swift`、`AssetLibraryExtractionViewModel.swift`、`AssetLibraryTab.swift`、`GeneralSettingsTab.swift`、`SettingsView.swift`。
  - 测试：`DalTests/JSONFileStoreRecoveryTests.swift`、`DatabaseFailurePropagationTests.swift`、`LogRedactionTests.swift`、`KeychainServiceTests.swift`、`AssetExtractionNormalizerTests.swift`、`AppStateTests.swift`。
- 验证：
  - `swift test --filter 'JSONFileStoreRecoveryTests|DatabaseFailurePropagationTests|LogRedactionTests|KeychainServiceTests|AssetExtractionLowValueFilterTests|AppStateTests'`：38 项，0 失败。
  - `swift test`：467 项，5 项按既有环境条件跳过，0 失败。
  - `swift build`、`swift build -c release`：通过。
  - `bash scripts/health-check.sh`：`HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建、467 项 Swift 测试、模型制品策略、Shell/Python 语法和 12 项 Python 服务测试全部通过。
  - `git diff --check`：通过；三轮独立只读审计确认默认测试不访问真实 Dal 目录或系统钥匙串，且未发现剩余 P0/P1。
- 遗留风险：隔离前的既有完整测试曾打开默认数据库并访问真实系统钥匙串，测试虽设计为恢复临时写入，但未获授权再次检查真实目录或钥匙串，无法确认是否存在持久影响；此事实已在文首审计更正。未用真实损坏配置或真实数据库目视验收恢复提示与错误重试；同一次设置页打开只提示扫描到的第一份损坏文件，多个损坏文件需后续再次打开设置页处理；非 throwing Store API 为兼容边界继续保留并记录错误，核心生产链路已不再使用；显式 `DAL_REAL_EXTRACTION=1` 的旧质量测试在安全隔离后无法读取真实钥匙串，后续应改用独立集成测试凭据。按用户指示未执行麦克风、AirPods 或其他音频真机测试。Cloud、Local 双制品签名、SHA256、更新与回滚真机验收尚未完成，自动更新开关继续保持 `false`。

## 批次 C 收口

- 代码任务：DAL-110 至 DAL-160 已按依赖顺序实施，每项均先红灯、再修复、跑定向与全量测试、最后独立提交。
- 当前代码 HEAD：`b48b180db68b37a9a6ded45c1d255ad6a9254a32`。
- 自动更新：`UpdateChecker.updateChannelEnabled = false`，未改动；Cloud、Local 双制品签名、SHA256、更新与回滚真机验收尚未完成，因此继续保持关闭。
- 真实用户数据：审计确认隔离前的既有完整测试会打开默认数据库并访问系统钥匙串，纠正了此前“未访问”的错误记录；未获授权再次检查或回滚，持久影响无法确认。`b48b180` 已隔离默认数据库、debug log、凭据文件、Provider 偏好与系统钥匙串路径，之后的收口测试未再触碰。
- 收口自动验收：`bash scripts/health-check.sh` 返回 `HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建通过，全量 `swift test` 执行 467 项、5 项按环境条件跳过、0 失败，模型制品策略、Shell/Python 语法和 12 项 Python 服务测试通过。
- 收口环境限制：`shellcheck`、`swiftlint`、`periphery` 未安装，健康检查按设计标记为 `SKIP`；未安装工具，也未降低构建或测试门槛。
- 音频测试：遵照用户指示，本批次未执行麦克风、AirPods 或其他音频真机测试；完整 `swift test` 中的纯单元音频缓冲测试仍按仓库硬门槛执行。
- 待人工项：真实模型 CDN/安装恢复、真实云端与本地 LLM 联调、词库迁移和损坏恢复 UI、Provider 启动回退、冻结本地服务路径，以及 DAL-120 要求的 Cloud/Local 双制品签名与 SHA256 验收。以上均继续作为发布前 gate，不据此开启自动更新。

## 批次 D

| 任务 | 状态 | 提交 | 备注 |
|---|---|---|---|
| DAL-170 | ✅ 完成 | `828c726` | 外层签名保持最后；Mach-O/MetalLib 嵌套代码、Cloud/Local 内容和严格验签均有自动回归门槛。 |
| DAL-180 | ✅ 完成 | `f89d7db` | Cloud/Local 清单、SHA256、不可变验签、ready 握手、可回滚同卷替换与 DMG 发布链均有自动回归门槛；自动更新仍关闭。 |

### DAL-170：修复 App Bundle 最终签名顺序

- 状态：✅ 完成。
- 提交：`828c726`（`修复: 调整应用签名顺序并验证最终 Bundle`）。
- 开始状态：分支 `codex/dal-hardening-v1`，HEAD `537d50220d3d8ce397f3eb26e9fab991de0ce530`；保留执行日志中的进行中标记及既有未跟踪文件 `CODEX_REPAIR_PLAN.md`，未覆盖或纳入代码提交。基线 `swift build` 通过；`swift test` 执行 467 项、5 项按既有环境条件跳过、0 失败。
- 测试优先：
  - 先新增脚本语法、嵌套签名失败、签名后禁写、Cloud/Local 内容、严格验签与篡改失效测试；首个策略测试在缺少 `scripts/sign-app-bundle.sh` 时明确失败，实施后逐项转绿。
  - 独立测试审计指出原 fixture 未执行真实 `package-app.sh`、嵌套失败由测试分支制造、篡改未走正式验证脚本等假绿风险；测试随后改为在临时项目中执行真实打包链，用可注入失败 signer、无扩展且无执行位的 Mach-O、正式 `test_app_bundle.sh` 与篡改制品锁定行为。
  - 终审发现真实 MLX `mlx.metallib` 被 `/usr/bin/file` 识别为 `MetalLib executable` 而非 Mach-O；先新增最小 MetalLib 内容 fixture 并观察脚本错误进入外层签名，再扩展内容检测，目标测试转绿。随后将仓库现有 150 MB 真实 MLX MetalLib 只读克隆到临时 App，确认嵌套签名、单体严格验签与外层严格验签均通过。
  - 再以两个失败哨兵测试锁定 Local 缺 dist、目录存在但 launcher 缺失时不得替换既有 Bundle；预检提升到构建和 Bundle 写入之前，并要求两套命名 launcher 均为可执行普通文件。
- 修改：
  - 新增独立签名阶段，遍历最终 `Contents` 并以 `/usr/bin/file` 内容识别所有 Mach-O 与 MetalLib code object；任一嵌套签名失败立即终止，最后才签外层 App，之后仅允许严格验签、元数据读取和 Gatekeeper 评估。
  - Local 服务直接复制到最终目录；可执行入口改为指向已签名冻结 launcher 的 Bundle 内相对符号链接，shell wrapper 作为非可执行资源由外层 seal 覆盖。Cloud 每次重建完整 `Contents`，不会残留旧 Local 文件。
  - Local 构建在任何构建或替换既有 Bundle 之前验证两套 dist 和可执行 launcher，缺件明确失败且保留原 Contents。
  - `test_app_bundle.sh` 对 Cloud/Local 执行同一 `codesign --verify --deep --strict --verbose=4` 门槛；Developer ID authority 继续执行 `spctl --assess`。健康检查新增签名策略静态门槛。
- 修改文件：
  - `DalTests/PackageScriptTests.swift`
  - `scripts/health-check.sh`
  - `scripts/package-app.sh`
  - `scripts/sign-app-bundle.sh`
  - `scripts/test_app_bundle.sh`
- 验证：
  - `swift test --filter PackageScriptTests`：10 项，0 失败。
  - `bash -n scripts/package-app.sh scripts/sign-app-bundle.sh scripts/test_app_bundle.sh scripts/health-check.sh`：通过。
  - 临时真实 Cloud 打包：ad-hoc 外层签名与两次严格验证通过；第一次额外手工复验误传旧 bundle id `com.haujet.dal` 而失败，改用仓库实际 `pro.daliang.muse` 后重跑通过，属于验收命令参数错误而非制品失败。
  - 真实 MLX `mlx.metallib` 临时验收：脚本明确输出嵌套签名，MetalLib 单体和最终 App 严格验签均通过；临时目录均已移入废纸篓，可恢复。
  - `swift build`、`swift build -c release`：通过。
  - `swift test`：477 项，5 项按既有环境条件跳过，0 失败。
  - `bash scripts/health-check.sh`：`HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建、477 项 Swift 测试、模型与签名策略、Shell/Python 语法和 12 项 Python 服务测试全部通过。
  - `git diff --check`：通过；独立只读终审确认无剩余 P0/P1。
- 遗留风险：仓库当前没有两套完整冻结服务 dist，因此真实 Local 成品未能在本机打包；Local 自动验收使用执行真实打包脚本的隔离 fixture，真实 Qwen MetalLib 另行完成签名验证。没有 Developer ID identity，故只验证 ad-hoc 严格签名，`spctl` 的发布证书路径仍是发布前 gate；未生成/公证 DMG，也未做 Cloud/Local 真机安装。`shellcheck`、`swiftlint`、`periphery` 未安装，健康检查按既有规则跳过。测试均使用临时目录和隔离 HOME，未访问真实 Dal 用户数据目录或系统钥匙串；但 DAL-160 已披露的更早测试隔离事故仍无法确认持久影响。按用户指示未执行麦克风、AirPods 或其他音频真机测试。Cloud、Local 双制品签名、SHA256、更新与回滚真机验收尚未全部完成，自动更新开关仍为 `false`。

### DAL-180：重构自动更新与回滚为不可变双制品链

- 状态：✅ 完成。
- 提交：`f89d7db`（`修复: 建立双制品不可变签名更新链`）。
- 开始状态：分支 `codex/dal-hardening-v1`，HEAD `acb62675de5a803399c38803db7ebf1dc83c2b86`；保留既有未跟踪文件 `CODEX_REPAIR_PLAN.md`，未覆盖或纳入提交。基线 Debug 构建与全量测试通过，自动更新开关为 `false`。
- 测试优先：
  - 先新增双制品 manifest、必填 SHA256、严格 URL/版本与禁止 legacy fallback 测试；初始实现因缺少新类型及严格解析而编译失败，非法版本测试也明确红灯。
  - 更新脚本首轮不可变制品策略测试出现 8 项失败；随后用隔离 fixture 逐项锁定带空格挂载路径、精确 `Dal.app`、当前/挂载/复制/正式路径验签、Bundle/Team/version、Cloud/Local 内容、首次及挂载前二次 SHA、四个 rename/清理故障相位和 Trash 实际内容。
  - 独立审计发现父 App 固定延时退出会令早期失败无日志且无法重启；先补缺失接口编译红灯、ready 生命周期与早期 stderr 测试，再实现父进程安全日志描述符和 ready 后退出握手。
  - DMG 动态顺序测试先因脚本绕过测试 shim、直接调用系统 `codesign` 而失败；实现显式测试模式后，证明创建、签名、严格验签、镜像验证、SHA256、发布的实际顺序及中途失败不发布。
  - 终审以真实 `TERM` 故障注入复现破坏性 rename 后不回滚；加入 `HUP/INT/TERM` 统一进入 EXIT 回滚后转绿。随后以编译红灯和 spoof 测试将 ready 改为随机 UUID 目录，并删除 Shell 对日志路径的二次打开；悬空日志符号链接测试也先红后以 `O_EXCL | O_NOFOLLOW` 收口。
- 修改：
  - 更新清单改为严格的 Cloud/Local 双制品结构；按安装形态只选择对应 URL 与 SHA256，缺失、HTTP、非法版本或 hash 一律拒绝且不跨制品 fallback。
  - 下载文件名绑定制品类型，下载后和安装前均校验 SHA256；旧下载、成功 staging、旧 App 和已安装 DMG 均使用可恢复的废纸篓清理。
  - 更新脚本不再本机重签或回写旧 Local 组件；对当前、挂载、同卷临时及正式 App 严格验签，并校验 Bundle ID、TeamIdentifier、版本与 Cloud/Local 内容。
  - 使用同卷临时 App、备份和 rename 事务安装；四个移动故障及 `HUP/INT/TERM` 均尝试隔离失败候选、恢复并复验旧 App，明确输出 `ROLLBACK_OK` 或 `ROLLBACK_FAILED`。
  - 父进程以 `0600`、`O_EXCL | O_NOFOLLOW` 创建并继承更新日志，使用随机 ready 目录握手；预检失败时保留父 App，ready 后才退出。失败或不完整日志保留并显示有界诊断，只有精确终态 `SUCCESS` 才清理 staging。
  - `build-dmg.sh` 强制显式 Cloud/Local、数值版本和安全文件名；发布制品要求 Developer ID App/DMG 签名、严格验签、镜像验证和 SHA256，验证全部成功后才替换正式 DMG。ad-hoc 仅生成不可发布开发制品。
- 修改文件：
  - `Dal/Services/AppUpdater.swift`
  - `Dal/Services/UpdateChecker.swift`
  - `DalTests/AppUpdaterChecksumTests.swift`
  - `DalTests/AppUpdaterScriptTests.swift`
  - `DalTests/AppUpdaterStatusTests.swift`
  - `DalTests/DMGScriptTests.swift`
  - `DalTests/UpdateManifestTests.swift`
  - `scripts/build-dmg.sh`
- 验证：
  - `swift test --filter 'UpdateManifestTests|AppUpdaterScriptTests|AppUpdaterChecksumTests|AppUpdaterStatusTests|DMGScriptTests'`：52 项，0 失败。
  - `swift test`：520 项，5 项按既有环境条件跳过，0 失败。
  - `swift build`、`swift build -c release`：通过。
  - `bash -n scripts/build-dmg.sh`、`git diff --check`：通过。
  - `bash scripts/health-check.sh`：`HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建、520 项 Swift 测试、模型与签名策略、全部 Shell/Python 语法和 12 项 Python 服务测试通过。
  - 独立最终复审确认无剩余 P0/P1，并独立复跑 `AppUpdaterScriptTests|AppUpdaterStatusTests` 29 项、0 失败。
- 遗留风险：本机没有 Developer ID 身份和两套完整冻结服务 dist，未生成/公证真实 Cloud/Local 发布 DMG，也未执行真实旧版到新版更新、失败回滚、Gatekeeper 或断电恢复验收；`updates.json` 尚无可发布的真实双制品信息。`SIGKILL`、突然断电或系统崩溃无法由进程内 trap 收口，两个 rename 之间仍需持久事务日志与启动恢复才能达到正式开放门槛。`shellcheck`、`swiftlint`、`periphery` 未安装，健康检查按规则跳过。所有自动安装测试均使用临时目录和隔离 HOME，未访问真实 Dal 用户数据目录。按用户指示未执行麦克风、AirPods 或其他音频真机测试；完整 `swift test` 中的纯单元音频缓冲测试仍按硬门槛执行。Cloud、Local 双制品签名、SHA256、真实更新与回滚验收尚未全部完成，因此 `UpdateChecker.updateChannelEnabled` 继续保持 `false`。

## 批次 D 收口

- 代码任务：DAL-170、DAL-180 已按依赖顺序完成，各自先红灯、后修复、通过定向与全量测试并独立提交。
- 当前代码 HEAD：`f89d7db19725eb3c57907230b9dc41df705fd357`。
- 自动更新：Cloud/Local 双制品协议、签名与回滚代码链已建立，但真实 Developer ID 双制品、SHA256 manifest、更新和回滚真机验收仍未完成，开关继续为 `false`。
- 收口自动验收：Debug/Release 构建通过；全量 `swift test` 520 项、5 项跳过、0 失败；`health-check.sh` 返回 `HEALTH_CHECK_RESULT: PASS`。
- 环境与人工门槛：缺少 Developer ID、真实 Local 双服务 dist、公证发布 DMG 和断电恢复 journal；`shellcheck`、`swiftlint`、`periphery` 未安装。按用户指示未做任何麦克风、AirPods 或人工音频测试。

## 批次 E

| 任务 | 状态 | 提交 | 备注 |
|---|---|---|---|
| DAL-190 | ✅ 完成 | `a441ce6` | Apple 识别强制端侧，拒绝 locale 回退并提供可操作错误；隐私文案与实现一致。 |
| DAL-200 | ✅ 完成 | `f9a8ce9` | macOS CI、双制品签名公证、不可变跨作业复验与发布门槛已落库；真实发布环境和真机 gate 未完成，自动更新仍关闭。 |

### DAL-190：对齐 Apple 识别的端侧行为和隐私说明

- 状态：✅ 完成。
- 提交：`a441ce627c9e276ce7665e7d0f3b66173e48e274`（`修复: 对齐 Apple 识别的端侧行为和隐私说明`）。
- 开始状态：分支 `codex/dal-hardening-v1`，HEAD `a4eeb486df4529afb59cefe3a2d9badca7425955`；保留执行日志中的进行中标记及既有未跟踪文件 `CODEX_REPAIR_PLAN.md`，未覆盖或纳入代码提交。基线 `swift build` 通过；`swift test` 执行 520 项、5 项按既有环境条件跳过、0 失败。
- 测试优先：
  - 先新增 Apple 请求强制端侧、端侧不支持错误、配置 locale 传递及中英文隐私文案测试；修复前定向测试明确编译失败，缺少端侧配置入口与错误类型。
  - 将识别会话工厂改为 throwing 后，先补旧工厂迟到失败不得清理新会话的竞态回归测试。
  - 独立复审发现 Speech 框架可能把不支持的 locale 回退到键盘听写语言；先补识别器为空、实际 locale 不匹配、等价 locale 写法及临时 unavailable 测试，首轮因缺少校验入口编译失败，实施后又以红灯锁定连字符/下划线归一化。
  - 二次复审发现 `isAvailable == false` 可能掩盖 `supportsOnDeviceRecognition == false`；先补 both-false 优先报告端侧不支持的失败测试，再固定校验顺序。
- 修改：
  - 创建 Apple recognition task 前校验请求 locale 与框架实际 locale 一致，并依次判定端侧能力和临时可用性；识别器为空或框架回退语言均返回包含 locale、切换语言及火山引擎建议的明确错误。
  - 请求始终设置 `requiresOnDeviceRecognition = true` 与 partial result；端侧不支持时不创建 task，不允许静默云端 fallback。
  - throwing 工厂异常在清理前核对 `sessionID`；旧连接的迟到失败转换为取消，不能使新会话失效。
  - README、设置页和首次引导的中英文说明统一为 Apple 仅端侧、识别音频不上传，不支持时切换语言或火山引擎。
- 修改文件：
  - `Dal/ASR/AppleASRClient.swift`
  - `Dal/UI/Settings/ASRSettingsFooter.swift`
  - `Dal/UI/Setup/SetupWizardView.swift`
  - `README.md`
  - `DalTests/AppleASRClientLifecycleTests.swift`
  - `DalTests/AppleASRConfigurationTests.swift`
- 验证：
  - `swift test --filter 'AppleASRConfigurationTests|AppleASRClientLifecycleTests'`：16 项，0 失败。
  - `swift test`：530 项，5 项按既有环境条件跳过，0 失败。
  - `swift build`、`swift build -c release`：通过。
  - `bash scripts/health-check.sh`：`HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建、530 项 Swift 测试、模型与签名策略、Shell/Python 语法和 12 项 Python 服务测试全部通过。
  - `git diff --check`：通过；三轮独立只读复审完成，最终确认无剩余 P0/P1、无云端 fallback，并独立复跑 16 项定向测试通过。
- 遗留风险：遵照用户指示未执行麦克风、AirPods、真实 Apple Speech 或其他音频真机测试；端侧 locale 的实际可用性仍取决于目标 macOS、硬件与已安装语言资产，自动测试只覆盖框架边界与可控工厂。`shellcheck`、`swiftlint`、`periphery` 未安装，健康检查按规则跳过。测试使用 fake 与临时资源，未访问真实 Dal 用户数据目录。Cloud、Local 双制品签名、SHA256、真实更新与回滚验收尚未全部完成，因此 `UpdateChecker.updateChannelEnabled` 继续保持 `false`。

### DAL-200：建立持续集成与双制品发布验签门槛

- 状态：✅ 仓库实现完成；正式发布仍被外部环境与真机验收 gate 阻断。
- 提交：`f9a8ce9a97fc93e0adbad9efe6378d37383b7d3c`（`配置: 建立 Dal 持续集成和发布验签门槛`）。
- 开始状态：分支 `codex/dal-hardening-v1`，HEAD `ce65e1579593978cb08636b06219d77ea754f021`；开始前除执行日志的任务认领外，仅有用户既有未跟踪文件 `CODEX_REPAIR_PLAN.md`，未覆盖、未修改、未纳入提交。基线 `swift build` 通过；`swift test` 执行 530 项、5 项按既有环境条件跳过、0 失败。
- 测试优先：
  - 首轮补 CI、发布工作流和双制品验证合同后，定向测试先出现 14 项测试、20 个断言失败；扩展 Swift 工具链固定、依赖冻结、签名与环境保护合同时先出现 19 项测试、23 个失败。
  - 再以失败测试锁定严格版本递增、稳定 Release 判定、跨作业 artifact ID/digest、签名窗口预构建 SHA、Bundle 权限归一化和安全清理；签名窗口阶段 4 项测试先出现 5 个失败。
  - 公证与 Hardened Runtime 合同首轮 6 项测试出现 19 个失败；实现 `notarytool submit --wait`、staple、Gatekeeper 复验及“公证后才计算 SHA256”后转绿。
  - 独立复审指出默认并发只保留一个 pending 发布；先让 `testReleaseWorkflowBuildsAndRevalidatesBothProductsBeforePublishing` 明确 1 项失败，再按 GitHub 官方语法加入 `queue: max`，目标测试转绿。
- 修改：
  - 新增 push/PR macOS CI，固定 Xcode 26.2 / Swift 6.2 和官方 Action commit SHA；每次执行 Debug/Release 构建、完整 Swift 测试、健康检查、全部 Bash 语法、6 个 Python 入口语法及 12 项 Python 安全测试。`shellcheck`、SwiftLint 仅在工具存在时执行，已安装工具失败不会被吞掉。
  - 新增严格 SwiftLint 配置和可移植相对路径 baseline，覆盖 `Dal` 与 `DalTests`；在仓库根目录及另一绝对路径复制中均以 SwiftLint 0.65.0 `--strict --no-cache` 通过。
  - 两套冻结服务构建固定 Python 3.12.10 / 3.14.6、uv 0.11.30 与完整 lock 依赖；旧 build/dist 只移入废纸篓，不再永久删除或覆盖 spec。
  - 发布工作流用 `release-signing`、`release` 两个受保护环境串联质量、签名和公开阶段；所有发布请求在 `dal-release` 并发组串行排队，公开前后各复核线上最高稳定版本，拒绝已有 tag、草稿或预发布同版本。
  - 签名密钥仅在消费 SHA256 锁定的预构建 Swift 二进制时导入临时 keychain；Cloud/Local 均由内到外使用 Developer ID、时间戳和 Hardened Runtime 签名，提交 Apple 公证、staple 后执行 DMG/App 严格验签、Gatekeeper、Team ID 和镜像验证。
  - 仅在两套公证制品全部通过后计算真实 SHA256、生成并校验 manifest fragment；跨作业传递锚定本次运行的 artifact ID 与 digest，公开前下载候选和远端草稿资产再次复验，失败时只清理当前运行创建且带标记的草稿。
  - 发布工作流保留 TextEdit、微信、Electron、nonactivatingPanel、Apple Speech、火山重连、本地双引擎、Cloud/Local 更新和失败回滚共 10 项人工真机 gate；未确认时禁止公开 Release。
- 修改文件：
  - 工作流与静态检查：`.github/workflows/ci.yml`、`.github/workflows/release-verify.yml`、`.swiftlint.yml`、`.swiftlint-baseline.json`。
  - 发布与构建脚本：`scripts/health-check.sh`、`release-verify.sh`、`run-signed-release-build.sh`、`prepare-release-binary.sh`、`notarize-release-artifacts.sh`、`verify-release-environments.sh`、`verify-release-artifact.sh`、`verify-release-version.sh`、`build-sensevoice-server.sh`、`build-qwen3-asr-server.sh`、`build-dmg.sh`、`package-app.sh`、`sign-app-bundle.sh`、`test_app_bundle.sh`。
  - 冻结依赖：`sensevoice-server/requirements.lock.txt`、`qwen3-asr-server/requirements.lock.txt`。
  - 测试：`DalTests/CIWorkflowTests.swift`、`ReleaseVerifyScriptTests.swift`、`PackageScriptTests.swift`、`DMGScriptTests.swift`。
- 验证：
  - `swift test --filter 'CIWorkflowTests|ReleaseVerifyScriptTests|PackageScriptTests|DMGScriptTests|UpdateManifestTests|AppUpdaterChecksumTests|AppUpdaterScriptTests|AppUpdaterStatusTests'`：86 项，0 失败。
  - 最终 `swift test --filter CIWorkflowTests`：11 项，0 失败；最终 `swift test`：554 项，5 项按既有环境条件跳过，0 失败。
  - `swift build`、`swift build -c release`：通过。
  - `bash scripts/health-check.sh`：`HEALTH_CHECK_RESULT: PASS`；Debug/Release 构建、554 项 Swift 测试、模型/签名/CI 发布策略、全部 Shell/Python 语法和 12 项 Python 服务测试通过。
  - `bash -n scripts/*.sh`、6 个 Python 文件 `py_compile`、两份 workflow Ruby YAML 解析、`git diff --check`：通过；`shellcheck`、`periphery` 本机不可用，按既定可选规则跳过。
  - SwiftLint 0.65.0：仓库根目录 strict 通过；复制到另一绝对路径后 strict 通过。actionlint 1.7.12 对除 2026 年新增 `concurrency.queue` 外的 workflow 规则通过；该版本尚未收录 `queue` schema，检查时仅忽略这一条已由 GitHub 官方文档确认的兼容性误报，两份 YAML 均通过解析。
  - 只读线上版本策略实测：`RELEASE_VERSION_POLICY_RESULT: PASS (1.7.4 -> 2.0.0)`。线上环境策略按预期 fail-closed：仓库当前环境数量为 0，Actions secrets/variables 为空，不能进入真实签名发布链。
  - 两轮独立只读审计未发现剩余代码级 P0/P1；公证顺序、artifact ID/digest 语义、远端复验与 fail-closed 边界均复核通过。
- 遗留风险：
  - GitHub 仓库尚未配置 `release-signing`、`release` 受保护环境、Developer ID/Apple Notary secrets 与 `APPLE_TEAM_ID`；未使用正式凭据构建、公证或验签真实 Cloud/Local DMG，也未执行真实冻结服务构建。因此本任务只完成仓库内门槛，不能宣称发布链已真实跑通。
  - 10 项真机发布 gate 均未在本任务执行；遵照用户指示跳过全部音频测试。真实旧版 Cloud/Local 更新、失败回滚、Gatekeeper、Intel/Apple Silicon、本地 MLX Hardened Runtime 兼容性仍是正式发布前阻断项。
  - 未访问或修改 `~/Library/Application Support/Muse/`，未安装任何插件、技能或系统级工具。Cloud、Local 双制品签名、公证、SHA256、更新和回滚真机验收未全部完成，`UpdateChecker.updateChannelEnabled` 继续保持 `false`。

## 批次 E 收口

- 代码任务：DAL-190、DAL-200 已按依赖顺序完成仓库实现，均先建立失败测试、再修复、通过定向和完整测试并独立提交。
- 当前代码 HEAD：`f9a8ce9a97fc93e0adbad9efe6378d37383b7d3c`。
- 收口自动验收：`swift build`、`swift build -c release` 通过；最终完整 `swift test` 执行 554 项、5 项按条件跳过、0 失败；`bash scripts/health-check.sh` 返回 `HEALTH_CHECK_RESULT: PASS`；严格 SwiftLint 在根目录与另一绝对路径均通过。
- 自动更新：仓库内双制品签名、公证、SHA256 和发布 fail-closed 链已建立，但真实 Developer ID/Notary 制品、GitHub 受保护环境、10 项真机更新与回滚验收尚未完成，开关继续保持 `false`。
- 外部阻断：需要仓库管理员配置 `release-signing`、`release` 受保护环境及签名/公证 secrets/variables，再用正式候选执行 Cloud/Local 公证、Gatekeeper、更新和回滚验收；在此之前不得公开发布或开启自动更新。
- 用户数据与音频：本批次未访问真实 Dal 用户数据目录；遵照用户明确指示，未执行麦克风、AirPods、Apple Speech 或其他音频真机测试。

## GitHub 合入与 Dal 2.0.0 发布准备

- 日期：2026-07-21。
- 安全加固主分支合入：PR [#1](https://github.com/DaliangPro/Dal/pull/1) 已合并，合并提交 `d75da1d3a8d2948d359ff49356adfc8c3f1e14cb`；对应主分支 CI [29878764682](https://github.com/DaliangPro/Dal/actions/runs/29878764682) 通过。
- 2.0.0 发布准备：提交 `983e2ceb4f580f85cf6e6d538d85ecb47904be5e` 将本地打包、DMG 构建和应用包验收的默认版本统一为 `2.0.0`，新增中文发布说明及回归测试；PR [#2](https://github.com/DaliangPro/Dal/pull/2) 已合并，合并提交 `e551e0a536a84225ea33604f7da2b7caf783848d`。
- 测试优先：发布版本回归测试在实施前出现 4 个预期失败；实施后单项测试、51 项相关测试均通过。隔离英文环境完整 `swift test` 执行 555 项，5 项按环境条件跳过，0 失败；`bash scripts/health-check.sh` 返回 `HEALTH_CHECK_RESULT: PASS`。
- GitHub 验收：发布准备分支的 push CI [29879645023](https://github.com/DaliangPro/Dal/actions/runs/29879645023) 与 PR CI [29879660827](https://github.com/DaliangPro/Dal/actions/runs/29879660827) 均通过；合并后的主分支 CI [29879945587](https://github.com/DaliangPro/Dal/actions/runs/29879945587) 通过。
- GitHub 发布：按 `v1.7.4` 的普通开源项目发布方式创建轻量 tag `v2.0.0`，指向 `17551ec1ff5cca0eeb3196e7e0f3a27fd4f6abef`；[Dal v2.0.0](https://github.com/DaliangPro/Dal/releases/tag/v2.0.0) 已作为稳定版公开发布，附件为 Apple Silicon（arm64）`Dal-v2.0.0.dmg`。
- 制品验证：应用使用既有 `Muse Local` 本地证书签名，严格代码签名验证、Bundle 元数据测试和 DMG 完整性验证通过。上传后重新下载的文件与本地候选逐字节一致，GitHub 记录及本地复算 SHA256 均为 `b9b37d1d6ce11ed90b9d5a8f2e45d2a4b8e24ac11db018c27b3e3eb87e0aa9a9`。
- 分发边界：本次是与 `v1.7.4` 相同的 GitHub 手动下载发布，不是 Developer ID 公证制品，也不声称受保护的 Cloud/Local 正式发布链或真机 gate 已完成。遵照用户指示未执行音频测试。
- 自动更新：`updates.json` 仍指向 `1.7.4`，`UpdateChecker.updateChannelEnabled` 继续保持 `false`；2.0.0 仅通过 GitHub Release 手动下载，不进入自动更新通道。
