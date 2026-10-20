import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech
import os

enum AppleASRError: Error, LocalizedError {
    case invalidConfig
    case permissionDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnsupported(localeIdentifier: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return "Apple ASR requires AppleASRConfig"
        case .permissionDenied:
            return L("未授予语音识别权限", "Speech recognition permission not granted")
        case .recognizerUnavailable:
            return L("Apple 语音识别当前不可用", "Apple speech recognition is currently unavailable")
        case .onDeviceRecognitionUnsupported(let localeIdentifier):
            return L(
                "Apple 端侧语音识别不支持当前语言（\(localeIdentifier)）。请切换识别语言，或改用火山引擎。",
                "Apple on-device speech recognition does not support \(localeIdentifier). Switch the recognition language or use Volcano Speech."
            )
        }
    }
}

private struct AppleASREndAudioTimeout: Error {}

struct AppleRecognitionCallback: @unchecked Sendable {
    let text: String?
    let isFinal: Bool
    let error: Error?
}

protocol AppleRecognitionSessionControlling: AnyObject, Sendable {
    func append(_ buffer: AVAudioPCMBuffer) async
    func endAudio() async
    func cancel()
}

typealias AppleRecognitionSessionFactory = @Sendable (
    Locale,
    @escaping @Sendable (AppleRecognitionCallback) -> Void
) async throws -> (any AppleRecognitionSessionControlling)?

