import Foundation

enum EntityResolver {
    static let similarityThreshold = 0.88
    static let confidenceMargin = 0.08
    private static let englishPhoneticThreshold = 0.94
    private static let chinesePinyinThreshold = 0.94

    private struct Candidate: Sendable {
        let alias: String
        let canonical: String
        let source: EntityCandidateSource
        let allowsFuzzy: Bool

        init(
            alias: String,
            canonical: String,
            source: EntityCandidateSource,
            allowsFuzzy: Bool = true
        ) {
            self.alias = alias
            self.canonical = canonical
            self.source = source
            self.allowsFuzzy = allowsFuzzy
        }
    }

    /// Muse 是应用自身拥有的产品名，中文口述“缪斯”是确定别名。只有安全上下文
    /// 已明确出现 canonical 时才启用，并且只做精确别名匹配，不参与开放式跨脚本猜词。
    private static let applicationOwnedContextAliases = [
        "Muse": ["缪斯"],
    ]

    /// 已经由产品测试明确确认、且只允许在安全上下文中启用的中文别名。
    /// 这张表是显式关系，不从共同前缀或全文语义锚点猜测新关系。
    private static let productConfirmedHanContextAliases: [
        String: [(alias: String, sharedScopeCues: [String])]
    ] = [
        "接口联调": [(alias: "接口调试", sharedScopeCues: ["上线"])],
    ]

    private struct NormalizedUnit {
        let character: Character
        let sourceRange: Range<String.Index>
    }

    private struct FlexibleMatch {
        let sourceRange: Range<String.Index>
        let normalizedLength: Int
    }

    private struct CandidateMatch {
        let match: FlexibleMatch
        let candidate: Candidate
    }

    private struct SurfaceRange {
        let text: String
        let range: Range<String.Index>
    }

    private struct RankedCandidate {
        let candidate: Candidate
        let score: Double
    }

    private struct PreparedCandidate {
        let candidate: Candidate
        let englishPhoneticKey: String?
        let chinesePinyinSyllables: [String]?
        let contextPinyinSyllables: [String]?
    }

    private struct ReplacementOperation {
        let range: Range<String.Index>
        let canonical: String
        let sourcePriority: Int
        let confidence: Double
    }

    private struct ContextMappingProposal {
        let surface: String
        let canonical: String
        let segmentID: String
    }

    private enum AuthorizedContextAssertion {
        case affirmed
        case historical
        case hypothetical
        case rejected
        case otherEntity
        case unrelated
        case unproven

        var allowsCandidate: Bool {
            switch self {
            case .affirmed:
                return true
            case .historical, .hypothetical, .rejected, .otherEntity, .unrelated, .unproven:
                return false
            }
        }
    }

    static func resolve(
        segments: [RecognitionSegment],
        lexicon: PersonalLexiconDocument,
        snippets: [(trigger: String, value: String)],
        hotwords: [String],
        context: WritingContext
    ) -> [ResolvedEntity] {
        let candidates = candidateList(
            lexicon: lexicon,
            snippets: snippets,
            hotwords: hotwords,
            context: context
        )
        let preparedCandidates = candidates.map { candidate in
            PreparedCandidate(
                candidate: candidate,
                englishPhoneticKey: candidate.source == .personalLexicon
                    || candidate.source == .authorizedContext
                    ? englishPhoneticKey(candidate.alias)
                    : nil,
                chinesePinyinSyllables: candidate.source == .personalLexicon
                    ? pinyinSyllablesIfChinese(candidate.alias)
                    : nil,
                contextPinyinSyllables: candidate.source == .authorizedContext
                    ? tonelessPinyinSyllablesIfChinese(candidate.alias)
                    : nil
            )
        }
        var resolutions: [ResolvedEntity] = []
        var keys = Set<String>()

        for segment in segments {
            let exactMatches = candidates.flatMap { candidate in
                flexibleMatches(of: candidate.alias, in: segment.text).map {
                    CandidateMatch(match: $0, candidate: candidate)
                }
            }
            for match in selectedExactMatches(exactMatches, in: segment.text) {
                let surface = String(segment.text[match.match.sourceRange])
                guard match.candidate.source != .authorizedContext
                        || allowsAuthorizedContextMapping(
                            surface: surface,
                            canonical: match.candidate.canonical,
                            in: segment.text
                        ) else {
                    continue
                }
                let key = "\(segment.id)|\(presentationKey(surface))|\(presentationKey(match.candidate.canonical))"
                guard keys.insert(key).inserted else { continue }
                resolutions.append(ResolvedEntity(
                    surfaceText: surface,
                    canonical: match.candidate.canonical,
                    sourceSegmentIDs: [segment.id],
                    candidateSource: match.candidate.source,
                    confidence: 1
                ))
            }

            let activePreparedCandidates = preparedCandidates.filter { $0.candidate.allowsFuzzy }
            let fuzzySurfaces = fuzzySurfaceRanges(
                in: segment.text,
                terminologyCandidates: candidates.filter {
                    $0.allowsFuzzy
                        && ($0.source == .personalLexicon || $0.source == .authorizedContext)
                }
            )
            for surface in fuzzySurfaces {
                guard let resolved = resolveSurface(
                    surface.text,
                    candidates: activePreparedCandidates
                ) else { continue }
                guard resolved.source != .authorizedContext
                        || allowsAuthorizedContextMapping(
                            surface: surface.text,
                            canonical: resolved.canonical,
                            in: segment.text
                        ) else {
                    continue
                }
                let key = "\(segment.id)|\(presentationKey(surface.text))|\(presentationKey(resolved.canonical))"
                guard keys.insert(key).inserted else { continue }
                resolutions.append(ResolvedEntity(
                    surfaceText: surface.text,
                    canonical: resolved.canonical,
                    sourceSegmentIDs: [segment.id],
                    candidateSource: resolved.source,
                    confidence: resolved.score
                ))
            }
        }

        // selected/nearby safe context 还允许两类受限映射：可证明的跨脚本
        // 音译，以及产品明确确认的中文 alias。开放式 Han→Han 音近纠错已在
        // 上面的唯一高置信通道完成，这里不再从共同前缀或任意锚点猜词。
        for resolution in contextAnchoredResolutions(
            segments: segments,
            context: context
        ) {
            let key = "\(resolution.sourceSegmentIDs.first ?? "")|\(presentationKey(resolution.surfaceText))|\(presentationKey(resolution.canonical))"
            guard keys.insert(key).inserted else { continue }
            resolutions.append(resolution)
        }
        return resolutions
    }

