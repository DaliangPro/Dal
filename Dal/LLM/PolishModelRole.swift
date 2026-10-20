import Foundation

enum PolishModelRole: String, CaseIterable, Identifiable, Sendable {
    // 仅用于旧存储键的兼容读取；活动模型只有 standard。
    case light
    case standard

    static let allCases: [Self] = [.standard]

    var id: String { rawValue }
    var title: String {
        L("润色模型", "Polish Model")
    }
    static func resolve(_ quality: VoicePolishQualityMode?) -> Self {
        .standard
    }
}

/// 与实际润色一致：单请求、关闭思考；不再把思考开关验证混入连接测试。
enum PolishModelConnectionTester {
    static func test(role: PolishModelRole, config: LLMConfig, client: any LLMClient) async throws {
        let response = try await client.generate(LLMRequest(
            context: .connectivityProbe,
            task: .voicePolishStructured,
            system: "只返回用户提供的文字，不要解释。",
            user: "连接正常",
            options: LLMGenerationOptions(temperature: 0, maxOutputTokens: 64, reasoningPolicy: .disabled)
        ), config: config.withThinkingMode(.disabled))
        guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyResponse(nil)
        }
    }
}