private final class LiveAppleRecognitionSession: AppleRecognitionSessionControlling, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let task: SFSpeechRecognitionTask

    private init(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        task: SFSpeechRecognitionTask
    ) {
        self.recognizer = recognizer
        self.request = request
        self.task = task
    }

    static func make(
        locale: Locale,
        callback: @escaping @Sendable (AppleRecognitionCallback) -> Void
    ) async throws -> LiveAppleRecognitionSession? {
        try await MainActor.run {
            let recognizer = SFSpeechRecognizer(locale: locale)
            try AppleASRClient.validateOnDeviceRecognizer(
                requestedLocaleIdentifier: locale.identifier,
                resolvedLocaleIdentifier: recognizer?.locale.identifier,
                isAvailable: recognizer?.isAvailable ?? false,
                supportsOnDeviceRecognition: recognizer?.supportsOnDeviceRecognition ?? false
            )
            guard let recognizer else {
                // validateOnDeviceRecognizer 已将 nil 转换为可操作的语言不支持错误。
                throw AppleASRError.onDeviceRecognitionUnsupported(
                    localeIdentifier: locale.identifier
                )
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            try AppleASRClient.configureOnDeviceRequest(
                request,
                supportsOnDeviceRecognition: recognizer.supportsOnDeviceRecognition,
                localeIdentifier: locale.identifier
            )
            let task = recognizer.recognitionTask(with: request) { result, error in
                let text = result?.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                callback(AppleRecognitionCallback(
                    text: text,
                    isFinal: result?.isFinal ?? false,
                    error: error
                ))
            }

            return LiveAppleRecognitionSession(
                recognizer: recognizer,
                request: request,
                task: task
            )
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) async {
        let request = self.request
        await MainActor.run {
            request.append(buffer)
        }
    }

    func endAudio() async {
        let request = self.request
        await MainActor.run {
            request.endAudio()
        }
    }

    func cancel() {
        Task { @MainActor [self] in
            task.cancel()
        }
    }
}

actor AppleASRClient: SpeechRecognizer {

    private struct FinishWaiter {
        let sessionID: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private let logger = Logger(subsystem: "pro.daliang.muse.asr", category: "AppleASRClient")
    private let permissionProvider: @Sendable () async -> Bool
    private let recognitionSessionFactory: AppleRecognitionSessionFactory
    private let endAudioTimeout: Duration

    private var recognitionSession: (any AppleRecognitionSessionControlling)?
    private var sessionID: UUID?
    private var eventContinuation: AsyncStream<RecognitionEvent>.Continuation?
    private var _events: AsyncStream<RecognitionEvent>?
    private var latestTranscript = ""
    private var didFinishStream = false
    private var finishWaiter: FinishWaiter?
    private var didLogInputBuffer = false

    init(
        permissionProvider: @escaping @Sendable () async -> Bool = {
            if PermissionManager.hasSpeechRecognitionPermission {
                return true
            }
            return await PermissionManager.requestSpeechRecognitionPermission()
        },
        recognitionSessionFactory: @escaping AppleRecognitionSessionFactory = { locale, callback in
            try await LiveAppleRecognitionSession.make(locale: locale, callback: callback)
        },
        endAudioTimeout: Duration = .seconds(5)
    ) {
        self.permissionProvider = permissionProvider
        self.recognitionSessionFactory = recognitionSessionFactory
        self.endAudioTimeout = endAudioTimeout
    }

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events { return existing }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        _events = stream
        eventContinuation = continuation
        return stream
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {
        guard let config = config as? AppleASRConfig else {
            throw AppleASRError.invalidConfig
        }
        _ = options

        guard await permissionProvider() else {
            throw AppleASRError.permissionDenied
        }

        let locale = Self.preferredLocale(for: config)
        logger.info("Apple ASR connect locale=\(locale.identifier, privacy: .public)")

        invalidateCurrentSession(emitCompleted: true)

        let newSessionID = UUID()
        sessionID = newSessionID
        latestTranscript = ""
        didFinishStream = false
        finishWaiter = nil
        didLogInputBuffer = false

        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        _events = stream
        eventContinuation = continuation

        let factory = recognitionSessionFactory
        let createdSession: (any AppleRecognitionSessionControlling)?
        do {
            createdSession = try await factory(locale) { [weak self] callback in
                guard let self else { return }
                Task {
                    await self.handleRecognitionCallback(
                        sessionID: newSessionID,
                        callback: callback
                    )
                }
            }
        } catch {
            guard sessionID == newSessionID else {
                throw CancellationError()
            }
            invalidateCurrentSession(emitCompleted: false)
            throw error
        }

        guard sessionID == newSessionID else {
            createdSession?.cancel()
            throw CancellationError()
        }
        guard let createdSession else {
            invalidateCurrentSession(emitCompleted: false)
            throw AppleASRError.recognizerUnavailable
        }

        recognitionSession = createdSession
        continuation.yield(.ready)
    }

    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        guard sessionID != nil, let recognitionSession else { return }

        if !didLogInputBuffer {
            didLogInputBuffer = true
            logger.info(
                "append first buffer sr=\(buffer.format.sampleRate, privacy: .public) ch=\(buffer.format.channelCount, privacy: .public) frames=\(buffer.frameLength, privacy: .public)"
            )
        }
        await recognitionSession.append(buffer)
    }

    func endAudio() async throws {
        guard let currentSessionID = sessionID, let recognitionSession else { return }

        logger.info("Apple ASR endAudio")
        await recognitionSession.endAudio()
        guard sessionID == currentSessionID else { return }

        do {
            try await AsyncTimeout.throwingValue(
                endAudioTimeout,
                timeoutError: AppleASREndAudioTimeout()
            ) { [weak self] in
                guard let self else { return }
                await self.waitForCompletion(sessionID: currentSessionID)
            }
        } catch is AppleASREndAudioTimeout {
            guard sessionID == currentSessionID else { return }
            logger.error("Apple ASR endAudio timeout, cancelling recognition and using fallback transcript")
            recognitionSession.cancel()
            finishStream(
                sessionID: currentSessionID,
                emitFallbackFinal: true,
                error: nil
            )
        } catch {
            throw error
        }
    }

    func disconnect() async {
        invalidateCurrentSession(emitCompleted: true)
    }

    private func handleRecognitionCallback(
        sessionID callbackSessionID: UUID,
        callback: AppleRecognitionCallback
    ) {
        guard sessionID == callbackSessionID, !didFinishStream else {
            logger.debug("Ignoring stale Apple ASR callback")
            return
        }

        if let text = callback.text {
            logger.info("Apple ASR callback final=\(callback.isFinal, privacy: .public) chars=\(text.count, privacy: .public)")

            if !text.isEmpty {
                latestTranscript = text
                eventContinuation?.yield(Self.makeTranscript(text: text, isFinal: callback.isFinal))
            }

            if callback.isFinal {
                finishStream(
                    sessionID: callbackSessionID,
                    emitFallbackFinal: false,
                    error: nil
                )
                return
            }
        }

        if let error = callback.error {
            logger.error("Apple ASR callback error: \(String(describing: error), privacy: .private)")
            finishStream(
                sessionID: callbackSessionID,
                emitFallbackFinal: true,
                error: error
            )
        }
    }

    private func waitForCompletion(sessionID waiterSessionID: UUID) async {
        guard sessionID == waiterSessionID, !didFinishStream else { return }

        await withCheckedContinuation { continuation in
            guard sessionID == waiterSessionID, !didFinishStream else {
                continuation.resume()
                return
            }
            guard finishWaiter == nil else {
                assertionFailure("Apple ASR only supports one endAudio waiter per session")
                logger.error("Rejected duplicate Apple ASR endAudio waiter")
                continuation.resume()
                return
            }
            finishWaiter = FinishWaiter(
                sessionID: waiterSessionID,
                continuation: continuation
            )
        }
    }

    private func finishStream(
        sessionID finishingSessionID: UUID,
        emitFallbackFinal: Bool,
        error: Error?
    ) {
        guard sessionID == finishingSessionID, !didFinishStream else { return }
        didFinishStream = true

        if emitFallbackFinal, !latestTranscript.isEmpty {
            eventContinuation?.yield(Self.makeTranscript(text: latestTranscript, isFinal: true))
        }

        if let error {
            eventContinuation?.yield(.error(error))
        }

        eventContinuation?.yield(.completed)
        eventContinuation?.finish()
        eventContinuation = nil

        if let finishWaiter {
            if finishWaiter.sessionID != finishingSessionID {
                logger.error("Apple ASR finish waiter belongs to a different session")
            }
            finishWaiter.continuation.resume()
            self.finishWaiter = nil
        }
    }

    private func invalidateCurrentSession(emitCompleted: Bool) {
        let invalidatedSessionID = sessionID
        let invalidatedRecognitionSession = recognitionSession
        let invalidatedContinuation = eventContinuation
        let invalidatedWaiter = finishWaiter
        let shouldEmitCompleted = emitCompleted && invalidatedSessionID != nil && !didFinishStream

        // 先使会话失效，再取消底层任务，保证迟到回调无法命中新会话。
        sessionID = nil
        recognitionSession = nil
        eventContinuation = nil
        _events = nil
        finishWaiter = nil
        latestTranscript = ""
        didFinishStream = false
        didLogInputBuffer = false

        if shouldEmitCompleted {
            invalidatedContinuation?.yield(.completed)
        }
        invalidatedContinuation?.finish()
        invalidatedWaiter?.continuation.resume()
        invalidatedRecognitionSession?.cancel()
    }

    #if DEBUG
    var hasFinishWaiterForTesting: Bool {
        finishWaiter != nil
    }
    #endif

    static func preferredLocale(for config: AppleASRConfig) -> Locale {
        Locale(identifier: config.localeIdentifier)
    }

    fileprivate static func validateOnDeviceRecognizer(
        requestedLocaleIdentifier: String,
        resolvedLocaleIdentifier: String?,
        isAvailable: Bool,
        supportsOnDeviceRecognition: Bool
    ) throws {
        guard let resolvedLocaleIdentifier,
              canonicalLocaleIdentifier(resolvedLocaleIdentifier)
                == canonicalLocaleIdentifier(requestedLocaleIdentifier) else {
            throw AppleASRError.onDeviceRecognitionUnsupported(
                localeIdentifier: requestedLocaleIdentifier
            )
        }
        guard supportsOnDeviceRecognition else {
            throw AppleASRError.onDeviceRecognitionUnsupported(
                localeIdentifier: requestedLocaleIdentifier
            )
        }
        guard isAvailable else {
            throw AppleASRError.recognizerUnavailable
        }
    }

    private static func canonicalLocaleIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    @MainActor
    fileprivate static func configureOnDeviceRequest(
        _ request: SFSpeechAudioBufferRecognitionRequest,
        supportsOnDeviceRecognition: Bool,
        localeIdentifier: String
    ) throws {
        guard supportsOnDeviceRecognition else {
            throw AppleASRError.onDeviceRecognitionUnsupported(
                localeIdentifier: localeIdentifier
            )
        }
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
    }

    @MainActor
    static func configureOnDeviceRequestForTesting(
        _ request: SFSpeechAudioBufferRecognitionRequest,
        supportsOnDeviceRecognition: Bool,
        localeIdentifier: String
    ) throws {
        try configureOnDeviceRequest(
            request,
            supportsOnDeviceRecognition: supportsOnDeviceRecognition,
            localeIdentifier: localeIdentifier
        )
    }

    static func validateOnDeviceRecognizerForTesting(
        requestedLocaleIdentifier: String,
        resolvedLocaleIdentifier: String?,
        isAvailable: Bool,
        supportsOnDeviceRecognition: Bool
    ) throws {
        try validateOnDeviceRecognizer(
            requestedLocaleIdentifier: requestedLocaleIdentifier,
            resolvedLocaleIdentifier: resolvedLocaleIdentifier,
            isAvailable: isAvailable,
            supportsOnDeviceRecognition: supportsOnDeviceRecognition
        )
    }

    private static func makeTranscript(text: String, isFinal: Bool) -> RecognitionEvent {
        .transcript(
            RecognitionTranscript(
                confirmedSegments: isFinal ? [text] : [],
                partialText: isFinal ? "" : text,
                authoritativeText: isFinal ? text : "",
                isFinal: isFinal
            )
        )
    }
}
