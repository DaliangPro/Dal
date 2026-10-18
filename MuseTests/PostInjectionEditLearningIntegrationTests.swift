import AppKit
import XCTest
@testable import Muse

@MainActor
final class PostInjectionEditLearningIntegrationTests: XCTestCase {
    func testNormalNativeEditorDoesNotNeedOptionalSubroleToStartLearning() {
        _ = NSApplication.shared
        let editor = NSTextView()
        XCTAssertEqual(editor.accessibilityRole(), .textArea)
        XCTAssertNil(editor.accessibilitySubrole(), "原生普通文本框本来就可以不提供 Subrole")
        XCTAssertTrue(PostInjectionEditLearningMonitor.supportsCapture(
            role: editor.accessibilityRole()?.rawValue, subrole: editor.accessibilitySubrole()?.rawValue,
            editable: nil, protectedContent: nil
        ))
        let password = NSSecureTextField()
        XCTAssertFalse(PostInjectionEditLearningMonitor.supportsCapture(
            role: password.accessibilityRole()?.rawValue, subrole: password.accessibilitySubrole()?.rawValue,
            editable: nil, protectedContent: nil
        ))
    }

    func testSessionSlowClipboardNativeEditAutomaticallyLearnsAndCorrectsNextOutput() async throws {
        try await verifyNativeSession(reportsCount: true)
    }

    func testSessionWithoutCharacterCountAutomaticallyLearnsAndCorrectsNextOutput() async throws {
        try await verifyNativeSession(reportsCount: false)
    }

    private func verifyNativeSession(reportsCount: Bool) async throws {
        let fixture = try LearningChainFixture()
        defer { fixture.cleanup() }
        let editor = LearningNativeEditor()
        let learningField = reportsCount ? editor.field : editor.fieldWithoutCount
        let injection = LearningClipboardInjection(editor: editor)
        let session = RecognitionSession(
            audioEngine: LearningChainAudio(), injectionEngine: injection, historyStore: fixture.history,
            asrClientFactory: { _ in LearningChainRecognizer(text: "cloud.") }, selectedASRProvider: { .apple },
            asrConfigLoader: { _ in AppleASRConfig(credentials: [:])! }, microphonePermission: { true },
            promptContextCapture: { PromptContext(selectedText: "", clipboardText: "") },
            writingContextCapture: { _ in WritingContext() },
            frontmostApplicationBundleIdentifier: { "pro.example.editor" },
            requestOptionsProvider: { _ in (ASRRequestOptions(), 0) },
            editLearningMonitor: fixture.monitor, editLearningFieldCapture: { await MainActor.run {
                let supported = PostInjectionEditLearningMonitor.supportsCapture(
                    role: editor.view.accessibilityRole()?.rawValue,
                    subrole: editor.view.accessibilitySubrole()?.rawValue,
                    editable: editor.view.isEditable, protectedContent: nil
                )
                return supported ? .field(learningField) : .unavailable(.unsafeField)
            } },
            vocabularyContext: fixture.context
        )
        let appState = AppState(initialModes: ProcessingMode.defaults)
        let status = AutomaticLearningStatus()
        let notification = NotificationCenter.default.addObserver(
            forName: .voicePolishAutomaticLearningDidFinish, object: nil, queue: .main
        ) { note in
            guard let feedback = note.object as? AutomaticLearningFeedback else { return }
            MainActor.assumeIsolated {
                status.update(feedback)
                appState.showAutomaticLearningFeedback(feedback)
            }
        }
        defer { NotificationCenter.default.removeObserver(notification); appState.cancel() }

        await session.startRecording(mode: .direct)
        await session.stopRecording()
        let phase = await session.state
        XCTAssertEqual(phase, .idle, "等候上屏验证不能阻塞下一次输入")
        try await waitUntil { editor.hasVerifiedOriginal }
        XCTAssertEqual(editor.view.string, "cloud.")
        editor.replace(with: "Claude")
        try await waitUntil { status.latest?.didPersist == true }
        XCTAssertTrue(appState.feedbackMessage.contains("Claude"), "真实观察循环必须发出成功反馈")
        let corrections = try await fixture.history.fetchVoicePolishCorrections()
        XCTAssertEqual(corrections.count, 1)
        XCTAssertFalse(try XCTUnwrap(corrections.first).learnStyle)
        XCTAssertEqual(TerminologyRepository.projections(context: fixture.context).corrections["cloud"], "Claude")

        editor.hasVerifiedOriginal = false
        await session.startRecording(mode: .direct)
        await session.stopRecording()
        try await waitUntil { editor.hasVerifiedOriginal }
        XCTAssertEqual(editor.view.string, "Claude.", "下一次完整会话须自动应用学到的规则")
        editor.available = false
    }

