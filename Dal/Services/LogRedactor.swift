import Foundation

/// AppLogger 与落盘 debug.log 共用的保守脱敏器。
/// 只要字段可能承载凭证、Prompt 或语音正文，就隐藏整个值；诊断日志保留字段名与结构。
enum LogRedactor {
    private static let sensitiveName = #"(?:authorization|api[ _-]?key|access[ _-]?key|access[ _-]?token|auth[ _-]?token|local[ _-]?token|x[ _-]?dal[ _-]?local[ _-]?token|client[ _-]?secret|password|credential|token|prompt|speech[ _-]?text|raw[ _-]?text|final[ _-]?text|transcript)"#
    private static let contentName = #"(?:prompt|speech[ _-]?text|raw[ _-]?text|final[ _-]?text|transcript)"#

    static func redact(_ message: String) -> String {
        var result = message
        let replacements: [(String, String)] = [
            // URL 的 query 一律整体隐藏；路径保留用于定位 endpoint。
            (#"(?i)\b([a-z][a-z0-9+.-]*://[^\s?#]+)\?[^\s]*"#, "$1?<redacted>"),
            // Prompt/语音正文若是 JSON 数组、对象或其他非字符串值，保守隐藏到消息末尾，
            // 避免仅遮住数组首项、让后续正文继续泄漏。
            (#"(?is)(\""# + contentName + #"\"\s*:\s*)(?!\").*\z"#, "$1<redacted>"),
            // JSON 字符串字段。
            (#"(?i)(\""# + sensitiveName + #"\"\s*:\s*\")(?:\\.|[^\"\\])*(?:\"|$)"#, "$1<redacted>\""),
            // Prompt/语音正文的非 JSON 形式可能跨行，标签后的剩余消息全部隐藏。
            (#"(?is)(\b(?:prompt|speech[ _-]?text|raw[ _-]?text|final[ _-]?text|transcript)\b\s*[:=]\s*).*\z"#, "$1<redacted>"),
            // Authorization 可能使用 Bearer、Basic 或自定义 scheme，整行隐藏。
            (#"(?im)(\bauthorization\b\s*[:=]\s*).*$"#, "$1<redacted>"),
            // 其余 key=value / key:value。
            (#"(?i)(\b"# + sensitiveName + #"\b\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,&;]+)"#, "$1<redacted>"),
        ]
        for (pattern, replacement) in replacements {
            result = replacing(pattern: pattern, in: result, with: replacement)
        }
        return result
    }

    static func redactedArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if let equals = argument.firstIndex(of: "="), argument.hasPrefix("-") {
                let flag = String(argument[..<equals])
                if isSensitiveFlag(flag) {
                    result.append("\(flag)=<redacted>")
                } else {
                    result.append(redact(argument))
                }
                index += 1
                continue
            }

            if argument.hasPrefix("-"), isSensitiveFlag(argument) {
                result.append(argument)
                if consumesUntilNextFlag(argument) {
                    var next = index + 1
                    while next < arguments.count, !arguments[next].hasPrefix("-") {
                        next += 1
                    }
                    result.append("<redacted>")
                    index = next
                } else if index + 1 < arguments.count {
                    result.append("<redacted>")
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            result.append(redact(argument))
            index += 1
        }
        return result
    }

    private static func isSensitiveFlag(_ flag: String) -> Bool {
        sensitiveFlagName(flag).map { normalized in
            [
                "authorization", "apikey", "accesskey", "accesstoken", "authtoken",
                "localtoken", "xdallocaltoken", "clientsecret", "password", "credential",
                "token", "prompt", "speechtext", "rawtext", "finaltext", "transcript",
            ].contains { normalized.contains($0) }
        } ?? false
    }

    private static func consumesUntilNextFlag(_ flag: String) -> Bool {
        let normalized = sensitiveFlagName(flag) ?? ""
        return ["authorization", "prompt", "speechtext", "rawtext", "finaltext", "transcript"]
            .contains { normalized.contains($0) }
    }

    private static func sensitiveFlagName(_ flag: String) -> String? {
        let normalized = flag
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return normalized.isEmpty ? nil : normalized
    }

    private static func replacing(pattern: String, in value: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: replacement
        )
    }
}
