import Foundation

// MARK: - LLM 输入守卫与结果清洗（2026-07-09 J14 自 AppState.swift 迁出）

extension ProcessingMode {
    func applyingLLMFormatGuard(to expandedPrompt: String) -> String {
        guard !expandedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return expandedPrompt
        }

        // Voice Polish V2 的规则由独立、版本化管线维护。附加要求不能再触发
        // 旧版隐藏列表、机械清理或任务边界拼接。
        var guardedPrompt = expandedPrompt

        let hasBoundaryGuard = guardedPrompt.contains(Self.llmOutputBoundaryGuardZH)
            || guardedPrompt.contains(Self.llmOutputBoundaryGuardEN)
        if !hasBoundaryGuard {
            guardedPrompt = """
            \(guardedPrompt)

            \(Self.llmOutputBoundaryGuard)
            """
        }
        return guardedPrompt
    }

    func applyingLLMResultCleanup(to result: String) -> String {
        var cleaned = Self.stripCommonLLMResponsePrefix(result.strippingThinkTags())
        if kind == .voicePolish {
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !isPromptOptimizeMode {
            cleaned = Self.stripLikelyPromptLeakage(from: cleaned)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func applyingFinalInsertionCleanup(to result: String) -> String {
        if kind == .voicePolish {
            // 润色管线已验证并拼装实际正文；二次清洗会删掉来源中的标签和代码缩进。
            return result
        }
        var cleaned = result.strippingThinkTags()
        if !isPromptOptimizeMode {
            cleaned = Self.stripLikelyPromptLeakage(from: cleaned)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripCommonLLMResponsePrefix(_ result: String) -> String {
        result
            .replacingOccurrences(
                of: #"^\s*(最终文本|输出结果|结果|润色后|改写后|翻译结果|处理结果)[：:]\s*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripLikelyPromptLeakage(from result: String) -> String {
        var cleaned = result
        let inlineMarkers = [
            "以下是语音识别的原始输出",
            "以下是原始内容",
            "以下是用户原始输入",
            "请在以下规则下执行命令",
            "现在选择的内容是",
            "现在剪切板",
            "命令如下：",
            "命令如下:",
            "系统指令：",
            "系统指令:",
            "开发者指令：",
            "开发者指令:",
            "要求后续变更",
            "Type / for commands",
            "Message Codex",
            "Message ChatGPT",
            "Ask anything",
            "输入 / 使用命令",
            "输入消息"
        ]

        for marker in inlineMarkers {
            guard let range = cleaned.range(of: marker) else { continue }
            let prefix = String(cleaned[..<range.lowerBound])
            if prefix.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
                cleaned = prefix
                break
            }
        }

        let lines = cleaned.components(separatedBy: .newlines)
        var kept: [String] = []
        for line in lines {
            if !kept.isEmpty,
               kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
               isLikelyPromptLeakLine(line) {
                break
            }
            kept.append(line)
        }

        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLikelyPromptLeakLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let markers = [
            "#Role", "# Role", "#角色", "# 角色",
            "#核心目标", "# 核心目标",
            "#核心规则", "# 核心规则",
            "#严格规则", "# 严格规则",
            "#示例", "# 示例",
            "#以下是", "# 以下是",
            "以下是语音识别", "以下是原始内容", "以下是用户原始输入",
            "请在以下规则下执行命令",
            "现在选择的内容是", "现在剪切板",
            "命令如下", "系统指令", "开发者指令",
            "要求后续变更",
            "用户输入：", "用户输入:",
            "原始输入：", "原始输入:",
            "提示词：", "提示词:",
            "Type / for commands",
            "Message Codex",
            "Message ChatGPT",
            "Ask anything",
            "输入 / 使用命令",
            "输入消息"
        ]
        return markers.contains { trimmed.hasPrefix($0) }
    }
}
