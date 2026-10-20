import Foundation
@testable import Dal

enum VoicePolishFixtureCategory: String, CaseIterable {
    case shortChat
    case workChat
    case email
    case immediateCorrection
    case delayedCorrection
    case sideNote
    case unorderedThinking
    case listCountChange
    case properNoun
    case numericFact
    case mixedTechnical
    case aiPrompt
    case socialMonologue

    var expectedCount: Int {
        switch self {
        case .shortChat:
            return 9
        case .workChat, .immediateCorrection, .delayedCorrection,
             .properNoun, .numericFact, .mixedTechnical, .aiPrompt:
            return 8
        case .email, .sideNote, .unorderedThinking, .listCountChange, .socialMonologue:
            return 7
        }
    }
}

struct VoicePolishFixture {
    let id: String
    let category: VoicePolishFixtureCategory
    let scene: WritingScene
    let segments: [RecognitionSegment]
    let expectedRoute: VoicePolishRoute
    let mustPreserveCanonicalFacts: [String]
    let supersededCanonicalFacts: [String]

    var sourceText: String { segments.map(\.text).joined(separator: "\n") }
}

enum VoicePolishFixtureCatalog {
    static let all: [VoicePolishFixture] = VoicePolishFixtureCategory.allCases.flatMap(makeFixtures)

    private static let variants = [
        "请保留原意", "语气自然", "不要扩写", "直接成稿",
        "表达清楚", "保持力度", "结构清晰", "只做整理",
        "可以直接发送",
    ]

    private static func makeFixtures(
        category: VoicePolishFixtureCategory
    ) -> [VoicePolishFixture] {
        (0..<category.expectedCount).map { index in
            let tail = variants[index]
            let base = template(for: category)
            let texts = base.texts.enumerated().map { segmentIndex, text in
                RecognitionSegment(
                    id: "s\(segmentIndex + 1)",
                    text: segmentIndex == base.texts.count - 1 ? "\(text)\(tail)。" : text,
                    startTimeMs: nil,
                    endTimeMs: nil,
                    confidence: nil,
                    isFinal: true
                )
            }
            return VoicePolishFixture(
                id: "\(category.rawValue)-\(String(format: "%03d", index + 1))",
                category: category,
                scene: base.scene,
                segments: texts,
                expectedRoute: base.route,
                mustPreserveCanonicalFacts: base.mustFacts,
                supersededCanonicalFacts: base.supersededFacts
            )
        }
    }

    private static func template(
        for category: VoicePolishFixtureCategory
    ) -> (texts: [String], scene: WritingScene, route: VoicePolishRoute, mustFacts: [String], supersededFacts: [String]) {
        switch category {
        case .shortChat:
            return (["我晚一点到，你们先开始。"], .chat, .fast, [], [])
        case .workChat:
            return (["今天先确认需求。", "明天再补完整排期。"], .workChat, .fast, [], [])
        case .email:
            return ([String(repeating: "请把本周进展和下周安排整理清楚，", count: 9)], .email, .fast, [], [])
        case .immediateCorrection:
            return (["会议定在周四，不对，改成周五下午。"], .workChat, .structured, [], [])
        case .delayedCorrection:
            return (["第一期一万六千八，刚才那句改成最终每期一万六，总价四万八。"], .document, .deep, ["16000", "48000"], ["16800"])
        case .sideNote:
            return (["方案按当前版本推进，顺便说一下，预算还要再确认。"], .workChat, .structured, [], [])
        case .unorderedThinking:
            return (["先说发布安排，换个话题讲预算，回到刚才，发布前要补回归测试。"], .document, .deep, [], [])
        case .listCountChange:
            return (["第一，写方案。第二，补测试。还有一项，发布前做演练。"], .document, .deep, [], [])
        case .properNoun:
            return (["请用 Claude Code 检查 Kubernetes 配置。"], .code, .fast, [], [])
        case .numericFact:
            return (["报价 4.98 万，折扣 12.5%，版本 v2.1.0，日期 2026-07-31。"], .document, .fast, ["49800", "12.5%", "v2.1.0", "2026-07-31"], [])
        case .mixedTechnical:
            return (["把 SwiftUI 的 WebSocket timeout 调成四十五秒。"], .code, .fast, ["45"], [])
        case .aiPrompt:
            return (["帮我整理一个提示词，要求保留输入事实，必须输出 JSON，不要添加例子，并限制在 3 段内。"], .aiPrompt, .deep, [], [])
        case .socialMonologue:
            return ([String(repeating: "今天想聊一个经常被忽略的问题，再补充一点真实使用中的感受，", count: 6)], .socialPost, .structured, [], [])
        }
    }
}
