import Foundation

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
            guard isUsableLexiconChange(alias: alias, canonical: canonical) else { continue }
            changes.append(TerminologyCorrectionCandidate(
                alias: alias,
                canonical: canonical
            ))
        }
        return changes
    }

    /// 自动观察专用：候选必须来自本次 ASR 原文，并通过保守的音近/拼写门槛。
    /// 普通人工语义改写仍可由明确的纠正界面保存，不在这里隐式入库。
    static func automaticASRCandidates(
        generatedText: String,
        correctedText: String,
        recognitionText: String
    ) -> [TerminologyCorrectionCandidate] {
        let source = recognitionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return [] }
        return candidates(generatedText: generatedText, correctedText: correctedText).filter { candidate in
            source.localizedStandardContains(candidate.alias)
                && EntityResolver.isLikelySpeechRecognitionCorrection(
                    alias: candidate.alias, canonical: candidate.canonical
                )
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
