import Foundation

struct VoicePolishTerminologyEntry: Sendable, Equatable {
    let entryID: UUID
    let canonicalText: String
    let aliases: [TerminologyAlias]
    let origin: TerminologyOrigin
    let scope: TerminologyScope
}

struct TerminologyProjectionBundle: Sendable, Equatable {
    /// 下发 ASR 的标准写法；保留用户优先、内置词靠后的稳定顺序。
    let hotwords: [String]
    /// 用户已确认且无歧义的 alias → canonical 本地确定性纠正。
    let corrections: [String: String]
    /// Voice Polish 使用的完整实体信息，包含来源、证据与作用域。
    let voicePolishEntries: [VoicePolishTerminologyEntry]
    /// 冲突只报告不覆盖，冲突 alias 不进入 corrections。
    let conflicts: [TerminologyConflict]

    /// EntityResolver 的兼容输入。这里使用已经过作用域、覆盖与冲突处理的投影，
    /// 避免试跑或其他入口再次拼接三套旧词库而得到不同结果。
    var personalLexicon: PersonalLexiconDocument {
        PersonalLexiconDocument(
            schemaVersion: 1,
            entries: voicePolishEntries.map { entry in
                PersonalLexiconEntry(
                    id: entry.entryID,
                    canonical: entry.canonicalText,
                    aliases: entry.aliases.map(\.text),
                    source: Self.personalLexiconSource(for: entry.origin),
                    createdAt: .distantPast
                )
            }
        )
    }

    private static func personalLexiconSource(
        for origin: TerminologyOrigin
    ) -> PersonalLexiconEntrySource {
        switch origin {
        case .confirmedCorrection:
            return .correctionCandidate
        case .legacySnippet, .builtIn:
            return .snippetCopy
        case .manual, .legacyPersonalLexicon, .legacyHotword, .contextCandidate:
            return .manual
        }
    }
}

enum TerminologyProjections {
    /// 词库允许整句替换，但识别提示只下发短词，避免把模板、网址或长句发给 ASR。
    private static func isRecognitionTerm(_ text: String) -> Bool {
        let marks = CharacterSet(charactersIn: "。！？；!?;，,：:\n\r")
        let lower = text.lowercased()
        return (1...64).contains(text.count)
            && text.rangeOfCharacter(from: marks) == nil
            && text.split(whereSeparator: \.isWhitespace).count <= 6
            && !["http://", "https://", "www.", "@"].contains(where: lower.contains)
    }

    static func make(
        from document: TerminologyDocument,
        applicationBundleIdentifier: String? = nil
    ) -> TerminologyProjectionBundle {
        let normalized = TerminologyDocumentNormalizer.normalized(document)
        let bundleIdentifier = applicationBundleIdentifier?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let enabled = normalized.entries.filter { entry in
            guard entry.isEnabled else { return false }
            switch entry.scope.kind {
            case .global:
                return true
            case .application:
                guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
                return entry.scope.applicationBundleIdentifier == bundleIdentifier
            }
        }
        let ordered = enabled.sorted { lhs, rhs in
            if lhs.scope.kind != rhs.scope.kind {
                return lhs.scope.kind == .application
            }
            if lhs.origin.priority != rhs.origin.priority {
                return lhs.origin.priority > rhs.origin.priority
            }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var seenHotwords = Set<String>()
        var hotwords: [String] = []
        for entry in ordered {
            guard isRecognitionTerm(entry.canonicalText) else { continue }
            let key = TerminologyText.normalizedKey(entry.canonicalText)
            guard seenHotwords.insert(key).inserted else { continue }
            hotwords.append(entry.canonicalText)
        }

        let runtimeConflicts = TerminologyDocumentNormalizer.runtimeConflicts(for: enabled)
        let conflictKeys = Set(runtimeConflicts.map(\.normalizedAlias))
        let applicationSurfaceKeys = Set(enabled.filter {
            $0.scope.kind == .application
        }.flatMap { entry in
            [TerminologyText.normalizedKey(entry.canonicalText)]
                + entry.aliases.map { TerminologyText.normalizedKey($0.text) }
        })
        var corrections: [String: String] = [:]
        var seenCorrections = Set<String>()
        for entry in ordered {
            for alias in entry.aliases {
                let key = TerminologyText.normalizedKey(alias.text)
                let storageKey = TerminologyText.aliasStorageKey(alias.text)
                let isShadowedGlobal = entry.scope.kind == .global
                    && applicationSurfaceKeys.contains(key)
                guard !isShadowedGlobal,
                      !conflictKeys.contains(key),
                      seenCorrections.insert(storageKey).inserted else {
                    continue
                }
                corrections[alias.text] = entry.canonicalText
            }
        }

        let voicePolishEntries = ordered.map { entry in
            let aliases = entry.scope.kind == .global
                ? entry.aliases.filter {
                    !applicationSurfaceKeys.contains(TerminologyText.normalizedKey($0.text))
                }
                : entry.aliases
            return VoicePolishTerminologyEntry(
                entryID: entry.id,
                canonicalText: entry.canonicalText,
                aliases: aliases,
                origin: entry.origin,
                scope: entry.scope
            )
        }

        return TerminologyProjectionBundle(
            hotwords: hotwords,
            corrections: corrections,
            voicePolishEntries: voicePolishEntries,
            conflicts: runtimeConflicts
        )
    }
}
