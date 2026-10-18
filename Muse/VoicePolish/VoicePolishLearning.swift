import Foundation
import NaturalLanguage

struct VoicePolishCorrectionRecord: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let historyID: String
    let createdAt: Date
    let scene: WritingScene
    let sourceText: String
    let generatedText: String
    let correctedText: String
    let learnStyle: Bool
    let learnTerminology: Bool

    init(
        id: String,
        historyID: String,
        createdAt: Date,
        scene: WritingScene,
        sourceText: String,
        generatedText: String,
        correctedText: String,
        learnStyle: Bool = true,
        learnTerminology: Bool = true
    ) {
        self.id = id
        self.historyID = historyID
        self.createdAt = createdAt
        self.scene = scene
        self.sourceText = sourceText
        self.generatedText = generatedText
        self.correctedText = correctedText
        self.learnStyle = learnStyle
        self.learnTerminology = learnTerminology
    }

    private enum CodingKeys: String, CodingKey {
        case id, historyID, createdAt, scene, sourceText, generatedText, correctedText
        case learnStyle, learnTerminology
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            historyID: try container.decode(String.self, forKey: .historyID),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            scene: try container.decode(WritingScene.self, forKey: .scene),
            sourceText: try container.decode(String.self, forKey: .sourceText),
            generatedText: try container.decode(String.self, forKey: .generatedText),
            correctedText: try container.decode(String.self, forKey: .correctedText),
            learnStyle: try container.decodeIfPresent(Bool.self, forKey: .learnStyle) ?? true,
            learnTerminology: try container.decodeIfPresent(Bool.self, forKey: .learnTerminology) ?? true
        )
    }
}

struct StyleProfile: Codable, Sendable, Equatable {
    let sampleCount: Int
    let brevity: Double
    let formality: Double
    let paragraphing: Double
    let listPreference: Double
    let punctuationDensity: Double

    static func merging(global: StyleProfile, scene: StyleProfile) -> StyleProfile {
        StyleProfile(
            sampleCount: global.sampleCount + scene.sampleCount,
            brevity: global.brevity * 0.4 + scene.brevity * 0.6,
            formality: global.formality * 0.4 + scene.formality * 0.6,
            paragraphing: global.paragraphing * 0.4 + scene.paragraphing * 0.6,
            listPreference: global.listPreference * 0.4 + scene.listPreference * 0.6,
            punctuationDensity: global.punctuationDensity * 0.4 + scene.punctuationDensity * 0.6
        )
    }
}

struct TerminologyCorrectionCandidate: Sendable, Equatable {
    let alias: String
    let canonical: String
}

/// 从一次用户明确纠正中提取术语候选。该纯函数同时供历史学习和统一术语仓库
/// 使用，避免两条链路分别实现文本 diff 后产生不一致。
enum TerminologyCorrectionExtractor {
    private struct LearningToken {
        let text: String
        let range: Range<String.Index>
    }

    /// 通过 token LCS 提取用户明确改动的最小连续片段。与逐 token zip 不同，
    /// 这里允许多个识别 token 对应一个标准术语（例如 Type less → Typeless）。
    static func candidates(
        generatedText: String,
        correctedText: String
    ) -> [TerminologyCorrectionCandidate] {
        let generated = learningTokens(in: generatedText)
        let corrected = learningTokens(in: correctedText)
        guard !generated.isEmpty, !corrected.isEmpty else { return [] }

        // 历史纠正通常是短文本。为避免对异常长文做二次方矩阵计算，长样本
        // 仍可参与风格画像，但不从中自动抽取术语。
        let maximumTokens = 256
        guard generated.count <= maximumTokens, corrected.count <= maximumTokens else { return [] }

        let matches = longestCommonSubsequenceMatches(generated, corrected)
        var changes: [TerminologyCorrectionCandidate] = []
        var previousGenerated = -1
        var previousCorrected = -1
        for (nextGenerated, nextCorrected) in matches + [(generated.count, corrected.count)] {
            let generatedRange = (previousGenerated + 1)..<nextGenerated
            let correctedRange = (previousCorrected + 1)..<nextCorrected
            previousGenerated = nextGenerated
            previousCorrected = nextCorrected

            guard !generatedRange.isEmpty, !correctedRange.isEmpty,
                  generatedRange.count <= 4, correctedRange.count <= 4 else { continue }
            let alias = sourceSpan(
                in: generatedText,
                tokens: generated,
                tokenRange: generatedRange
            )
            let canonical = sourceSpan(
                in: correctedText,
                tokens: corrected,
                tokenRange: correctedRange
            )
            if isUsableLexiconChange(alias: alias, canonical: canonical) {
                changes.append(TerminologyCorrectionCandidate(alias: alias, canonical: canonical))
            } else if let expanded = expandedChineseChange(
                generatedText: generatedText, correctedText: correctedText,
                generated: generated, corrected: corrected,
                generatedRange: generatedRange, correctedRange: correctedRange
            ), !changes.contains(expanded) {
                changes.append(expanded)
            }
        }
        return changes
    }

