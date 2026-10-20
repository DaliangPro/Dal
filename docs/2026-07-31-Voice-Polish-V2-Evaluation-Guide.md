# Voice Polish V3 评测指南

## 固定夹具

`VoicePolishFixtureCatalog` 包含 94 条合成夹具，覆盖简短聊天、工作沟通、邮件、即时/延迟改口、旁注、乱序、列表数量变化、专有名词、数字日期、中英技术内容、AI Prompt 和自媒体口播。默认 `swift test` 会检查数量分布、确定性路由和 canonical facts。

## Live Provider Benchmark

Live Benchmark 只在显式启用时调用当前已配置的 LLM Provider：

```bash
bash scripts/run-voice-polish-live-benchmark.sh
```

可用 `DAL_VOICE_POLISH_LIVE_LIMIT` 控制 1～94 条样本，用 `DAL_VOICE_POLISH_LIVE_REPORT` 指定报告路径。报告记录 Provider、模型、endpoint、Prompt 版本、路由、调用次数、延迟、事实通过、旧事实残留、回退率和长度比例。

截至 2026-07-31，本次工程实施未自动调用付费/远程 Live Provider，因此 Live 报告状态为“未执行”。

## 人工盲测

先准备至少 100 条真实同音频样本。每条至少包含：

- 唯一 `id`。
- 非空、真实存在且可解码的本地 `audio_ref`；时长至少 0.5 秒，100 条统一解码后的 PCM 内容必须互不重复。
- `category` 必须覆盖 `proper_noun`、`self_correction`、`aside`、`disordered`、`list`、`numbers`、`mixed_language`、`ai_prompt` 八类。
- `reference_transcript`、`dal_output`、`typeless_output`。
- 完整 `dal_metrics`，其中 `route` 只能是 `fast`、`structured`、`deep`。

若同时提供 `dal_audio_ref` 和 `typeless_audio_ref`，两者必须与 `audio_ref` 指向同一个文件。准备阶段会固化容器 SHA-256、统一 PCM 指纹、媒体信息、参考稿、类别和左右输出；评分阶段只允许修改 `ratings`。文件缺失、内容变化、改容器复用同一录音、替换输出或双方音频来源不一致都会拒绝验收。

```bash
python3 scripts/voice-polish-blind-test.py prepare \
  --input samples.json \
  --output blind-evaluation.json \
  --key blind-key.json \
  --baseline-commit <本次 Dal 提交哈希>
```

正式准备默认使用不可预测随机并保持左右数量平衡。`--seed` 只用于测试复现，种子不会写入公开评测文件，而且带测试种子的报告永远不能得到 `product_ready=true`。

评审者只拿 `blind-evaluation.json`，在每条 `ratings` 中分别填写 `overall`、`writing_quality`、`terminology`、`fact_preservation`、`sendability`；每项只能是 `left`、`right`、`tie` 或 `both_unusable`。密钥文件不交给评审者。完成后计分：

```bash
python3 scripts/voice-polish-blind-test.py score \
  --evaluation blind-evaluation.json \
  --key blind-key.json \
  --output blind-report.json
```

只有同时满足以下条件，`product_ready` 才为 `true`：

- 100 条以上唯一真实音频和完整人工评分。
- 八类内容全部覆盖，正式随机化与左右平衡校验通过，且准备后的非评分证据未被修改。
- Dal 总体胜或平不低于 85%，明显落后不高于 15%，双方不可用不高于 1%。
- 已确认 alias 纠正、关键事实保留、实体幻觉、单次调用、Repair、fallback 全部达到门槛；单次调用与 Repair 按真实发起过 LLM 的样本计算，fallback 按全部自动处理样本计算。
- 延迟样本至少覆盖 Fast 20 条、Structured 20 条、Deep 10 条，且每档 P50/P95 达标；缺少任一档不能视为通过。

工具能验证证据文件的一致性，不能证明评审者身份，也不能密码学证明输出确由该音频现场运行生成；这两项仍需由真实采集和独立评审流程负责。截至 2026-08-02，没有真实同音频 Typeless 输出和人工评分，因此产品验收状态仍为“未执行/未完成”，不得据此声称已经比肩 Typeless。