    func testRealObservationCanLearnOtherWordsWithoutHardCodedCloudRule() async throws {
        let fixture = try LearningChainFixture()
        defer { fixture.cleanup() }
        let editor = LearningNativeEditor()
        await fixture.insert(id: "generic", text: "我使用 alfadeck 编辑")
        editor.replace(with: "我使用 alfadeck 编辑")
        await fixture.monitor.start(
            injectedText: editor.view.string, historyID: "generic", capture: .field(editor.field), historyStore: fixture.history
        )
        try await waitUntil { editor.hasVerifiedOriginal }
        editor.replace(with: "我使用 AlphaDeck 编辑")
        try await waitUntil {
            TerminologyRepository.projections(context: fixture.context).corrections["alfadeck"] == "AlphaDeck"
        }
        XCTAssertNil(TerminologyRepository.projections(context: fixture.context).corrections["cloud"])
        editor.available = false
    }

    func testUnextractableIntermediateEditDoesNotEndActualObservation() async throws {
        let fixture = try LearningChainFixture()
        defer { fixture.cleanup() }
        let editor = LearningNativeEditor()
        await fixture.insert(id: "intermediate", text: "cloud.")
        editor.replace(with: "cloud.")
        await fixture.monitor.start(
            injectedText: "cloud.", historyID: "intermediate", capture: .field(editor.field), historyStore: fixture.history
        )
        try await waitUntil { editor.hasVerifiedOriginal }
        editor.replace(with: "cloud!")
        try await Task.sleep(for: .seconds(2.2))
        editor.replace(with: "Claude")
        try await waitUntil {
            TerminologyRepository.projections(context: fixture.context).corrections["cloud"] == "Claude"
        }
        editor.available = false
    }

    func testFocusLeavesWhileWaitingForPasteNeverReadsAnotherField() async throws {
        let editor = LearningNativeEditor()
        editor.available = false
        let target = await PostInjectionEditLearningMonitor.capture(
            injectedText: "cloud.", historyID: "not-focused", field: editor.field
        )
        XCTAssertNil(target)
        XCTAssertEqual(editor.rangeReads, 0)
    }

    func testCaptureFailureDoesNotPostTechnicalFailureNotification() async throws {
        let fixture = try LearningChainFixture()
        defer { fixture.cleanup() }
        let reportCount = NotificationReportCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .voicePolishAutomaticLearningDidFinish, object: nil, queue: nil
        ) { _ in reportCount.increment() }
        defer { NotificationCenter.default.removeObserver(token) }