    /// 自动观察专用：词对须来自本次 ASR 原文，并满足中文近音或英文音形结构。
    /// 提取后直接保存，由本次收据提供撤销，不再产生记词前的确认步骤。
    static func automaticASRCandidates(
        generatedText: String,
        correctedText: String,
        recognitionText: String
    ) -> [TerminologyCorrectionCandidate] {
        let source = recognitionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return [] }
        return candidates(generatedText: generatedText, correctedText: correctedText).filter { candidate in
            containsStandaloneASRTerm(candidate.alias, in: source)
                && (EntityResolver.isLikelySpeechRecognitionCorrection(
                    alias: candidate.alias, canonical: candidate.canonical
                ) || EntityResolver.isEnglishSpeechCorrectionVariant(candidate.alias, candidate.canonical))
        }
    }

    /// 英文词须在识别原文中独立出现，不能从网址、邮箱或较长标识符中
    /// 截出片段建立全局替换；句末句号仍是普通标点。
    private static func containsStandaloneASRTerm(_ term: String, in source: String) -> Bool {
        guard term.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }) else {
            return source.localizedStandardContains(term)
        }
        // 引号包裹的邮箱 local-part 可以包含空格，不能按空白或引号切开
        // 再判断。先排除与完整邮箱片段重叠的词，匹配式不可用时保守跳过。
        let emailRanges: [NSRange]
        if source.contains("@") {
            guard let expression = try? NSRegularExpression(pattern: #"(?:"(?:[^"\\\r\n]|\\.)*"|[\p{L}\p{N}!#$%&'*+/=?^_`{|}~.\-]+)@[\p{L}\p{N}.\-]+"#) else { return false }
            emailRanges = expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).map(\.range)
        } else { emailRanges = [] }
        var start = source.startIndex
        while let range = source.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: start..<source.endIndex) {
            let before = range.lowerBound > source.startIndex ? source.index(before: range.lowerBound) : nil
            let after = range.upperBound < source.endIndex ? range.upperBound : nil
            // 邮箱 local-part 可含加号、引号、星号等合法符号，不能只检查
            // 紧邻字符；同一连续片段中出现 @ 或 URI scheme 时保守跳过。
            func tokenBoundary(_ character: Character) -> Bool {
                character.isWhitespace || "，。；、（）<>".contains(character)
            }
            let tokenStart = source[..<range.lowerBound].lastIndex(where: tokenBoundary).map { source.index(after: $0) } ?? source.startIndex
            let tokenEnd = source[range.upperBound...].firstIndex(where: tokenBoundary) ?? source.endIndex
            let token = source[tokenStart..<tokenEnd]
            func isBoundary(_ index: String.Index?, preceding: Bool) -> Bool {
                guard let index else { return true }
                let character = source[index]
                guard !isASCIIWordCharacter(character), !"@:/\\#?=&%+-$`{}".contains(character) else { return false }
                if character == "." {
                    if preceding {
                        // 点号左边还有域名/标识符，不能将右段当作独立术语。
                        return index == source.startIndex || !isDomainCharacter(source[source.index(before: index)])
                    }
                    let outer = source.index(after: index)
                    return outer == source.endIndex || !isDomainCharacter(source[outer])
                }
                return true
            }
            let inEmail = emailRanges.contains { NSIntersectionRange($0, NSRange(range, in: source)).length > 0 }
            if !inEmail, !token.contains("@"), !token.contains("://"),
               isBoundary(before, preceding: true), isBoundary(after, preceding: false) { return true }
            start = range.upperBound
        }
        return false
    }

    private static func isDomainCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// 中文单字音近差异不能直接成为全局规则。先恢复本机分词确认的短词；
    /// 陌生词被逐字切开时，仅合并被词界/功能字包围的 2～4 字连续片段。
    /// 两边上下文必须逐字相同，不能跨标点、空格或其他修改拼成词条。
    private static func expandedChineseChange(
        generatedText: String, correctedText: String,
        generated: [LearningToken], corrected: [LearningToken],
        generatedRange: Range<Int>, correctedRange: Range<Int>
    ) -> TerminologyCorrectionCandidate? {
        guard generatedRange.count == 1, correctedRange.count == 1 else { return nil }
        let left = generated[generatedRange.lowerBound]
        let right = corrected[correctedRange.lowerBound]
        guard isHan(left.text), isHan(right.text),
              EntityResolver.isLikelySpeechRecognitionCorrection(alias: left.text, canonical: right.text)
        else { return nil }

        func wordRange(in text: String, change: Range<String.Index>) -> Range<String.Index> {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = text
            tagger.setLanguage(.simplifiedChinese, range: text.startIndex..<text.endIndex)
            var ranges: [Range<String.Index>] = []
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                                 scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { _, range in
                ranges.append(range)
                return true
            }
            guard let index = ranges.firstIndex(where: { $0.overlaps(change) }) else { return change }
            if text[ranges[index]].count > 1 { return ranges[index] }
            // 功能字不作为陌生专名的一部分；无法得到短而完整的片段就放弃。
            let boundaries = Set("的地得了着过在去到从向和与及或是把被让给为对将要我你他她它们这那有不也都很就再才又而但吗呢吧啊片个名位条本次件杯份种台部")
            func joins(_ range: Range<String.Index>) -> Bool {
                let word = String(text[range])
                return isHan(word) && !boundaries.contains(word.first!)
            }
            guard joins(ranges[index]) else { return change }
            var start = index
            var end = index
            while start > 0, ranges[start - 1].upperBound == ranges[start].lowerBound,
                  joins(ranges[start - 1]) { start -= 1 }
            while end + 1 < ranges.count, ranges[end].upperBound == ranges[end + 1].lowerBound,
                  joins(ranges[end + 1]) { end += 1 }
            return ranges[start].lowerBound..<ranges[end].upperBound
        }

        let leftBoundary = wordRange(in: generatedText, change: left.range)
        let rightBoundary = wordRange(in: correctedText, change: right.range)
        // 分词器可能把陌生名称的一部分识别成人名。两侧词界取有界并集，
        // 之后仍须验证扩出的前后文字完全一致，不能借扩词包住别处修改。
        let before = max(generatedText.distance(from: leftBoundary.lowerBound, to: left.range.lowerBound),
                         correctedText.distance(from: rightBoundary.lowerBound, to: right.range.lowerBound))
        let after = max(generatedText.distance(from: left.range.upperBound, to: leftBoundary.upperBound),
                        correctedText.distance(from: right.range.upperBound, to: rightBoundary.upperBound))
        guard before + after + 1 <= 4,
              let leftStart = generatedText.index(left.range.lowerBound, offsetBy: -before, limitedBy: generatedText.startIndex),
              let rightStart = correctedText.index(right.range.lowerBound, offsetBy: -before, limitedBy: correctedText.startIndex),
              let leftEnd = generatedText.index(left.range.upperBound, offsetBy: after, limitedBy: generatedText.endIndex),
              let rightEnd = correctedText.index(right.range.upperBound, offsetBy: after, limitedBy: correctedText.endIndex)
        else { return nil }
        let leftWord = leftStart..<leftEnd
        let rightWord = rightStart..<rightEnd
        let leftPrefix = String(generatedText[leftWord.lowerBound..<left.range.lowerBound])
        let rightPrefix = String(correctedText[rightWord.lowerBound..<right.range.lowerBound])
        let leftSuffix = String(generatedText[left.range.upperBound..<leftWord.upperBound])
        let rightSuffix = String(correctedText[right.range.upperBound..<rightWord.upperBound])
        let alias = String(generatedText[leftWord])
        let canonical = String(correctedText[rightWord])
        guard (2...4).contains(alias.count), (2...4).contains(canonical.count),
              alias.allSatisfy({ isHan(String($0)) }), canonical.allSatisfy({ isHan(String($0)) }),
              leftPrefix == rightPrefix, leftSuffix == rightSuffix,
              isUsableLexiconChange(alias: alias, canonical: canonical) else { return nil }
        return TerminologyCorrectionCandidate(alias: alias, canonical: canonical)
    }

    private static func isHan(_ text: String) -> Bool {
        text.count == 1 && text.unicodeScalars.allSatisfy {
            (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
        }
    }

    private static func longestCommonSubsequenceMatches(
        _ left: [LearningToken],
        _ right: [LearningToken]
    ) -> [(Int, Int)] {
        let columns = right.count + 1
        var lengths = Array(repeating: 0, count: (left.count + 1) * columns)
        func offset(_ leftIndex: Int, _ rightIndex: Int) -> Int {
            leftIndex * columns + rightIndex
        }

        for leftIndex in stride(from: left.count - 1, through: 0, by: -1) {
            for rightIndex in stride(from: right.count - 1, through: 0, by: -1) {
                if tokenComparisonKey(left[leftIndex].text) == tokenComparisonKey(right[rightIndex].text) {
                    lengths[offset(leftIndex, rightIndex)] = 1
                        + lengths[offset(leftIndex + 1, rightIndex + 1)]
                } else {
                    lengths[offset(leftIndex, rightIndex)] = max(
                        lengths[offset(leftIndex + 1, rightIndex)],
                        lengths[offset(leftIndex, rightIndex + 1)]
                    )
                }
            }
        }

        var result: [(Int, Int)] = []
        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < left.count, rightIndex < right.count {
            if tokenComparisonKey(left[leftIndex].text) == tokenComparisonKey(right[rightIndex].text) {
                result.append((leftIndex, rightIndex))
                leftIndex += 1
                rightIndex += 1
            } else if lengths[offset(leftIndex + 1, rightIndex)]
                >= lengths[offset(leftIndex, rightIndex + 1)] {
                leftIndex += 1
            } else {
                rightIndex += 1
            }
        }
        return result
    }

    private static func learningTokens(in text: String) -> [LearningToken] {
        var result: [LearningToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace || character.isPunctuation {
                index = text.index(after: index)
                continue
            }
            if isASCIIWordCharacter(character) {
                let start = index
                index = text.index(after: index)
                while index < text.endIndex, isASCIIWordCharacter(text[index]) {
                    index = text.index(after: index)
                }
                result.append(LearningToken(
                    text: String(text[start..<index]),
                    range: start..<index
                ))
            } else {
                let next = text.index(after: index)
                result.append(LearningToken(
                    text: String(text[index..<next]),
                    range: index..<next
                ))
                index = next
            }
        }
        return result
    }

    private static func sourceSpan(
        in text: String,
        tokens: [LearningToken],
        tokenRange: Range<Int>
    ) -> String {
        let start = tokens[tokenRange.lowerBound].range.lowerBound
        let end = tokens[tokenRange.upperBound - 1].range.upperBound
        return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUsableLexiconChange(alias: String, canonical: String) -> Bool {
        guard (2...64).contains(alias.count),
              (2...64).contains(canonical.count),
              normalized(alias) != normalized(canonical),
              !alias.contains(where: { $0.isNewline }),
              !canonical.contains(where: { $0.isNewline }) else { return false }
        return true
    }

    private static func isASCIIWordCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII else { return false }
        switch scalar.value {
        case 48...57, 65...90, 95, 97...122:
            return true
        default:
            return false
        }
    }

    private static func tokenComparisonKey(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
    }
}
