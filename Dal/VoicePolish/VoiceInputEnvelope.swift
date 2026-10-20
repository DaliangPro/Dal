import Foundation

struct RecognitionSegment: Sendable, Equatable, Codable {
    let id: String
    let text: String
    let startTimeMs: Int?
    let endTimeMs: Int?
    let confidence: Double?
    let isFinal: Bool
}

/// 本次从 ASR 原文实际执行的确定性术语修改。
///
/// 该信息只用于本地校验，确保模型不能在保留 canonical 的同时把旧 alias
/// 又带回成稿；不包含完整用户正文。
struct VoiceTerminologyEdit: Sendable, Equatable {
    let alias: String
    let canonical: String
    let sourceSegmentIDs: [String]
}

struct VoiceInputEnvelope: Sendable, Equatable {
    /// ASR Provider 最终实际可用的原样终稿。
    let providerFinalText: String
    /// 只有确实存在独立标点恢复结果时才设置。
    let punctuatedText: String?
    /// ASR 原始分段，仅用于事实追溯与审计，不作为失败回退文本。
    let rawSegments: [RecognitionSegment]
    /// 应用已确认术语和确定性规则后的完整文本。
    let canonicalText: String
    /// canonical 分段，供路由、事实抽取与 LLM 成稿使用。
    let segments: [RecognitionSegment]
    /// 已经在 canonical 化阶段实际执行的 alias → canonical 修改。
    let requiredEntityEdits: [VoiceTerminologyEdit]
    let durationMs: Int
    let detectedLanguage: String?
    let provider: ASRProvider

    var fallbackText: String {
        VoicePolishCharacterSafety.sanitizedFallback(
            canonicalText.isEmpty ? (punctuatedText ?? providerFinalText) : canonicalText
        )
    }

