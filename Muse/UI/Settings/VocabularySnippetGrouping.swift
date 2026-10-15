struct VocabularySnippetGroup: Identifiable, Equatable {
    var id: String { replacement }
    let replacement: String
    let triggers: [String]
}

enum VocabularySnippetGrouping {
    /// 由主词库生成且仍有对应主词条的兼容副本，不是独立的固定替换入口。
    /// 只隐藏来源明确的副本；外部改值、无对应主词条和应用专属规则仍保持可见。
    static func standaloneReplacements(
        in snippets: [(trigger: String, value: String)],
        terms: [TerminologyEntry],
        ownedCorrections: [String: String]
    ) -> [(trigger: String, value: String)] {
        var represented: [String: Set<String>] = [:]
        for term in terms where term.scope.kind == .global && term.isEnabled
            && term.origin != .builtIn && term.origin != .contextCandidate {
            for alias in term.aliases {
                represented[TerminologyText.normalizedKey(alias.text), default: []]
                    .insert(TerminologyText.normalizedKey(term.canonicalText))
            }
        }
        return snippets.filter { snippet in
            guard !SnippetStorage.isDraftTrigger(snippet.trigger),
                  !TerminologyMigration.isEligibleTerminologySnippet(trigger: snippet.trigger, value: snippet.value)
            else { return false }
            let aliasKey = TerminologyText.normalizedKey(snippet.trigger)
            let canonicalKey = TerminologyText.normalizedKey(snippet.value)
            return ownedCorrections[aliasKey] != canonicalKey
                || represented[aliasKey]?.contains(canonicalKey) != true
        }
    }

    static func groups(for snippets: [(trigger: String, value: String)]) -> [VocabularySnippetGroup] {
        var orderedReplacements: [String] = []
        var triggersByReplacement: [String: [String]] = [:]

        for snippet in snippets {
            if triggersByReplacement[snippet.value] == nil {
                orderedReplacements.append(snippet.value)
            }
            triggersByReplacement[snippet.value, default: []].append(snippet.trigger)
        }

        return orderedReplacements.map { replacement in
            VocabularySnippetGroup(
                replacement: replacement,
                triggers: triggersByReplacement[replacement, default: []]
            )
        }
    }
}
