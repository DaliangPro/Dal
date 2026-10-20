import Foundation

/// Voice Polish 正式输入与设置页试跑共用的术语运行时入口。
/// 调用方不得再分别读取 PersonalLexicon、Hotword 和术语型 Snippet。
enum VoicePolishTerminologyRuntime {
    struct PreparedInput {
        let canonicalText: String
        let projection: TerminologyProjectionBundle
        let fixedSnippets: [(trigger: String, value: String)]
    }

    static func prepare(
        rawText: String,
        applicationBundleIdentifier: String?,
        context: VocabularyStorageContext = .production
    ) -> PreparedInput {
        let projection = TerminologyRepository.projections(
            applicationBundleIdentifier: applicationBundleIdentifier,
            context: context
        )
        let fixedSnippets = effectiveFixedSnippets(context: context)
        let fixedText = applyingFixedSnippets(fixedSnippets, to: rawText)
        let canonicalText = EntityResolver.applyingKnownCorrections(
            projection.corrections,
            to: fixedText
        )
        return PreparedInput(
            canonicalText: canonicalText,
            projection: projection,
            fixedSnippets: fixedSnippets
        )
    }

    /// 使用本次整句 prepare 已经加载好的统一词库投影和固定替换规则，逐段生成
    /// canonical 文本。避免按 ASR segment 数量重复读取 Repository 与兼容文件。
    static func canonicalText(
        for rawText: String,
        reusing preparedInput: PreparedInput
    ) -> String {
        let fixedText = applyingFixedSnippets(preparedInput.fixedSnippets, to: rawText)
        return EntityResolver.applyingKnownCorrections(
            preparedInput.projection.corrections,
            to: fixedText
        )
    }

    /// 旧 Snippet 兼容窗口中，只保留不适合建模为术语的固定/整句替换。
    private static func effectiveFixedSnippets(
        context: VocabularyStorageContext
    ) -> [(trigger: String, value: String)] {
        let userSnippets = SnippetStorage.load(context: context)
        let userKeys = Set(userSnippets.map { snippetKey($0.trigger) })
        let builtinSnippets = SnippetStorage.loadBuiltin(context: context).filter {
            !userKeys.contains(snippetKey($0.trigger))
        }
        return (builtinSnippets + userSnippets).filter {
            !SnippetStorage.isDraftTrigger($0.trigger)
                && !TerminologyMigration.isEligibleTerminologySnippet(
                    trigger: $0.trigger,
                    value: $0.value
                )
        }
    }

    /// 同一 trigger 若意外出现冲突则保持原文，避免由文件顺序决定结果。
    private static func applyingFixedSnippets(
        _ snippets: [(trigger: String, value: String)],
        to text: String
    ) -> String {
        var corrections: [String: String] = [:]
        var conflictedTriggers = Set<String>()
        for snippet in snippets {
            guard !snippet.trigger.isEmpty,
                  !snippet.value.isEmpty,
                  !conflictedTriggers.contains(snippet.trigger) else { continue }
            if let existing = corrections[snippet.trigger], existing != snippet.value {
                corrections.removeValue(forKey: snippet.trigger)
                conflictedTriggers.insert(snippet.trigger)
            } else {
                corrections[snippet.trigger] = snippet.value
            }
        }
        return EntityResolver.applyingKnownCorrections(corrections, to: text)
    }

    private static func snippetKey(_ trigger: String) -> String {
        trigger.filter { !$0.isWhitespace }.lowercased()
    }
}
