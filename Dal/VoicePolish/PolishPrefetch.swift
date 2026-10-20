import Foundation
import os

/// 仅驻留内存，不记录正文或凭据；调用方只可交付完整匹配的成功候选。
final class PolishPrefetch: Sendable {
    struct Key: Equatable, Sendable {
        let text: String
        let requirements: String
        let provider: LLMProvider
        private let inputBytes: Data
        private let requirementBytes: Data
        private let model: String
        private let endpoint: String
        private let credential: String
        private let thinking: LLMThinkingMode
        private let promptVersion = VoicePolishEditingPrompts.version

        init(text: String, requirements: String, provider: LLMProvider, config: LLMConfig) {
            self.text = text
            self.requirements = requirements
            self.provider = provider
            inputBytes = Data(text.utf8)
            requirementBytes = Data(requirements.utf8)
            model = config.model
            endpoint = config.baseURL
            credential = config.apiKey
            thinking = config.thinkingMode
        }
    }

    private struct State {
        var session: RecognitionSessionID?
        var attempted: [Key] = []
        var key: Key?
        var token: UUID?
        var task: Task<Void, Never>?
        var completed: VoicePolishResult?

        mutating func invalidate() {
            task?.cancel()
            task = nil
            key = nil
            token = nil
            completed = nil
        }
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func start(session: RecognitionSessionID, key: Key,
               generate: @escaping @Sendable () async -> VoicePolishResult) {
        state.withLock { value in
            if value.session != session {
                value.invalidate()
                value.session = session
                value.attempted = []
            }
            guard !key.text.isEmpty, value.attempted.count < 2,
                  !value.attempted.contains(key) else { return }
            value.invalidate()
            value.attempted.append(key)
            DebugFileLogger.log("polish prefetch: scheduled attempt=\(value.attempted.count)")
            value.key = key
            let token = UUID()
            value.token = token
            value.task = Task { [weak self] in
                guard !Task.isCancelled else { return }
                let result = await generate()
                guard !Task.isCancelled, let self else { return }
                self.state.withLock { value in
                    guard value.session == session, value.token == token else { return }
                    if !result.usedFallback { value.completed = result }
                    value.task = nil
                }
            }
        }
    }

    /// 转写变化立即作废，但不重置本段录音的请求预算。
    func invalidate() {
        state.withLock { $0.invalidate() }
    }

    /// 调度数量单独统计，不能当作 Provider 已接收的请求数。
    func scheduledCount(session: RecognitionSessionID) -> Int {
        state.withLock { $0.session == session ? $0.attempted.count : 0 }
    }

    func take(session: RecognitionSessionID, key: Key) -> VoicePolishResult? {
        state.withLock { value in
            guard value.session == session else { return nil }
            let result = value.key == key ? value.completed : nil
            DebugFileLogger.log("polish prefetch: stop attempts=\(value.attempted.count) reused=\(result != nil)")
            value.invalidate()
            return result
        }
    }

    func reset(session: RecognitionSessionID? = nil) {
        state.withLock { value in
            guard session == nil || value.session == session else { return }
            value.invalidate()
            value.session = nil
            value.attempted = []
        }
    }
}
