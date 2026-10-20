# Dal 语音润色 77 条真实模型验收报告

日期：2026-08-12

## 结论

语音润色质量测试通过 L13 发布门槛。

- 40 条场景基准：`direct_send` 39/40（97.5%），`direct_send + minor_edit` 40/40（100%）。
- 37 条脏输入：`direct_send` 34/37（91.9%），`direct_send + minor_edit` 37/37（100%）。
- 9 条口吃专项：9/9 `direct_send`，非自愿重复全部清理，未发现误删有意强调。
- 关键事实、最终意图、白名单外实体幻觉：77/77 通过。
- 20 类 `input_factor`：均无 `major_edit` 或 `unusable`。
- 八个场景的基准样本均达到至少 4/5 `direct_send`；其中技术表达为 4/5，其余场景均为 5/5。

## 实际运行证据

本轮从严格签名的 `/Applications/Dal.app/Contents/MacOS/Dal` 启动专用质量入口，复用正式 `VoicePolishPipeline` 与应用当前 Provider 配置。

| 项目 | 结果 |
|---|---|
| 数据集 | 40 条基准 + 37 条脏输入，共 77 条 |
| Provider | `deepseek` |
| 模型 | `deepseek-v4-flash` |
| Endpoint origin | `https://api.deepseek.com` |
| Prompt 版本 | 15 |
| 被测提交 | `0583ec9` |
| 完成情况 | 77/77 |
| LLM 调用次数 | 77 条全部一次调用 |
| 安全回退 | 0 |
| Validator 失败 | 0 |
| 平均耗时 | 903 ms |
| P50 / P95 | 897 ms / 1307 ms |
| 最长耗时 | 1447 ms |

原始运行报告保存在本机：`build/voice-polish-quality-final-0583ec9.json`。报告包含每条输入、参考成稿、模型输出、事实约束、路由、调用数、耗时、回退和校验码，不包含 API Key。

## 人工评分记录

除下列 4 条外，其余 73 条均评为 `direct_send`；4 条均事实与意图正确，只需删除一句过程说明或补一个句末标点，因此评为 `minor_edit`。

| ID | 分层 | 评分 | 原因 |
|---|---|---|---|
| `code-01` | 基准 | `minor_edit` | 保留了“先不要改路径和命令”这一写法指令；路径、命令和技术事实均正确，删除该句即可。 |
| `work-03-noise-01` | 脏输入 | `minor_edit` | 保留了“原本想先灰度 10%”的讨论过程，且结论未前置；最终不发布及两项风险均正确。 |
| `email-05-noise-01` | 脏输入 | `minor_edit` | 内容、顺序和事实正确，仅缺句末标点。 |
| `code-03-noise-01` | 脏输入 | `minor_edit` | 四个步骤和命令全部正确，仅缺句末标点。 |

没有 `major_edit` 或 `unusable`。

## 自动验证与部署

- 测试集完整性校验通过：77 次输入、20 类因素达到覆盖门槛、口吃覆盖 9 条和 4 种形态。
- 健康检查通过：1048 项 Swift 测试中 6 项按条件跳过、0 失败；13 项 Python 测试通过；Debug、Release、脚本语法与策略检查通过。
- `/Applications/Dal.app` 已复用 `Muse Local` 签名覆盖安装；Bundle ID 为 `pro.daliang.muse`，严格签名通过。

## 边界

- 本轮是文本母集上的真实外部模型验收，不替代 L9 的真人录音与 Typeless 同音频匿名盲测。
- 人工可发送性评分由本轮执行者复核，不是独立第三方盲评。
- 当前 macOS 菜单栏设置会在普通启动时向 Dal 发送 `NSStatusItemChangeVisibilityAction`，SwiftUI 随后退出。签名应用的质量入口已真实启动并完成 77 条请求；本轮未擅自修改用户的系统菜单栏设置。