        await fixture.monitor.start(
            injectedText: "cloud.", historyID: "unsupported", capture: .unavailable(.unsupportedField),
            historyStore: fixture.history
        )
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reportCount.value, 0, "输入框能力不足时不应弹出技术失败提示")
    }

    func testTransientFieldLookupRetriesUntilInputBoxBecomesReadable() async throws {
        let fixture = try LearningChainFixture()
        defer { fixture.cleanup() }
        let editor = LearningNativeEditor()
        await fixture.insert(id: "delayed-field", text: "cloud.")
        editor.replace(with: "cloud.")
        let attempts = NotificationReportCounter()
        await fixture.monitor.start(
            injectedText: "cloud.", historyID: "delayed-field",
            captureProvider: {
                let attempt = attempts.incrementAndRead()
                if attempt < 3 { return .unavailable(.unavailable) }
                return .field(editor.field)
            },
            historyStore: fixture.history
        )
        try await waitUntil { editor.hasVerifiedOriginal }
        editor.replace(with: "Claude")
        try await waitUntil {
            TerminologyRepository.projections(context: fixture.context).corrections["cloud"] == "Claude"
        }
        XCTAssertGreaterThanOrEqual(attempts.value, 3)
    }

    func testQuickFocusDepartureUsesOnlyLastVerifiedSnapshot() async throws {
        let fixture = try LearningChainFixture()
        defer { fixture.cleanup() }
        let editor = LearningNativeEditor()
        await fixture.insert(id: "quick-departure", text: "cloud")
        editor.replace(with: "cloud")
        await fixture.monitor.start(injectedText: "cloud", historyID: "quick-departure",
                                    capture: .field(editor.field), historyStore: fixture.history)
        try await waitUntil { editor.hasVerifiedOriginal }
        editor.replace(with: "Claude")
        try await waitUntil { editor.lastReadText == "Claude" }
        let reads = editor.rangeReads
        editor.available = false
        editor.allowsFocusFinalization = true
        try await waitUntil {
            TerminologyRepository.projections(context: fixture.context).corrections["cloud"] == "Claude"
        }
        XCTAssertEqual(editor.rangeReads, reads, "失焦后不能再读取正文或新输入框")
    }

    func testSafetyFailureDoesNotCommitCachedCorrection() async throws {
        let fixture = try LearningChainFixture()
        defer { fixture.cleanup() }
        let editor = LearningNativeEditor()
        await fixture.insert(id: "unsafe-departure", text: "cloud")
        editor.replace(with: "cloud")
        await fixture.monitor.start(injectedText: "cloud", historyID: "unsafe-departure",
                                    capture: .field(editor.field), historyStore: fixture.history)
        try await waitUntil { editor.hasVerifiedOriginal }
        editor.replace(with: "Claude")
        try await waitUntil { editor.lastReadText == "Claude" }
        editor.available = false
        // 安全/能力检查失败不能当成正常切换焦点。
        editor.allowsFocusFinalization = false
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(TerminologyRepository.projections(context: fixture.context).corrections["cloud"])
    }

    func testActualObservationContinuesAfterRelatedEditExtendsIdleTimeout() async throws {
        let fixture = try LearningChainFixture(timing: PostInjectionObservationTiming(
            pollingInterval: .milliseconds(20), stableDuration: .milliseconds(60),
            idleTimeout: .milliseconds(400), maximumLifetime: .seconds(2)
        ))
        defer { fixture.cleanup() }
        let editor = LearningNativeEditor()
        await fixture.insert(id: "extended", text: "cloud.")
        editor.replace(with: "cloud.")
        await fixture.monitor.start(injectedText: "cloud.", historyID: "extended",
                                    capture: .field(editor.field), historyStore: fixture.history)
        try await waitUntil { editor.hasVerifiedOriginal }
        try await Task.sleep(for: .milliseconds(250))
        editor.replace(with: "cloud!")
        try await waitUntil { editor.lastReadText == "cloud!" }
        try await Task.sleep(for: .milliseconds(250))
        editor.replace(with: "Claude")
        try await waitUntil {
            TerminologyRepository.projections(context: fixture.context).corrections["cloud"] == "Claude"
        }
        editor.available = false
    }

    func testRangeReadFailureClearsSnapshotBeforeFocusDeparture() async throws {
        let fixture = try LearningChainFixture()
        defer { fixture.cleanup() }
        let editor = LearningNativeEditor()
        await fixture.insert(id: "range-failed", text: "cloud")
        editor.replace(with: "cloud")
        await fixture.monitor.start(injectedText: "cloud", historyID: "range-failed",
                                    capture: .field(editor.field), historyStore: fixture.history)
        try await waitUntil { editor.hasVerifiedOriginal }
        editor.replace(with: "Claude")
        try await waitUntil { editor.lastReadText == "Claude" }
        editor.failsRangeReads = true
        try await waitUntil { editor.didFailRangeRead }
        // 等本轮 nil 候选处理完成，随后模拟正常切换焦点。
        try await Task.sleep(for: .milliseconds(50))
        editor.available = false
        editor.allowsFocusFinalization = true
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertNil(TerminologyRepository.projections(context: fixture.context).corrections["cloud"])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), "自动学习链路没有按期完成")
    }
}

private final class NotificationReportCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func incrementAndRead() -> Int {
        lock.lock()
        count += 1
        let result = count
        lock.unlock()
        return result
    }
}