    /// 只替换已经由 resolve 命中的实体范围。替换操作先在原文上统一定位，
    /// 再从后向前落盘，避免 sequential global replace 产生级联或误伤单词子串。
    static func applying(_ resolutions: [ResolvedEntity], to text: String) -> String {
        let operations = resolutions.flatMap { resolution -> [ReplacementOperation] in
            guard resolution.confidence >= similarityThreshold,
                  !resolution.surfaceText.isEmpty,
                  !resolution.canonical.isEmpty,
                  resolution.surfaceText != resolution.canonical else { return [] }
            return flexibleMatches(of: resolution.surfaceText, in: text).map {
                ReplacementOperation(
                    range: $0.sourceRange,
                    canonical: resolution.canonical,
                    sourcePriority: resolution.candidateSource.priority,
                    confidence: resolution.confidence
                )
            }
        }
        let selected = selectedReplacementOperations(operations, in: text)
        var output = text
        for operation in selected.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            output.replaceSubrange(operation.range, with: operation.canonical)
        }
        return output
    }

    /// 将统一术语仓库已确认、无冲突的 alias 规则应用到 canonical 文本。
    /// 这里只做灵活精确匹配，不启用 fuzzy 推断，保证确定性纠错不会猜词。
    static func applyingKnownCorrections(
        _ corrections: [String: String],
        to text: String
    ) -> String {
        let candidates = corrections.map {
            Candidate(alias: $0.key, canonical: $0.value, source: .personalLexicon)
        }
        let matches = candidates.flatMap { candidate in
            flexibleMatches(of: candidate.alias, in: text).map {
                CandidateMatch(match: $0, candidate: candidate)
            }
        }
        let resolutions = selectedExactMatches(matches, in: text).map { match in
            ResolvedEntity(
                surfaceText: String(text[match.match.sourceRange]),
                canonical: match.candidate.canonical,
                sourceSegmentIDs: ["s1"],
                candidateSource: match.candidate.source,
                confidence: 1
            )
        }
        return applying(resolutions, to: text)
    }

    static func editSimilarity(_ left: String, _ right: String) -> Double {
        let a = Array(normalized(left))
        let b = Array(normalized(right))
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        var previous = Array(0...b.count)
        for (i, leftCharacter) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, rightCharacter) in b.enumerated() {
                current[j + 1] = min(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(longest)
    }

    /// 自动记词专用的保守判定：只接受可解释为 ASR 同音/近音或明显拼写
    /// 偏差的词对。它不判断语义，也不把两个不同意思的正常换词当成识别错误。
    static func isLikelySpeechRecognitionCorrection(alias: String, canonical: String) -> Bool {
        let left = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty, left.lowercased() != right.lowercased() else { return false }

        if let leftSyllables = pinyinSyllablesIfChinese(left),
           let rightSyllables = pinyinSyllablesIfChinese(right),
           let score = chinesePinyinSimilarity(leftSyllables, rightSyllables),
           score >= chinesePinyinThreshold {
            return true
        }
        if let leftSyllables = tonelessPinyinSyllablesIfChinese(left),
           let rightSyllables = tonelessPinyinSyllablesIfChinese(right),
           let score = chinesePinyinSimilarity(leftSyllables, rightSyllables),
           score >= 0.97 {
            return true
        }
        if let leftKey = englishPhoneticKey(left),
           let rightKey = englishPhoneticKey(right),
           editSimilarity(
               leftKey.replacingOccurrences(of: "|", with: ""),
               rightKey.replacingOccurrences(of: "|", with: "")
           ) >= englishPhoneticThreshold {
            return true
        }
        guard isASCIIWordLike(left) && isASCIIWordLike(right) else {
            return false
        }
        let compactLeft = left.replacingOccurrences(of: " ", with: "")
        let compactRight = right.replacingOccurrences(of: " ", with: "")
        let score = editSimilarity(compactLeft.lowercased(), compactRight.lowercased())
        return score >= similarityThreshold
    }

    /// 只用于提出需用户确认的候选，不自动建立替换。弱元音、清浊音和
    /// 词尾 /ts/、/s/ 可能混淆，但辅音结构相同仍不能证明是识别错误。
    static func isPossibleEnglishSpeechCorrection(_ left: String, _ right: String) -> Bool {
        if isEnglishLetterFragmentCorrection(left, right) { return true }
        func isLongWord(_ word: String) -> Bool {
            (7...32).contains(word.count) && word.unicodeScalars.allSatisfy {
                $0.isASCII && CharacterSet.letters.contains($0)
            }
        }
        guard isLongWord(left), isLongWord(right),
              Double(min(left.count, right.count)) / Double(max(left.count, right.count)) >= 0.75,
              editSimilarity(left, right) >= 0.5,
              let leftKey = englishPhoneticKey(left), let rightKey = englishPhoneticKey(right),
              abs(leftKey.filter({ $0 == "a" }).count - rightKey.filter({ $0 == "a" }).count) <= 1
        else { return false }

        func consonants(_ key: String) -> String {
            var result = ""
            for character in key where character != "a" {
                let folded: Character
                switch character {
                case "b": folded = "p"
                case "d": folded = "t"
                case "g": folded = "k"
                case "v": folded = "f"
                case "z": folded = "s"
                default: folded = character
                }
                if result.last != folded { result.append(folded) }
            }
            return result
        }
        let leftConsonants = consonants(leftKey)
        let rightConsonants = consonants(rightKey)
        guard leftConsonants.hasSuffix("s"), rightConsonants.hasSuffix("s"),
              leftConsonants.hasSuffix("ts") != rightConsonants.hasSuffix("ts")
        else { return false }
        func simplifyFinalCluster(_ value: String) -> String {
            value.hasSuffix("ts") ? String(value.dropLast(2)) + "s" : value
        }
        let signature = simplifyFinalCluster(leftConsonants)
        return (4...16).contains(signature.count) && signature == simplifyFinalCluster(rightConsonants)
    }

    /// ASR 可把名字前半段听成独立字母。完整后缀及相近拼写只足以提出
    /// 确认，不能据此自动建词，例如多个字母片段再接一个完整英文单词。
    private static func isEnglishLetterFragmentCorrection(_ left: String, _ right: String) -> Bool {
        func lettersOnly(_ word: String) -> Bool {
            !word.isEmpty && word.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.letters.contains($0) }
        }
        let words = left.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (2...4).contains(words.count), (7...32).contains(right.count), lettersOnly(right),
              let suffix = words.last, (4...16).contains(suffix.count), lettersOnly(suffix),
              words.dropLast().allSatisfy({ $0.count == 1 && lettersOnly($0) }),
              right.lowercased().hasSuffix(suffix.lowercased()) else { return false }
        let compact = words.joined()
        return Double(min(compact.count, right.count)) / Double(max(compact.count, right.count)) >= 0.5
            && editSimilarity(compact, right) >= 0.5
    }

    private static func resolveSurface(
        _ surface: String,
        candidates: [PreparedCandidate]
    ) -> (canonical: String, source: EntityCandidateSource, score: Double)? {
        // 每个 surface 的转写只做一次；候选侧的发音键在本次 resolve 开始时预计算，
        // 避免中文滑窗 × 术语数量重复调用 Foundation transliteration 拉长本地延迟。
        let surfaceEnglishKey = englishPhoneticKey(surface)
        let surfacePinyinSyllables = pinyinSyllablesIfChinese(surface)
        let ranked = candidates.compactMap { prepared -> RankedCandidate? in
            let candidate = prepared.candidate
            let editScore = editSimilarity(surface, candidate.alias)
            var qualifiedScores = editScore >= similarityThreshold ? [editScore] : []

            // 个人词库继续使用带声调的严格发音通道。显式授权的安全上下文可
            // 作为更低优先级候选，但只允许唯一近似实体，不把上下文整句抄入正文。
            if candidate.source == .personalLexicon {
                if let leftKey = surfaceEnglishKey,
                   let rightKey = prepared.englishPhoneticKey {
                    let score = editSimilarity(leftKey, rightKey)
                    if score >= englishPhoneticThreshold {
                        qualifiedScores.append(score)
                    }
                }
                if let leftSyllables = surfacePinyinSyllables,
                   let rightSyllables = prepared.chinesePinyinSyllables,
                   let score = chinesePinyinSimilarity(leftSyllables, rightSyllables),
                   score >= chinesePinyinThreshold {
                    qualifiedScores.append(score)
                }
            } else if candidate.source == .authorizedContext {
                if let leftSyllables = tonelessPinyinSyllablesIfChinese(surface),
                   let rightSyllables = prepared.contextPinyinSyllables,
                   let score = chinesePinyinSimilarity(leftSyllables, rightSyllables),
                   score >= 0.9 {
                    qualifiedScores.append(max(0.92, score))
                }
            }
            guard let score = qualifiedScores.max() else { return nil }
            return RankedCandidate(candidate: candidate, score: score)
        }.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.candidate.source.priority > right.candidate.source.priority
        }
        guard let best = ranked.first else { return nil }
        let competitor = ranked.first {
            normalized($0.candidate.canonical) != normalized(best.candidate.canonical)
        }
        guard competitor == nil || best.score - competitor!.score >= confidenceMargin else { return nil }
        return (best.candidate.canonical, best.candidate.source, best.score)
    }

    private static func candidateList(
        lexicon: PersonalLexiconDocument,
        snippets: [(trigger: String, value: String)],
        hotwords: [String],
        context: WritingContext
    ) -> [Candidate] {
        var result: [Candidate] = []
        for entry in lexicon.entries where entry.isEnabled {
            result.append(Candidate(alias: entry.canonical, canonical: entry.canonical, source: .personalLexicon))
            result.append(contentsOf: entry.aliases.map {
                Candidate(alias: $0, canonical: entry.canonical, source: .personalLexicon)
            })
        }
        for snippet in snippets where !SnippetStorage.isDraftTrigger(snippet.trigger) {
            result.append(Candidate(
                alias: snippet.trigger,
                canonical: snippet.value,
                source: .snippet
            ))
            // 确定性纠错后 envelope 已经是 canonical；把标准写法也加入候选，
            // 让后续 LLM/Validator 继续把它当成受保护实体。
            result.append(Candidate(
                alias: snippet.value,
                canonical: snippet.value,
                source: .snippet
            ))
        }
        result.append(contentsOf: hotwords.map {
            Candidate(alias: $0, canonical: $0, source: .hotword)
        })
        if context.safety == .safe {
            var authorizedBodies = context.recentMuseInputs
            if context.level != .metadataOnly {
                authorizedBodies.append(contentsOf: [
                    context.selectedText,
                    context.textBeforeCursor,
                    context.textAfterCursor,
                ].compactMap { $0 })
            }
            result.append(contentsOf: authorizedBodies.flatMap { body in
                authorizedContextTerms(in: body)
                    .filter { hasAffirmedContextProvenance(for: $0, in: body) }
                    .flatMap { term -> [Candidate] in
                        var candidates = [
                            Candidate(alias: term, canonical: term, source: .authorizedContext),
                        ]
                        for alias in applicationOwnedContextAliases[term] ?? [] {
                            candidates.append(Candidate(
                                alias: alias,
                                canonical: term,
                                source: .authorizedContext,
                                allowsFuzzy: false
                            ))
                        }
                        return candidates
                    }
            })
        }
        return deduplicated(result)
    }

    private static func contextAnchoredResolutions(
        segments: [RecognitionSegment],
        context: WritingContext
    ) -> [ResolvedEntity] {
        guard context.safety == .safe else { return [] }
        // 开放式“锚点 + 别名”推导只允许用户当前明确授权的选中/邻近文本。
        // recentMuseInputs 仍可走既有的同文种高置信与应用自有 exact alias，
        // 但不能仅凭一条历史输入把任意相邻中文短语映射到英文名称。
        guard context.level != .metadataOnly else { return [] }
        let bodies = [
            context.selectedText,
            context.textBeforeCursor,
            context.textAfterCursor,
        ].compactMap { $0 }
        let evidence = bodies.flatMap { body in
            authorizedContextTerms(in: body).compactMap { term -> (String, String)? in
                hasAffirmedContextProvenance(for: term, in: body)
                    ? (term, body)
                    : nil
            }
        }

        var proposals: [ContextMappingProposal] = []
        for segment in segments {
            for (canonical, body) in evidence {
                let aliases: [String]
                if canonical.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil {
                    aliases = asciiContextAliases(
                        canonical: canonical,
                        contextBody: body,
                        source: segment.text
                    )
                } else {
                    aliases = hanContextAliases(
                        canonical: canonical,
                        contextBody: body,
                        source: segment.text
                    )
                }
                for alias in aliases where allowsAuthorizedContextMapping(
                    surface: alias,
                    canonical: canonical,
                    in: segment.text
                ) {
                    proposals.append(ContextMappingProposal(
                        surface: alias,
                        canonical: canonical,
                        segmentID: segment.id
                    ))
                }
            }
        }

        let grouped = Dictionary(grouping: proposals) {
            "\($0.segmentID)|\(presentationKey($0.surface))"
        }
        return grouped.values.compactMap { matches in
            let canonicals = Set(matches.map { presentationKey($0.canonical) })
            guard canonicals.count == 1, let match = matches.first else { return nil }
            return ResolvedEntity(
                surfaceText: match.surface,
                canonical: match.canonical,
                sourceSegmentIDs: [match.segmentID],
                candidateSource: .authorizedContext,
                confidence: 0.99
            )
        }
    }

    /// ASCII 标准名只有在它旁边的中文语义锚点也出现在 source，且该锚点前
    /// 存在唯一中文名称时才建立映射。例如 `Claude Desktop 配置` 可约束
    /// “克劳德桌面版的配置”，但上下文里孤立出现一个英文词不会触发。
    private static func asciiContextAliases(
        canonical: String,
        contextBody: String,
        source: String
    ) -> [String] {
        let anchors = contextualAnchorTokens(
            excluding: canonical,
            in: contextBody
        ).filter { source.contains($0) }
        var rankedAliases: [(surface: String, score: Double)] = []
        for anchor in anchors {
            let escaped = NSRegularExpression.escapedPattern(for: anchor)
            let pattern = #"([\p{Han}]{2,12}?)(?:的)?\s*"# + escaped
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, range: range) {
                guard match.numberOfRanges > 1,
                      let capture = Range(match.range(at: 1), in: source) else { continue }
                var captured = String(source[capture])
                for prefix in ["请把", "请用", "关于", "这个", "那个", "把", "用", "在", "将"]
                    where captured.hasPrefix(prefix) && captured.count - prefix.count >= 2 {
                    captured.removeFirst(prefix.count)
                    break
                }
                let characters = Array(captured)
                guard characters.count >= 2 else { continue }
                for length in 2...min(12, characters.count) {
                    let alias = String(characters.suffix(length))
                    guard let score = crossScriptAliasScore(
                        surface: alias,
                        canonical: canonical
                    ) else { continue }
                    rankedAliases.append((alias, score))
                }
            }
        }
        guard let bestScore = rankedAliases.map(\.score).max() else { return [] }
        // 同一名称若有两个互不包含且同分的中文候选，无法确定哪一个才是
        // ASR 别名；留给模型处理，不做本地强制替换。
        let best = rankedAliases.filter { bestScore - $0.score < 0.02 }
        let distinct = Array(Set(best.map(\.surface)))
        let minimal = distinct.filter { candidate in
            !distinct.contains { other in
                other != candidate && other.hasSuffix(candidate)
                    && other.count > candidate.count
            }
        }
        return minimal.count == 1 ? minimal : []
    }

    /// 只在“音译主体足够接近”时接受跨脚本别名。像 Claude Desktop 这类
    /// 混合音译 + 通用产品形态允许有限的语义后缀；不会因为共享“配置/服务”
    /// 就把大梁老师、Chrome 或任意中文名改成上下文里的英文产品名。
    private static func crossScriptAliasScore(
        surface: String,
        canonical: String
    ) -> Double? {
        guard surface.allSatisfy(isHanCharacter), isASCIIWordLike(canonical) else {
            return nil
        }
        let words = canonical.lowercased().split {
            !$0.unicodeScalars.allSatisfy(\.isASCII) || !$0.isLetter
        }.map(String.init)
        guard !words.isEmpty else { return nil }

        let semanticSuffixes: [String: [String]] = [
            "desktop": ["桌面客户端", "桌面版", "桌面"],
        ]
        if words.count >= 2,
           let suffixes = semanticSuffixes[words.last!],
           let suffix = suffixes.first(where: surface.hasSuffix) {
            let head = String(surface.dropLast(suffix.count))
            guard head.count >= 2,
                  let score = crossScriptConsonantSimilarity(
                    surface: head,
                    canonical: words.dropLast().joined(separator: " ")
                  ),
                  score >= 0.9 else { return nil }
            return score
        }

        guard let score = crossScriptConsonantSimilarity(
            surface: surface,
            canonical: canonical
        ), score >= 0.78 else { return nil }
        return score
    }

    private static func crossScriptConsonantSimilarity(
        surface: String,
        canonical: String
    ) -> Double? {
        guard let syllables = tonelessPinyinSyllablesIfChinese(surface) else {
            return nil
        }
        let left = String(syllables.compactMap(\.first).map(normalizedSoundConsonant))
        let rightRaw = canonical.lowercased().filter {
            $0.isLetter && !"aeiouy".contains($0)
        }
        let right = String(rightRaw.map(normalizedSoundConsonant))
        guard left.count >= 3, right.count >= 3 else { return nil }
        return editSimilarity(left, right)
    }

    private static func normalizedSoundConsonant(_ character: Character) -> Character {
        switch character {
        case "c", "k", "q", "s", "x", "z": return "k"
        case "f", "v", "w": return "v"
        case "r", "l": return "l"
        default: return character
        }
    }

    /// 中文上下文不能凭共同前缀和全文任意语义锚点建立确定性替换，否则
    /// “登录失败仍在排查”会被“登录流程刚完成排查”误改。开放式中文纠错
    /// 已由 resolveSurface 的唯一高置信音近通道负责；这里仅返回产品明确
    /// 确认过的 alias，并仍受安全上下文 provenance 与冲突消解约束。
    private static func hanContextAliases(
        canonical: String,
        contextBody: String,
        source: String
    ) -> [String] {
        guard let aliases = productConfirmedHanContextAliases[canonical] else {
            return []
        }
        return aliases.flatMap { rule -> [String] in
            // 同一条已确认 alias 仍需落在相同的明确业务范围；范围词也来自
            // 规则本身，而不是从上下文全文临时寻找任意重合词。
            guard rule.sharedScopeCues.contains(where: {
                contextBody.contains($0) && source.contains($0)
            }) else { return [] }
            return flexibleMatches(of: rule.alias, in: source).map {
                String(source[$0.sourceRange])
            }
        }
    }

    private static func contextualAnchorTokens(
        excluding canonical: String,
        in body: String
    ) -> [String] {
        let remainder = body.replacingOccurrences(
            of: canonical,
            with: " ",
            options: [.caseInsensitive, .diacriticInsensitive]
        )
        let ignored: Set<String> = [
            "这个", "那个", "这次", "本次", "当前", "已经", "正在", "刚刚",
            "完成", "以后", "时间", "记录", "说明", "检查", "测试", "确认",
            "更新", "错误", "候选", "仅作", "上下", "文泄", "泄漏",
        ]
        var tokens: Set<String> = []
        for run in hanRuns(in: remainder) {
            let characters = Array(run)
            guard characters.count >= 2 else { continue }
            for length in 2...min(4, characters.count) {
                for start in 0...(characters.count - length) {
                    let token = String(characters[start..<(start + length)])
                    guard !ignored.contains(token),
                          !canonical.contains(token) else { continue }
                    tokens.insert(token)
                }
            }
        }
        return tokens.sorted { left, right in
            if left.count != right.count { return left.count > right.count }
            return left < right
        }
    }

    private static func hanRuns(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[\p{Han}]{2,64}"#) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func isHanCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) }
    }

    private static func authorizedContextTerms(in text: String) -> [String] {
        let bounded = String(text.prefix(1_024))
        var terms: [String] = []

        for pattern in [#"[“\"]([^”\"\n]{2,64})[”\"]"#, #"`([^`\n]{2,64})`"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(bounded.startIndex..<bounded.endIndex, in: bounded)
            terms.append(contentsOf: regex.matches(in: bounded, range: range).compactMap { match in
                guard match.numberOfRanges > 1,
                      let capture = Range(match.range(at: 1), in: bounded) else { return nil }
                return String(bounded[capture])
            })
        }

        if let asciiRegex = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9])([A-Za-z][A-Za-z0-9]*(?:[ _-]+[A-Za-z][A-Za-z0-9]*){0,2})(?![A-Za-z0-9])"#
        ) {
            let range = NSRange(bounded.startIndex..<bounded.endIndex, in: bounded)
            terms.append(contentsOf: asciiRegex.matches(in: bounded, range: range).compactMap {
                guard let capture = Range($0.range(at: 1), in: bounded) else { return nil }
                return String(bounded[capture])
            })
        }

        // 用户安全选中的标题常见形态是“北辰研究：个人语音输入产品对比”。
        // 冒号前的首行标题本身就是当前肯定实体，不能因为没有引号或“已确认”
        // 四个字而漏掉。只取文本开头 2...16 个汉字，并排除常见字段标签；
        // 历史、假设、错误候选仍会在 provenance gate 中被拒绝。
        if let leadingTitleRegex = try? NSRegularExpression(
            pattern: #"^\s*([\p{Han}]{2,16})\s*[：:]"#
        ) {
            let range = NSRange(bounded.startIndex..<bounded.endIndex, in: bounded)
            let genericLabels: Set<String> = [
                "项目名", "项目名称", "标题", "名称", "产品名", "产品名称",
                "负责人", "截止时间", "时间", "日期", "状态", "备注", "内容",
                "说明", "任务", "目标", "版本",
            ]
            if let match = leadingTitleRegex.firstMatch(in: bounded, range: range),
               let capture = Range(match.range(at: 1), in: bounded) {
                let title = String(bounded[capture])
                if !genericLabels.contains(title) {
                    terms.append(title)
                }
            }
        }

        let cueWords = [
            "刚", "已", "正在", "已经", "即将", "将要", "这次", "本次", "中的",
            "里面", "排期", "配置", "部署", "构建", "启动", "确认", "更新", "修复",
            "发布", "上线", "说明", "记录",
        ]
        if let hanRegex = try? NSRegularExpression(pattern: #"[\p{Han}]{2,64}"#) {
            let range = NSRange(bounded.startIndex..<bounded.endIndex, in: bounded)
            for match in hanRegex.matches(in: bounded, range: range) {
                guard let runRange = Range(match.range, in: bounded) else { continue }
                var run = String(bounded[runRange])
                for prefix in ["当前", "本次", "这次", "这个", "该"] where run.hasPrefix(prefix) {
                    run.removeFirst(prefix.count)
                    break
                }
                let cueRange = cueWords.compactMap { run.range(of: $0) }
                    .filter { run.distance(from: run.startIndex, to: $0.lowerBound) >= 2 }
                    .min { left, right in left.lowerBound < right.lowerBound }
                if let cueRange {
                    let term = String(run[..<cueRange.lowerBound])
                    if (2...16).contains(term.count) { terms.append(term) }
                }
            }
        }

        var seen = Set<String>()
        return terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { (2...64).contains($0.count) }
            .filter { seen.insert(normalized($0)).inserted }
            .prefix(128)
            .map { $0 }
    }

    /// 上下文里“出现过某个名称”不等于“已确认它就是当前实体”。每个候选必须
    /// 至少有一处肯定来源；旧称、假设、错误候选、同名他人和无关实体只淘汰
    /// 自己所在的语义片段，不会关闭同一段上下文中的其他可靠候选。
    private static func hasAffirmedContextProvenance(
        for term: String,
        in text: String
    ) -> Bool {
        let bounded = String(text.prefix(1_024))
        let matches = flexibleMatches(of: term, in: bounded)
        guard !matches.isEmpty else { return false }
        return matches.contains { match in
            authorizedContextAssertion(
                for: match.sourceRange,
                in: bounded
            ).allowsCandidate
        }
    }

    private static func authorizedContextAssertion(
        for candidateRange: Range<String.Index>,
        in text: String
    ) -> AuthorizedContextAssertion {
        let fragmentRange = semanticFragmentRange(containing: candidateRange, in: text)
        let prefix = compactAssertionText(String(text[fragmentRange.lowerBound..<candidateRange.lowerBound]))
        let suffix = compactAssertionText(String(text[candidateRange.upperBound..<fragmentRange.upperBound]))
        let prefixTail = String(prefix.suffix(40))
        let suffixHead = String(suffix.prefix(40))

        let historicalPrefixes = [
            "旧项目", "旧产品", "历史项目", "历史产品", "旧名", "旧称",
            "曾用名", "以前叫", "过去叫", "原来叫", "曾叫", "曾经叫",
        ]
        let historicalSuffixes = [
            "是旧名", "是旧称", "是曾用名", "只是旧名", "只是旧称",
        ]
        if historicalPrefixes.contains(where: prefixTail.contains)
            || historicalSuffixes.contains(where: suffixHead.contains) {
            return .historical
        }

        let hypotheticalPrefixes = [
            "如果", "假如", "假设", "要是", "若定为", "若命名为", "若改名",
            "计划改名", "考虑改名", "以后改名", "未来改名", "暂定为",
            "听说", "据说", "有人说", "传闻",
        ]
        let hypotheticalSuffixes = [
            "未确认", "还未确认", "尚未确认", "还没确认", "没有确认",
            "待确认", "尚未确定", "还没确定", "仍不确定",
        ]
        if hypotheticalPrefixes.contains(where: prefixTail.contains)
            || hypotheticalSuffixes.contains(where: suffixHead.contains) {
            return .hypothetical
        }

        let rejectedPrefixes = [
            "错误候选", "错误名称", "错误名字", "错误写法", "无效候选",
            "已否决的候选", "排除的候选", "误写为", "错写成",
        ]
        let rejectedSuffixes = [
            "是错误候选", "是错误名称", "这个写法不对", "不要使用",
            "不能使用", "已被否决", "已经排除",
        ]
        if rejectedPrefixes.contains(where: prefixTail.contains)
            || rejectedSuffixes.contains(where: suffixHead.contains) {
            return .rejected
        }

        let otherEntityPrefixes = [
            "同名的另一位", "同名另一位", "同名的另一个", "同名另一个",
            "另一位同名", "另一个同名",
        ]
        let otherEntitySuffixes = [
            "是另一位", "是另一个", "指另一位", "指另一个",
        ]
        if otherEntityPrefixes.contains(where: prefixTail.contains)
            || otherEntitySuffixes.contains(where: suffixHead.contains) {
            return .otherEntity
        }

        let unrelatedSuffixes = [
            "与本次无关", "和本次无关", "与当前无关", "和当前无关",
            "不是本次的", "不是当前的", "不是本次产品名", "不是当前产品名",
            "并非本次产品名", "并非当前产品名", "不属于本次", "不属于当前",
            "不要用于当前", "请勿用于当前", "不能用于当前", "禁止用于当前",
            "只属于历史记录", "已停用", "已经停用", "已弃用", "已经弃用",
            "不再使用", "只是演示例子", "仅是演示例子",
        ]
        if unrelatedSuffixes.contains(where: suffixHead.contains) {
            return .unrelated
        }

        let rawPrefix = String(text[fragmentRange.lowerBound..<candidateRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSuffix = String(text[candidateRange.upperBound..<fragmentRange.upperBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if rawPrefix.isEmpty, rawSuffix.hasPrefix("：") || rawSuffix.hasPrefix(":") {
            return .affirmed
        }

        let affirmedPrefixes = [
            "项目统一名称是", "统一名称是", "正式名称是", "标准名称是",
            "正确名称是", "正确写法是",
            // 书面语常用“为”，与“是”同义。
            "项目统一名称为", "统一名称为", "正式名称为", "标准名称为",
            "正确名称为", "正确写法为",
            "当前项目的名称已确认为", "当前项目的名称是",
            "当前项目名称已确认为", "当前项目名称是", "当前项目是", "当前项目:",
            "当前项目：", "当前产品是", "当前产品:", "当前产品：",
            "本次项目是", "本次项目:", "本次项目：", "本次产品是",
            "本次产品:", "本次产品：", "当前工单产品:", "当前工单产品：",
            "客户当前使用的软件是",
            "当前仓库托管在", "正在审查", "当前使用", "本次使用",
        ]
        let affirmedSuffixes = [
            "刚确认", "已确认", "已经确认", "已确认为", "正在使用", "当前使用",
            "刚刚结束", "刚结束", "已经结束", "已结束", "刚刚完成", "刚完成",
            "构建正在", "构建已经", "构建已", "服务启动", "服务部署",
            "配置", "排期", "部署", "构建", "启动", "更新", "修复",
            "发布", "上线", "说明", "记录", "审查", "中的", "里面",
        ]
        if affirmedPrefixes.contains(where: prefixTail.contains)
            || affirmedSuffixes.contains(where: suffixHead.contains) {
            return .affirmed
        }
        return .unproven
    }

    private static func semanticFragmentRange(
        containing candidateRange: Range<String.Index>,
        in text: String
    ) -> Range<String.Index> {
        var lowerBound = candidateRange.lowerBound
        while lowerBound > text.startIndex {
            let previous = text.index(before: lowerBound)
            guard !isContextFragmentBoundary(text[previous]) else { break }
            lowerBound = previous
        }

        var upperBound = candidateRange.upperBound
        while upperBound < text.endIndex {
            guard !isContextFragmentBoundary(text[upperBound]) else { break }
            upperBound = text.index(after: upperBound)
        }
        return lowerBound..<upperBound
    }

    private static func isContextFragmentBoundary(_ character: Character) -> Bool {
        "，,。！!？?；;\n\r".contains(character)
    }

    private static func compactAssertionText(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .filter { !$0.isWhitespace }
    }

    /// 安全上下文只能帮助纠正用户没有否认的具体 A→B 映射。这里按候选关系
    /// 局部判断，而不是看到整段任意“不要/保留”就关掉全部上下文纠错：
    /// “缪斯构建完成，不要把日志发给客户”仍可纠正产品名；
    /// “别把缪斯换成 Muse”则必须尊重用户对该映射的明确否定。
    private static func allowsAuthorizedContextMapping(
        surface: String,
        canonical: String,
        in text: String
    ) -> Bool {
        let surfaceKey = normalized(surface)
        let canonicalKey = normalized(canonical)
        guard !surfaceKey.isEmpty,
              !canonicalKey.isEmpty,
              surfaceKey != canonicalKey else { return true }

        let compact = text.filter { !$0.isWhitespace }
        let alias = NSRegularExpression.escapedPattern(for: surfaceKey)
        let target = NSRegularExpression.escapedPattern(for: canonicalKey)
        let sameClause = #"[^，,。！？!?；;\n]{0,18}"#
        let softSeparator = #"[，,：:]?"#
        let patterns = [
            // 用户直接否认 A 与 B 是同一个实体。
            "\(alias)\(softSeparator)\(sameClause)(?:不是|并非|不等于|不同于)\(sameClause)\(target)",
            "\(target)\(softSeparator)\(sameClause)(?:不是|并非|不等于|不同于)\(sameClause)\(alias)",
            "\(alias)\(sameClause)(?:和|与)\(sameClause)\(target)\(sameClause)(?:无关|不是一回事|不是一个东西|不是同一个|不同)",
            "\(target)\(sameClause)(?:和|与)\(sameClause)\(alias)\(sameClause)(?:无关|不是一回事|不是一个东西|不是同一个|不同)",
            // 用户明确要求不要把 A 改写成 B。
            "(?:不要|别|请勿)\(sameClause)(?:把)?\(alias)\(sameClause)(?:改|换|替换|纠正|校正|写)\(sameClause)(?:成|为)?\(sameClause)\(target)",
            "(?:不要|别|请勿)\(sameClause)(?:把)?\(target)\(sameClause)(?:改|换|替换|纠正|校正|写)\(sameClause)(?:成|为)?\(sameClause)\(alias)",
            "(?:请)?(?:照录|原样保留|保留原词|维持原词)\(sameClause)\(alias)",
            "\(alias)\(sameClause)(?:保持原样|保留原文|保留原词|维持原词|别改写|不要改写|暂时别替换|暂不替换)",
            // 即使没有再次说出 B，只要同一小句明确说 A 尚未确认、有歧义或
            // 不是产品名，也不能利用上下文替用户作决定。
            "\(alias)\(sameClause)(?:名字|名称|写法|词|术语)?\(sameClause)(?:没确认|未确认|还没确认|尚未确定|不确定|有歧义|不是产品名)",
        ]
        return !patterns.contains { pattern in
            compact.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    /// 为编辑距离与两个发音通道提供有界候选窗口。英文最多四个 token；中文只在
    /// 连续汉字 run 内、按白名单术语长度 ±1 滑窗，因此不会枚举整段正文的任意子串。
    private static func fuzzySurfaceRanges(
        in text: String,
        terminologyCandidates: [Candidate]
    ) -> [SurfaceRange] {
        let baseTokenRanges = tokenRanges(in: text)
        var surfaces: [SurfaceRange] = baseTokenRanges
        let wordRanges = baseTokenRanges.filter { isASCIIWordLike($0.text) }
        if wordRanges.count >= 2 {
            for start in wordRanges.indices {
                let maximumCount = min(4, wordRanges.count - start)
                guard maximumCount >= 2 else { continue }
                for count in 2...maximumCount {
                    let group = wordRanges[start..<(start + count)]
                    guard adjacentWordRanges(Array(group), in: text),
                          let first = group.first,
                          let last = group.last else { continue }
                    let range = first.range.lowerBound..<last.range.upperBound
                    surfaces.append(SurfaceRange(text: String(text[range]), range: range))
                }
            }
        }

        let chineseLengths = Set(terminologyCandidates.compactMap { candidate -> Int? in
            guard isAllHan(candidate.alias) else { return nil }
            let count = candidate.alias.count
            return count >= 2 ? count : nil
        })
        if !chineseLengths.isEmpty {
            for run in hanCharacterRuns(in: text) {
                for targetLength in chineseLengths {
                    let minimumLength = max(2, targetLength - 1)
                    let maximumLength = min(run.count, targetLength + 1)
                    guard minimumLength <= maximumLength else { continue }
                    for length in minimumLength...maximumLength {
                        for start in 0...(run.count - length) {
                            let range = run[start].lowerBound..<run[start + length - 1].upperBound
                            surfaces.append(SurfaceRange(text: String(text[range]), range: range))
                        }
                    }
                }
            }
        }

        var seen = Set<String>()
        return surfaces.filter { surface in
            guard (2...64).contains(surface.text.count) else { return false }
            let nsRange = NSRange(surface.range, in: text)
            return seen.insert("\(nsRange.location):\(nsRange.length)").inserted
        }
    }

    private static func tokenRanges(in text: String) -> [SurfaceRange] {
        var result: [SurfaceRange] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let separator = character.isWhitespace || character.isPunctuation
            if separator, let tokenStart = start {
                let range = tokenStart..<index
                result.append(SurfaceRange(text: String(text[range]), range: range))
                start = nil
            } else if !separator, start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let tokenStart = start {
            let range = tokenStart..<text.endIndex
            result.append(SurfaceRange(text: String(text[range]), range: range))
        }
        return result
    }

    private static func adjacentWordRanges(_ ranges: [SurfaceRange], in text: String) -> Bool {
        guard ranges.count >= 2 else { return true }
        for index in 1..<ranges.count {
            let gap = text[ranges[index - 1].range.upperBound..<ranges[index].range.lowerBound]
            guard gap.allSatisfy({ $0.isWhitespace || $0 == "-" }) else { return false }
        }
        return true
    }

    private static func hanCharacterRuns(in text: String) -> [[Range<String.Index>]] {
        var runs: [[Range<String.Index>]] = []
        var current: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if isHan(text[index]) {
                current.append(index..<next)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
            index = next
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// 无外部依赖的保守英文发音键。它只折叠高确定性的拼写差异，并保留词边界；
    /// 最终是否替换仍需经过绝对阈值和候选领先幅度两道门槛。
    private static func englishPhoneticKey(_ value: String) -> String? {
        guard isASCIIWordLike(value) else { return nil }
        let words = value.lowercased().split {
            !$0.unicodeScalars.allSatisfy(\.isASCII) || !$0.isLetter
        }
        guard !words.isEmpty else { return nil }
        let keys = words.compactMap { rawWord -> String? in
            var word = String(rawWord)
            guard word.count >= 2 else { return nil }
            if word.hasPrefix("kn") { word.removeFirst() }
            if word.hasPrefix("wr") { word.removeFirst() }
            let replacements = [
                ("tion", "shun"), ("sion", "shun"), ("tch", "ch"),
                ("dge", "j"), ("igh", "i"), ("ght", "t"),
                ("ph", "f"), ("ck", "k"), ("qu", "k")
            ]
            for (source, target) in replacements {
                word = word.replacingOccurrences(of: source, with: target)
            }
            if word.count > 2, word.hasSuffix("e") { word.removeLast() }
            word = word.replacingOccurrences(of: "c", with: "k")
                .replacingOccurrences(of: "q", with: "k")
                .replacingOccurrences(of: "x", with: "ks")

            var result = ""
            var previous: Character?
            for character in word {
                let normalizedCharacter: Character = "aeiouy".contains(character) ? "a" : character
                guard normalizedCharacter != previous else { continue }
                result.append(normalizedCharacter)
                previous = normalizedCharacter
            }
            return result.count >= 2 ? result : nil
        }
        guard keys.count == words.count else { return nil }
        return keys.joined(separator: "|")
    }

    private static func chinesePinyinSimilarity(
        _ leftSyllables: [String],
        _ rightSyllables: [String]
    ) -> Double? {
        guard abs(leftSyllables.count - rightSyllables.count) <= 1 else { return nil }
        let joinedScore = editSimilarity(
            leftSyllables.joined(separator: "|"),
            rightSyllables.joined(separator: "|")
        )
        guard leftSyllables.count == rightSyllables.count else {
            return joinedScore * 0.9
        }
        let syllableScore = zip(leftSyllables, rightSyllables)
            .map { editSimilarity($0, $1) }
            .reduce(0, +) / Double(leftSyllables.count)
        return max(joinedScore, syllableScore)
    }

    private static func pinyinSyllablesIfChinese(_ value: String) -> [String]? {
        guard isAllHan(value) else { return nil }
        return pinyinSyllables(value)
    }

    private static func tonelessPinyinSyllablesIfChinese(_ value: String) -> [String]? {
        guard isAllHan(value),
              let latin = value.applyingTransform(.mandarinToLatin, reverse: false),
              let toneless = latin.applyingTransform(.stripDiacritics, reverse: false) else {
            return nil
        }
        let syllables = toneless.lowercased().split { !$0.isLetter }.map(String.init)
        return syllables.isEmpty ? nil : syllables
    }

    private static func pinyinSyllables(_ value: String) -> [String]? {
        guard let latin = value.applyingTransform(.mandarinToLatin, reverse: false) else {
            return nil
        }
        // 保留声调符号。去掉声调会把“飞书 / 非数”都折叠成 `fei shu`，
        // 在只有一个白名单候选时造成高置信误替换。
        let normalizedLatin = latin.precomposedStringWithCanonicalMapping.lowercased()
        let syllables = normalizedLatin.split { !$0.isLetter }.map(String.init)
        return syllables.isEmpty ? nil : syllables
    }

    private static func isASCIIWordLike(_ value: String) -> Bool {
        var letterCount = 0
        for scalar in value.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                guard scalar.isASCII else { return false }
                letterCount += 1
            } else if !CharacterSet.whitespacesAndNewlines.contains(scalar),
                      !"-_‐‑‒–—﹘﹣－".unicodeScalars.contains(scalar) {
                return false
            }
        }
        return letterCount >= 4
    }

    private static func isAllHan(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(isHan)
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    private static func deduplicated(_ candidates: [Candidate]) -> [Candidate] {
        var bestByPair: [String: Candidate] = [:]
        for candidate in candidates {
            let aliasKey = normalized(candidate.alias)
            let canonicalKey = normalized(candidate.canonical)
            guard !aliasKey.isEmpty, !canonicalKey.isEmpty else { continue }
            let key = "\(aliasKey)→\(canonicalKey)"
            if let existing = bestByPair[key], existing.source.priority >= candidate.source.priority {
                continue
            }
            bestByPair[key] = candidate
        }
        return Array(bestByPair.values)
    }

    private static func selectedExactMatches(
        _ matches: [CandidateMatch],
        in text: String
    ) -> [CandidateMatch] {
        let byRange = Dictionary(grouping: matches) {
            let range = NSRange($0.match.sourceRange, in: text)
            return "\(range.location):\(range.length)"
        }
        let unambiguous = byRange.values.compactMap { group -> CandidateMatch? in
            let ranked = group.sorted { left, right in
                if left.candidate.source.priority != right.candidate.source.priority {
                    return left.candidate.source.priority > right.candidate.source.priority
                }
                return left.match.normalizedLength > right.match.normalizedLength
            }
            guard let best = ranked.first else { return nil }
            let competitor = ranked.first {
                $0.candidate.source.priority == best.candidate.source.priority
                    && $0.match.normalizedLength == best.match.normalizedLength
                    && normalized($0.candidate.canonical) != normalized(best.candidate.canonical)
            }
            return competitor == nil ? best : nil
        }
        let ranked = unambiguous.sorted { left, right in
            let leftRange = NSRange(left.match.sourceRange, in: text)
            let rightRange = NSRange(right.match.sourceRange, in: text)
            if leftRange.length != rightRange.length { return leftRange.length > rightRange.length }
            if left.candidate.source.priority != right.candidate.source.priority {
                return left.candidate.source.priority > right.candidate.source.priority
            }
            return leftRange.location < rightRange.location
        }
        var selected: [CandidateMatch] = []
        var occupied: [NSRange] = []
        for match in ranked {
            let range = NSRange(match.match.sourceRange, in: text)
            guard occupied.allSatisfy({ NSIntersectionRange($0, range).length == 0 }) else { continue }
            selected.append(match)
            occupied.append(range)
        }
        return selected.sorted {
            $0.match.sourceRange.lowerBound < $1.match.sourceRange.lowerBound
        }
    }

    private static func selectedReplacementOperations(
        _ operations: [ReplacementOperation],
        in text: String
    ) -> [ReplacementOperation] {
        let byRange = Dictionary(grouping: operations) {
            let range = NSRange($0.range, in: text)
            return "\(range.location):\(range.length)"
        }
        let unambiguous = byRange.values.compactMap { group -> ReplacementOperation? in
            let ranked = group.sorted { left, right in
                if left.sourcePriority != right.sourcePriority {
                    return left.sourcePriority > right.sourcePriority
                }
                return left.confidence > right.confidence
            }
            guard let best = ranked.first else { return nil }
            let competitor = ranked.first {
                $0.sourcePriority == best.sourcePriority
                    && $0.confidence == best.confidence
                    && normalized($0.canonical) != normalized(best.canonical)
            }
            return competitor == nil ? best : nil
        }
        let ranked = unambiguous.sorted { left, right in
            let leftRange = NSRange(left.range, in: text)
            let rightRange = NSRange(right.range, in: text)
            if leftRange.length != rightRange.length { return leftRange.length > rightRange.length }
            if left.sourcePriority != right.sourcePriority {
                return left.sourcePriority > right.sourcePriority
            }
            return leftRange.location < rightRange.location
        }
        var selected: [ReplacementOperation] = []
        var occupied: [NSRange] = []
        for operation in ranked {
            let range = NSRange(operation.range, in: text)
            guard occupied.allSatisfy({ NSIntersectionRange($0, range).length == 0 }) else { continue }
            selected.append(operation)
            occupied.append(range)
        }
        return selected
    }

    /// 在忽略大小写、内部空白和连字符的视图上匹配，同时保留到原始 String.Range
    /// 的映射。边界只约束 ASCII 单词，英文术语可以自然嵌在中文句子中。
    private static func flexibleMatches(of alias: String, in text: String) -> [FlexibleMatch] {
        let needle = Array(normalized(alias))
        guard needle.count >= 2 else { return [] }
        let haystack = normalizedUnits(in: text)
        guard haystack.count >= needle.count else { return [] }

        var result: [FlexibleMatch] = []
        for start in 0...(haystack.count - needle.count) {
            let end = start + needle.count
            guard zip(haystack[start..<end], needle).allSatisfy({ $0.character == $1 }) else {
                continue
            }
            let range = haystack[start].sourceRange.lowerBound..<haystack[end - 1].sourceRange.upperBound
            guard hasValidBoundaries(
                range: range,
                first: needle[0],
                last: needle[needle.count - 1],
                in: text
            ) else { continue }
            result.append(FlexibleMatch(
                sourceRange: range,
                normalizedLength: needle.count
            ))
        }
        return result
    }

    private static func normalizedUnits(in value: String) -> [NormalizedUnit] {
        var units: [NormalizedUnit] = []
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(after: index)
            let sourceRange = index..<next
            let folded = String(value[sourceRange])
                .precomposedStringWithCompatibilityMapping
                .lowercased()
            for character in folded where !isIgnoredSeparator(character) {
                units.append(NormalizedUnit(
                    character: character,
                    sourceRange: sourceRange
                ))
            }
            index = next
        }
        return units
    }

    private static func hasValidBoundaries(
        range: Range<String.Index>,
        first: Character,
        last: Character,
        in text: String
    ) -> Bool {
        if isASCIIAlphaNumeric(first), range.lowerBound > text.startIndex {
            let previous = text[text.index(before: range.lowerBound)]
            if isASCIIAlphaNumeric(previous) { return false }
        }
        if isASCIIAlphaNumeric(last), range.upperBound < text.endIndex {
            let next = text[range.upperBound]
            if isASCIIAlphaNumeric(next) { return false }
        }
        return true
    }

    private static func isIgnoredSeparator(_ character: Character) -> Bool {
        if character.isWhitespace {
            let value = String(character)
            return !value.contains("\n") && !value.contains("\r")
        }
        return "-‐‑‒–—﹘﹣－".contains(character)
    }

    private static func isASCIIAlphaNumeric(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII else { return false }
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }

    private static func presentationKey(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
    }

    private static func normalized(_ value: String) -> String {
        String(normalizedUnits(in: value).map(\.character))
    }
}
