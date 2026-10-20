import Foundation
@preconcurrency import AVFoundation

struct ASRRequestOptions: Sendable, Equatable {
    var enablePunc: Bool = true
    var hotwords: [String] = []
    /// hotwords 中前 N 个是用户手动添加的词；顺序保持用户词在前、内置词在后。
    var userHotwordCount: Int = 0
    /// 用户配置的确定性错词纠正，火山端用于实时结果，本地收尾仍会再次兜底。
    var correctionWords: [String: String] = [:]
    var boostingTableID: String?
    var contextHistoryLength: Int = 0

    var urlSessionConfiguration: URLSessionConfiguration {
        URLSessionConfiguration.default
    }
}

struct RecognitionTranscript: Sendable, Equatable {
    let confirmedSegments: [String]
    let partialText: String
    let authoritativeText: String
    let isFinal: Bool

    static let empty = RecognitionTranscript(
        confirmedSegments: [],
        partialText: "",
        authoritativeText: "",
        isFinal: false
    )

    var composedText: String {
        let pieces = confirmedSegments + (partialText.isEmpty ? [] : [partialText])
        return pieces.joined()
    }

    var displayText: String {
        authoritativeText.isEmpty ? composedText : authoritativeText
    }
}

enum InjectionOutcome: Sendable, Equatable {
    case inserted
    case copiedToClipboard
    case noFocusedInput(copiedToClipboard: Bool)
    /// 自动粘贴所需的辅助功能权限未授予，文本已留在剪贴板等待手动粘贴（REPAIR_PLAN B1）
    case copiedToClipboardPermissionMissing

    var completionMessage: String {
        switch self {
        case .inserted:
            return L("已完成", "Done")
        case .copiedToClipboard:
            return L("已粘贴到剪贴板", "Copied to clipboard")
        case .noFocusedInput(let copiedToClipboard):
            return copiedToClipboard
                ? L("未找到输入位置，已复制", "No input target — copied")
                : L("未找到输入位置", "No input target")
        case .copiedToClipboardPermissionMissing:
            return L("已复制，请手动粘贴（开启辅助功能权限后可自动输入）",
                     "Copied — paste manually (grant Accessibility to auto-insert)")
        }
    }

    var needsManualCopyCard: Bool {
        if case .noFocusedInput = self { return true }
        return false
    }
}

enum RecognitionEvent: Sendable {
    case ready
    case transcript(RecognitionTranscript)
    case error(Error)
    case completed
    case processingResult(text: String)
    /// Voice Polish 正在执行的可见阶段；不携带任何用户正文。
    case voicePolishStage(VoicePolishStage)
    /// 润色未能安全完成。Session 此时不会自动注入原转写，而是等待用户
    /// 明确重试润色或取消当前输入。
    case voicePolishUnavailable(reason: VoicePolishFailureReason?)
    case finalized(text: String, injection: InjectionOutcome)
    /// 流式上传中断（REPAIR_PLAN B7a）：录音仍在继续，最终文本由停止后的
    /// 批量兜底重识别保证；UI 据此提示用户不必因字幕停更而中断说话
    case streamingInterrupted
}

struct LLMConfig: Sendable {
    let apiKey: String
    let model: String
    let baseURL: String
    let thinkingMode: LLMThinkingMode

    init(
        apiKey: String,
        model: String,
        baseURL: String = "",
        thinkingMode: LLMThinkingMode = .disabled
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.thinkingMode = thinkingMode
    }

    func withThinkingMode(_ mode: LLMThinkingMode) -> LLMConfig {
        LLMConfig(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            thinkingMode: mode
        )
    }

    func withModel(_ model: String) -> LLMConfig {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return self }
        return LLMConfig(
            apiKey: apiKey,
            model: normalized,
            baseURL: baseURL,
            thinkingMode: thinkingMode
        )
    }
}

protocol SpeechRecognizer: AnyObject, Sendable {
    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws
    func sendAudio(_ data: Data) async throws
    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws
    func endAudio() async throws
    func disconnect() async
    var events: AsyncStream<RecognitionEvent> { get async }
}

extension SpeechRecognizer {
    func sendAudio(_ data: Data) async throws {
        _ = data
    }

    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        _ = buffer
    }
}
