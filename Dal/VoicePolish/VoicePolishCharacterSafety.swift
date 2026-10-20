import Foundation

enum VoicePolishCharacterSafety {

    static func normalizedLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func containsUnsafeCharacters(_ text: String) -> Bool {
        normalizedLineEndings(text).unicodeScalars.contains(where: isUnsafe)
    }

    static func sanitizedFallback(_ text: String) -> String {
        let normalized = normalizedLineEndings(text)
        let scalars = normalized.unicodeScalars.filter { !isUnsafe($0) }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0x09 || value == 0x0A { return false }
        if value <= 0x1F { return true }
        if value == 0x7F || (0x80...0x9F).contains(value) { return true }
        if (0xFDD0...0xFDEF).contains(value) { return true }
        return value & 0xFFFF == 0xFFFE || value & 0xFFFF == 0xFFFF
    }
}

enum VoicePolishOutputNormalizer {

    static let maximumResponseBytes = 1_048_576

    static func plainText(_ response: String, sourceText: String) -> String? {
        guard response.utf8.count <= maximumResponseBytes else { return nil }
        var normalized = VoicePolishCharacterSafety.normalizedLineEndings(
            response.strippingThinkTags()
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixes = ["最终文本：", "最终文本:", "润色后：", "润色后:",
                        "Final text:", "Polished text:"]
        for prefix in prefixes where normalized.hasPrefix(prefix) && !sourceText.hasPrefix(prefix) {
            normalized.removeFirst(prefix.count)
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return collapsingExactWholeDraftRepetitions(
            in: normalized,
            sourceText: sourceText
        )
    }

    /// Provider 的安全修复偶尔会把同一份完整成稿原样重复两到三遍。只有在
    /// 空行分隔出的若干 block 能组成至少两份逐字相同的完整文本，且原口述
    /// 本身没有同样重复时才折叠；近似段落或任一事实不同都保持原样，继续交
    /// 给 Validator 判断，避免误删用户有意重复的内容。
    static func collapsingExactWholeDraftRepetitions(
        in text: String,
        sourceText: String
    ) -> String {
        let normalized = VoicePolishCharacterSafety.normalizedLineEndings(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let blocks = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard blocks.count >= 2 else { return normalized }

        for unitBlockCount in 1...(blocks.count / 2) {
            guard blocks.count.isMultiple(of: unitBlockCount) else { continue }
            let repetitionCount = blocks.count / unitBlockCount
            guard repetitionCount >= 2 else { continue }
            let unit = Array(blocks[..<unitBlockCount])
            let isExactRepetition = stride(
                from: unitBlockCount,
                to: blocks.count,
                by: unitBlockCount
            ).allSatisfy { start in
                Array(blocks[start..<(start + unitBlockCount)]) == unit
            }
            guard isExactRepetition else { continue }

            let collapsed = unit.joined(separator: "\n\n")
            // 极短的重复可能就是聊天中的语气强调；只有完整成稿级文本才在本地
            // 确定性折叠。原口述已包含两份相同文本时也不替用户做删除决定。
            guard collapsed.count >= 40,
                  !sourceContainsRepeatedWholeDraft(
                    collapsed,
                    repetitionCount: repetitionCount,
                    sourceText: sourceText
                  ) else {
                continue
            }
            return collapsed
        }
        return normalized
    }

    private static func sourceContainsRepeatedWholeDraft(
        _ draft: String,
        repetitionCount: Int,
        sourceText: String
    ) -> Bool {
        let comparableDraft = draft
            .filter { !$0.isWhitespace && !$0.isPunctuation }
            .lowercased()
        let comparableSource = sourceText
            .filter { !$0.isWhitespace && !$0.isPunctuation }
            .lowercased()
        guard !comparableDraft.isEmpty else { return true }
        return comparableSource.components(separatedBy: comparableDraft).count - 1
            >= repetitionCount
    }
}