    init(
        providerFinalText: String,
        punctuatedText: String? = nil,
        rawSegments: [RecognitionSegment]? = nil,
        canonicalText: String? = nil,
        segments: [RecognitionSegment],
        requiredEntityEdits: [VoiceTerminologyEdit] = [],
        durationMs: Int,
        detectedLanguage: String? = nil,
        provider: ASRProvider
    ) {
        self.providerFinalText = providerFinalText
        self.punctuatedText = punctuatedText
        self.rawSegments = rawSegments ?? segments
        self.canonicalText = (canonicalText ?? punctuatedText ?? providerFinalText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.segments = segments
        self.requiredEntityEdits = requiredEntityEdits
        self.durationMs = max(0, durationMs)
        self.detectedLanguage = detectedLanguage
        self.provider = provider
    }

    static func fromFinalTranscript(
        _ transcript: RecognitionTranscript,
        rawFinalText: String,
        canonicalText: String,
        preferredCanonicalSegmentTexts: [String]? = nil,
        deterministicCorrections: [String: String] = [:],
        durationMs: Int,
        provider: ASRProvider
    ) -> VoiceInputEnvelope? {
        let trimmedRaw = rawFinalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCanonical = canonicalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty, !trimmedCanonical.isEmpty else { return nil }

        let sourceSegments = transcript.confirmedSegments
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let rawSegments: [RecognitionSegment]
        let confirmedText = sourceSegments.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sourceSegments.isEmpty || confirmedText != trimmedRaw {
            rawSegments = [RecognitionSegment(
                id: "s1",
                text: trimmedRaw,
                startTimeMs: nil,
                endTimeMs: nil,
                confidence: nil,
                isFinal: true
            )]
        } else {
            rawSegments = sourceSegments.enumerated().map { index, text in
                RecognitionSegment(
                    id: "s\(index + 1)",
                    text: text,
                    startTimeMs: nil,
                    endTimeMs: nil,
                    confidence: nil,
                    isFinal: true
                )
            }
        }

        let segments = canonicalSegments(
            rawSegments: rawSegments,
            canonicalText: trimmedCanonical,
            preferredTexts: preferredCanonicalSegmentTexts
        )
        let requiredEntityEdits = actualTerminologyEdits(
            corrections: deterministicCorrections,
            rawSegments: rawSegments,
            canonicalText: trimmedCanonical
        )

        return VoiceInputEnvelope(
            providerFinalText: trimmedRaw,
            punctuatedText: nil,
            rawSegments: rawSegments,
            canonicalText: trimmedCanonical,
            segments: segments,
            requiredEntityEdits: requiredEntityEdits,
            durationMs: durationMs,
            provider: provider
        )
    }

    /// 优先采用调用方按相同规则逐段 canonical 化的结果；只有整句规则跨越
    /// segment 边界、无法逐段复现时，才按原分段长度做单调保守映射。无论哪条
    /// 路径都保持 segment 数量与 ID，不让一次术语纠正改变复杂度路由。
    private static func canonicalSegments(
        rawSegments: [RecognitionSegment],
        canonicalText: String,
        preferredTexts: [String]?
    ) -> [RecognitionSegment] {
        guard rawSegments.map(\.text).joined() != canonicalText else { return rawSegments }

        let texts: [String]
        if let preferredTexts,
           preferredTexts.count == rawSegments.count,
           preferredTexts.joined().trimmingCharacters(in: .whitespacesAndNewlines) == canonicalText {
            texts = preferredTexts
        } else {
            texts = proportionalPartition(
                canonicalText,
                rawLengths: rawSegments.map { $0.text.count }
            )
        }

        return zip(rawSegments, texts).map { raw, text in
            RecognitionSegment(
                id: raw.id,
                text: text,
                startTimeMs: raw.startTimeMs,
                endTimeMs: raw.endTimeMs,
                confidence: raw.confidence,
                isFinal: raw.isFinal
            )
        }
    }

    private static func proportionalPartition(
        _ text: String,
        rawLengths: [Int]
    ) -> [String] {
        guard rawLengths.count > 1 else { return [text] }
        let characters = Array(text)
        let totalRawLength = max(1, rawLengths.reduce(0, +))
        let canKeepEverySegmentNonempty = characters.count >= rawLengths.count
        var previousBoundary = 0
        var cumulativeRawLength = 0
        var result: [String] = []

        for index in rawLengths.indices {
            cumulativeRawLength += rawLengths[index]
            let remainingSegments = rawLengths.count - index - 1
            let boundary: Int
            if remainingSegments == 0 {
                boundary = characters.count
            } else {
                let proportional = Int(
                    (Double(cumulativeRawLength) / Double(totalRawLength)
                        * Double(characters.count)).rounded()
                )
                let minimum = previousBoundary + (canKeepEverySegmentNonempty ? 1 : 0)
                let maximum = characters.count
                    - (canKeepEverySegmentNonempty ? remainingSegments : 0)
                boundary = min(max(proportional, minimum), max(minimum, maximum))
            }
            result.append(String(characters[previousBoundary..<boundary]))
            previousBoundary = boundary
        }
        return result
    }

    /// 只记录确实命中过原文、且 canonical 结果中已经完成替换的规则。
    /// 这样 Validator 不会把词库中未参与本次输入的 alias 当成必改项。
    private static func actualTerminologyEdits(
        corrections: [String: String],
        rawSegments: [RecognitionSegment],
        canonicalText: String
    ) -> [VoiceTerminologyEdit] {
        corrections
            .sorted { left, right in
                if left.key.count != right.key.count { return left.key.count > right.key.count }
                return left.key.localizedStandardCompare(right.key) == .orderedAscending
            }
            .compactMap { alias, canonical in
                let rule = [alias: canonical]
                let sourceSegmentIDs = rawSegments.compactMap { segment -> String? in
                    EntityResolver.applyingKnownCorrections(rule, to: segment.text) == segment.text
                        ? nil
                        : segment.id
                }
                let rawText = rawSegments.map(\.text).joined()
                let matchedAcrossSegments = EntityResolver.applyingKnownCorrections(
                    rule,
                    to: rawText
                ) != rawText
                guard matchedAcrossSegments,
                      canonicalText.contains(canonical),
                      EntityResolver.applyingKnownCorrections(rule, to: canonicalText) == canonicalText
                else { return nil }
                return VoiceTerminologyEdit(
                    alias: alias,
                    canonical: canonical,
                    sourceSegmentIDs: sourceSegmentIDs.isEmpty
                        ? rawSegments.map(\.id)
                        : sourceSegmentIDs
                )
            }
    }
}