/// 使用真实 AppKit 输入框及其范围读取方法，只有系统焦点查询由固定测试对象替代。
@MainActor
private final class LearningNativeEditor {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 160))
    var available = true
    var hasVerifiedOriginal = false
    var rangeReads = 0
    var lastReadText: String?
    var allowsFocusFinalization = false
    var failsRangeReads = false
    var didFailRangeRead = false

    init() { view.isRichText = false }

    func replace(with text: String) {
        view.string = text
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    nonisolated var field: PostInjectionLearningField {
        PostInjectionLearningField(
            isAvailable: { await MainActor.run { self.available } },
            selectedRange: { await MainActor.run {
                let range = self.view.accessibilitySelectedTextRange()
                return CFRange(location: range.location, length: range.length)
            } },
            characterCount: { await MainActor.run { self.view.accessibilityNumberOfCharacters() } },
            stringForRange: { range in await MainActor.run {
                self.rangeReads += 1
                if self.failsRangeReads { self.didFailRangeRead = true; return nil }
                let text = self.view.accessibilityString(for: NSRange(location: range.location, length: range.length))
                if text == self.view.string, !(text ?? "").isEmpty {
                    self.lastReadText = text
                    self.hasVerifiedOriginal = true
                }
                return text
            } },
            canFinishAfterFocusLoss: { await MainActor.run { self.allowsFocusFinalization } }
        )
    }

    nonisolated var fieldWithoutCount: PostInjectionLearningField {
        let native = field
        return PostInjectionLearningField(
            isAvailable: native.isAvailable, selectedRange: native.selectedRange, characterCount: { nil },
            readRange: { range in await MainActor.run {
                guard range.location >= 0, range.length >= 0,
                      range.location + range.length <= self.view.accessibilityNumberOfCharacters() else { return .outOfBounds }
                self.rangeReads += 1
                guard let text = self.view.accessibilityString(for: NSRange(location: range.location, length: range.length)) else { return .unavailable }
                if text == self.view.string, !text.isEmpty { self.hasVerifiedOriginal = true }
                return .text(text)
            } }
        )
    }
}

private struct LearningChainFixture {
    let context: VocabularyStorageContext
    let history: HistoryStore
    let monitor: PostInjectionEditLearningMonitor
    let suiteName: String

    init(timing: PostInjectionObservationTiming = PostInjectionObservationTiming()) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MuseLearningChain-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "MuseLearningChain.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        context = VocabularyStorageContext(
            supportDirectory: directory, userDefaults: defaults, fileManager: .default,
            hotwordsDidChange: {}, revealFile: { _ in }
        )
        try HotwordStorage.saveBuiltin(["Claude"], context: context)
        try SnippetStorage.saveBuiltin([], context: context)
        _ = try TerminologyRepository.migrateIfNeeded(context: context)
        VoicePolishSettings.setTerminologyLearningEnabled(true, defaults: defaults)
        history = HistoryStore(path: directory.appendingPathComponent("history.db").path)
        monitor = PostInjectionEditLearningMonitor(
            coordinator: TerminologyHistoryTransactionCoordinator(context: context), settingsContext: context,
            observationTiming: timing
        )
    }

    func insert(id: String, text: String) async {
        await history.insert(HistoryRecord(
            id: id, createdAt: Date(), durationSeconds: 1, rawText: text, processingMode: "直出",
            processedText: nil, finalText: text, status: "completed", characterCount: text.count
        ))
    }

    func cleanup() {
        context.userDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.trashItem(at: context.supportDirectory, resultingItemURL: nil)
    }
}

private final class LearningClipboardInjection: TextInjecting, @unchecked Sendable {
    var preserveClipboard = true
    private let engine: TextInjectionEngine

    init(editor: LearningNativeEditor) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MuseLearningChain.\(UUID())"))
        engine = TextInjectionEngine(
            pasteboard: pasteboard, clipboardLeaseCoordinator: ClipboardLeaseCoordinator(),
            pasteSimulator: {
                let text = pasteboard.string(forType: .string) ?? ""
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    editor.replace(with: text)
                }
                return true
            }, sleep: { _ in }, logger: { _ in }
        )
    }

    func inject(_ text: String) -> InjectionOutcome {
        engine.injectViaClipboard(text, hasFrontmostApplication: true)
    }
}

private actor LearningChainRecognizer: SpeechRecognizer {
    let events: AsyncStream<RecognitionEvent>
    private let continuation: AsyncStream<RecognitionEvent>.Continuation
    private let text: String

    init(text: String) {
        let pair = AsyncStream<RecognitionEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.text = text
    }

    func connect(config: any ASRProviderConfig, options: ASRRequestOptions) async throws {}
    func endAudio() async throws {
        continuation.yield(.transcript(RecognitionTranscript(
            confirmedSegments: [text], partialText: "", authoritativeText: text, isFinal: true
        )))
        continuation.yield(.completed)
        continuation.finish()
    }
    func disconnect() async {}
}

private final class LearningChainAudio: AudioCaptureControlling, @unchecked Sendable {
    func warmUp() {}
    func setAudioHandlers(onChunk: ((Data) -> Void)?, onLevel: ((Float) -> Void)?) {}
    func setAudioChunkHandler(_ handler: ((Data) -> Void)?) {}
    func clearAudioHandlers() {}
    func start(timeout: Duration) async throws {}
    func stop() {}
    func getRecordedAudio() -> Data { Data() }
}
