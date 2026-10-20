import XCTest
@testable import Dal

final class RecognitionSessionTests: XCTestCase {
    override func tearDown() {
        KeychainService.selectedASRProvider = .volcano
    }

    func testLegacyLightAndPolishUseStandardConfiguration() async throws {
        try await KeychainService.withIsolatedPolishSettingsForTestingAsync {
            let fixture = try RecognitionSessionVocabularyFixture()
            defer { fixture.cleanup() }
            for (role, model) in [(PolishModelRole.light, "light-model"), (.standard, "standard-model")] {
                KeychainService.setSelectedPolishProvider(.bailian, for: role)
                try KeychainService.savePolishCredentials(for: .bailian, role: role, values: [
                    "apiKey": "test-key", "model": model, "baseURL": "https://example.com/v1"
                ])
            }
            let source = "明天上午开会。"
            let client = RecognitionSessionVoicePolishLLM(response: source)
            let session = RecognitionSession(historyStore: HistoryStore(path: ":memory:"), llmClientFactory: { client })
            let transcript = RecognitionTranscript(confirmedSegments: [source], partialText: "", authoritativeText: source, isFinal: true)
            for mode in [ProcessingMode.lightPolish, .formalWriting] {
                let result = await session.postProcessForTesting(rawText: source, transcript: transcript, mode: mode, vocabularyContext: fixture.context)
                XCTAssertFalse(result?.llmFailed ?? true)
            }
            let models = await client.recordedModels()
            XCTAssertEqual(models, ["standard-model", "standard-model"])
            let requests = await client.recordedRequests()
            XCTAssertEqual(requests.map(\.task), [.voicePolishStructured, .voicePolishStructured])
        }
    }

    func testInitialStateIsIdle() async {
        let session = makeSession()
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func testStopDuringBlockedTargetApplicationCaptureCannotStartZombieSession() async throws {
        let gate = RecognitionSessionApplicationCaptureGate()
        let recorder = RecognitionEventRecorder()
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            frontmostApplicationBundleIdentifier: { await gate.capture() }
        )
        await session.setOnASREvent { recorder.record($0) }

        let startTask = Task { await session.startRecording(mode: .direct) }
        for _ in 0..<100 {
            if await gate.hasStarted { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let didStartCapture = await gate.hasStarted
        XCTAssertTrue(didStartCapture)

        await session.stopRecording()
        await gate.resolve("com.example.target")
        await startTask.value

        let finalState = await session.state
        XCTAssertEqual(finalState, .idle)
        XCTAssertTrue(recorder.values.contains("completed"))
    }

    func testAbortDuringBlockedTargetApplicationCaptureCannotStartZombieSession() async throws {
        let gate = RecognitionSessionApplicationCaptureGate()
        let recorder = RecognitionEventRecorder()
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            frontmostApplicationBundleIdentifier: { await gate.capture() }
        )
        await session.setOnASREvent { recorder.record($0) }

        let startTask = Task { await session.startRecording(mode: .direct) }
        for _ in 0..<100 {
            if await gate.hasStarted { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let didStartCapture = await gate.hasStarted
        XCTAssertTrue(didStartCapture)

        await session.abortCurrentSession()
        await gate.resolve("com.example.target")
        await startTask.value

        let finalState = await session.state
        XCTAssertEqual(finalState, .idle)
        XCTAssertTrue(recorder.values.contains("completed"))
    }

    func testSetState() async {
        let session = makeSession()
        await session.setState(.recording)
        let state = await session.state
        XCTAssertEqual(state, .recording)
        await session.setState(.idle)
    }

    func testCanStartRecordingOnlyWhenIdle() async {
        let session = makeSession()
        var canStart = await session.canStartRecording
        XCTAssertTrue(canStart)

        await session.setState(.recording)
        canStart = await session.canStartRecording
        XCTAssertFalse(canStart)
        await session.setState(.idle)
    }

    func testSwitchModeAppliesToDirect() async {
        KeychainService.selectedASRProvider = .volcano
        let session = makeSession()

        await session.switchMode(to: .direct)

        let mode = await session.currentModeForTesting()
        XCTAssertEqual(mode.id, ProcessingMode.directId)
    }

    func testSwitchModeDirectWorksForVolcano() async {
        KeychainService.selectedASRProvider = .volcano
        let session = makeSession()

        await session.switchMode(to: .direct)

        let mode = await session.currentModeForTesting()
        XCTAssertEqual(mode.id, ProcessingMode.directId)
    }

    func testReadyEventsAreDeduplicated() async {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }

        await session.handleASREventForTesting(.ready)
        await session.handleASREventForTesting(.ready)

        XCTAssertEqual(recorder.values, ["ready"])
        let emittedReady = await session.hasEmittedReadyForTesting
        XCTAssertTrue(emittedReady)
    }

    func testTranscriptEventUpdatesStoredTranscriptAndForwardsToUI() async {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }
        let transcript = RecognitionTranscript(
            confirmedSegments: ["hello "],
            partialText: "world",
            authoritativeText: "",
            isFinal: false
        )

        await session.handleASREventForTesting(.transcript(transcript))

        XCTAssertEqual(recorder.values, ["transcript:hello world"])
        let storedTranscript = await session.transcriptForTesting
        XCTAssertEqual(storedTranscript, transcript)
    }

    func testStaleASREventsAreIgnoredAfterSessionChanges() async throws {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }
        await session.handleASREventForTesting(.ready)
        let staleSessionIDCandidate = await session.currentSessionIDForTesting
        let staleSessionID = try XCTUnwrap(staleSessionIDCandidate)
        await session.setState(.recording)
        await session.forceResetForTesting()

        await session.handleASREventForTesting(
            .transcript(RecognitionTranscript(
                confirmedSegments: ["stale"],
                partialText: "",
                authoritativeText: "",
                isFinal: true
            )),
            expectedSessionID: staleSessionID
        )

        XCTAssertEqual(recorder.values, ["ready"])
        let storedTranscript = await session.transcriptForTesting
        XCTAssertEqual(storedTranscript, .empty)
    }

    func testAbortCurrentSessionWhileIdleEmitsCompletedForUICleanup() async {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }

        await session.abortCurrentSession()

        XCTAssertEqual(recorder.values, ["completed"])
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func testAbortCurrentSessionFromStartingResetsToIdleAndEmitsCompleted() async {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }
        await session.setState(.starting)

        await session.abortCurrentSession()

        XCTAssertEqual(recorder.values, ["completed"])
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func testASRErrorWhileRecordingPreservesSessionForStopTimeRecovery() async {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }
        await session.setState(.recording)

        await session.handleASREventForTesting(.error(NSError(
            domain: "RecognitionSessionTests",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "ASR failed"]
        )))
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(recorder.values, ["streamingInterrupted"])
        let state = await session.state
        XCTAssertEqual(state, .recording)
    }

    func testStopDuringStartingEmitsCompletedForUICleanup() async {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }
        await session.setState(.starting)

        await session.stopRecording()

        XCTAssertEqual(recorder.values, ["completed"])
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func testStreamingInterruptedKeepsRecordingActive() async {
        let session = makeSession()
        let recorder = RecognitionEventRecorder()
        await session.setOnASREvent { recorder.record($0) }
        await session.setState(.recording)

        await session.handleASREventForTesting(.streamingInterrupted)

        XCTAssertEqual(recorder.values, ["streamingInterrupted"])
        let state = await session.state
        XCTAssertEqual(state, .recording)
    }

    func testPolishPrefetchCannotReplaceTheChangedFinalTranscript() async throws {
        let source = "明天下午三点开会。"
        let client = RecognitionSessionVoicePolishLLM(response: source)
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmClientFactory: { client },
            llmConfigLoader: {
                LLMConfig(
                    apiKey: "test",
                    model: "mock-model",
                    baseURL: "https://example.com/v1"
                )
            }
        )
        await session.setState(.recording)
        await session.switchMode(to: .formalWriting)
        await session.handleASREventForTesting(.transcript(RecognitionTranscript(
            confirmedSegments: [],
            partialText: "明天下午",
            authoritativeText: "",
            isFinal: false
        )))
        // 等待预生成实际开始；固定延迟在繁忙的CI机器上不能保证任务已获得调度。
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await client.requestCount() == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let speculativeCount = await client.requestCount()
        XCTAssertEqual(speculativeCount, 1)

        let finalTranscript = RecognitionTranscript(
            confirmedSegments: [source],
            partialText: "",
            authoritativeText: source,
            isFinal: true
        )
        let result = await session.postProcessVoicePolishForTesting(
            rawText: source,
            transcript: finalTranscript
        )

        XCTAssertEqual(result?.finalText, source)
        XCTAssertEqual(result?.processedText, source)
        XCTAssertEqual(result?.llmFailed, false)
        XCTAssertEqual(result?.historyStatus, "voice_polish_success")
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.task), [.voicePolishStructured, .voicePolishStructured])
        XCTAssertEqual(try Self.voicePolishPayload(from: XCTUnwrap(requests.first))["canonical_text"] as? String, "明天下午")
        XCTAssertEqual(try Self.voicePolishPayload(from: XCTUnwrap(requests.last))["canonical_text"] as? String, source)
    }

    func testVoicePolishUsesCanonicalTextAndCompleteEffectiveSnippetRules() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try SnippetStorage.saveBuiltin([
            (trigger: "Type less", value: "Typeless"),
            (trigger: "Cloud Code", value: "Claude Code"),
            (trigger: "把这整句替换掉。", value: "内置整句。"),
        ], context: fixture.context)
        try SnippetStorage.save([
            (trigger: "Code X", value: "Codex"),
            (trigger: "把这整句替换掉。", value: "用户整句。"),
        ], context: fixture.context)
        VoicePolishSettings.setModelOverride(
            "voice-polish-fast-model",
            defaults: fixture.context.userDefaults
        )
        let raw = "我在用 Type less、Cloud Code 和 Code X。把这整句替换掉。"
        let canonical = "我在用 Typeless、Claude Code 和 Codex。用户整句。"
        let client = RecognitionSessionVoicePolishLLM(response: canonical)
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmClientFactory: { client },
            llmConfigLoader: {
                LLMConfig(
                    apiKey: "test",
                    model: "mock-model",
                    baseURL: "https://example.com/v1"
                )
            }
        )
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let result = await session.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(result?.finalText, canonical)
        XCTAssertEqual(result?.processedText, canonical)
        XCTAssertFalse(result?.llmFailed ?? true)
        let requests = await client.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let payload = try Self.voicePolishPayload(from: request)
        XCTAssertEqual(payload["canonical_text"] as? String, canonical)
        XCTAssertFalse(request.user.contains("内置整句"))
        let models = await client.recordedModels()
        // 配置加载器已完成按档解析，旧覆盖值不能再次覆盖已选择的模型。
        XCTAssertEqual(models, ["mock-model"])
    }

    func testDirectAndVoicePolishShareGlobalCanonicalAndFixedSnippetBehavior() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try TerminologyRepository.save(
            TerminologyDocument(entries: [TerminologyEntry(
                canonicalText: "Typeless",
                aliases: [TerminologyAlias(text: "Type less")],
                origin: .manual,
                scope: .global
            )]),
            context: fixture.context
        )
        try SnippetStorage.save([
            (trigger: "旧的整句模板。", value: "固定替换成功。"),
        ], context: fixture.context)
        let raw = "我正在使用 Type less。旧的整句模板。"
        let expected = "我正在使用 Typeless。固定替换成功。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let directSession = RecognitionSession(historyStore: HistoryStore(path: ":memory:"))
        let directResult = await directSession.postProcessForTesting(
            rawText: raw,
            transcript: transcript,
            mode: .direct,
            vocabularyContext: fixture.context
        )
        let voicePolishSession = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let voicePolishResult = await voicePolishSession.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(directResult?.finalText, expected)
        XCTAssertEqual(voicePolishResult?.finalText, expected)
    }

    func testAllASRProvidersShareLocalCanonicalFinalization() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try TerminologyRepository.save(
            TerminologyDocument(entries: [TerminologyEntry(
                canonicalText: "Typeless",
                aliases: [TerminologyAlias(text: "type list")],
                origin: .manual,
                scope: .global
            )]),
            context: fixture.context
        )
        let raw = "我正在使用 type list。"
        let expected = "我正在使用 Typeless。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        for provider in ASRProvider.allCases {
            let session = RecognitionSession(historyStore: HistoryStore(path: ":memory:"))
            let result = await session.postProcessForTesting(
                rawText: raw,
                transcript: transcript,
                mode: .direct,
                provider: provider,
                vocabularyContext: fixture.context
            )
            XCTAssertEqual(result?.finalText, expected, provider.rawValue)
        }
    }

    func testDirectAndVoicePolishApplyApplicationTerminologyForSameTarget() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        let targetApplication = "com.example.app-a"
        try TerminologyRepository.save(
            TerminologyDocument(entries: [TerminologyEntry(
                canonicalText: "Typeless",
                aliases: [TerminologyAlias(text: "Type less")],
                origin: .manual,
                scope: .application(targetApplication)
            )]),
            context: fixture.context
        )
        let raw = "我正在使用 Type less。"
        let expected = "我正在使用 Typeless。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let directSession = RecognitionSession(historyStore: HistoryStore(path: ":memory:"))
        let directResult = await directSession.postProcessForTesting(
            rawText: raw,
            transcript: transcript,
            mode: .direct,
            applicationBundleIdentifier: targetApplication,
            vocabularyContext: fixture.context
        )
        let voicePolishSession = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let voicePolishResult = await voicePolishSession.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            writingContext: WritingContext(applicationBundleID: targetApplication),
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(directResult?.finalText, expected)
        XCTAssertEqual(voicePolishResult?.finalText, expected)
    }

    func testApplicationTerminologyDoesNotLeakToOtherTargetInEitherMode() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try TerminologyRepository.save(
            TerminologyDocument(entries: [TerminologyEntry(
                canonicalText: "Typeless",
                aliases: [TerminologyAlias(text: "Type less")],
                origin: .manual,
                scope: .application("com.example.app-a")
            )]),
            context: fixture.context
        )
        let otherApplication = "com.example.app-b"
        let raw = "我正在使用 Type less。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let directSession = RecognitionSession(historyStore: HistoryStore(path: ":memory:"))
        let directResult = await directSession.postProcessForTesting(
            rawText: raw,
            transcript: transcript,
            mode: .direct,
            applicationBundleIdentifier: otherApplication,
            vocabularyContext: fixture.context
        )
        let voicePolishSession = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let voicePolishResult = await voicePolishSession.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            writingContext: WritingContext(applicationBundleID: otherApplication),
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(directResult?.finalText, raw)
        XCTAssertEqual(voicePolishResult?.finalText, raw)
    }

    func testCapturedNilTargetDoesNotFallBackToLaterVoicePolishFocus() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        let laterFocusedApplication = "com.example.later-focused"
        try TerminologyRepository.save(
            TerminologyDocument(entries: [TerminologyEntry(
                canonicalText: "Typeless",
                aliases: [TerminologyAlias(text: "Type less")],
                origin: .manual,
                scope: .application(laterFocusedApplication)
            )]),
            context: fixture.context
        )
        let raw = "我正在使用 Type less。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )

        let result = await session.postProcessForTesting(
            rawText: raw,
            transcript: transcript,
            mode: .formalWriting,
            writingContext: WritingContext(
                applicationBundleID: laterFocusedApplication
            ),
            applicationBundleIdentifier: nil,
            applicationBundleIdentifierWasCaptured: true,
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(result?.finalText, raw)
    }

    func testLegacyLLMAndVoicePolishFallbackBothUseCanonicalText() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try TerminologyRepository.save(
            TerminologyDocument(entries: [TerminologyEntry(
                canonicalText: "Typeless",
                aliases: [TerminologyAlias(text: "Type less")],
                origin: .manual,
                scope: .global
            )]),
            context: fixture.context
        )
        let raw = "我正在使用 Type less。"
        let expected = "我正在使用 Typeless。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let legacyLLMSession = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let legacyResult = await legacyLLMSession.postProcessForTesting(
            rawText: raw,
            transcript: transcript,
            mode: .smartDirect,
            vocabularyContext: fixture.context
        )
        let voicePolishSession = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let voicePolishResult = await voicePolishSession.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(legacyResult?.finalText, expected)
        XCTAssertTrue(legacyResult?.llmFailed ?? false)
        XCTAssertEqual(voicePolishResult?.finalText, expected)
        XCTAssertTrue(voicePolishResult?.llmFailed ?? false)
    }

    func testConfirmedHistoryCorrectionIsCanonicalInNextRecognitionSession() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try TerminologyRepository.save(.empty, context: fixture.context)
        let historyID = "history-confirmed-for-next-session"
        let historyStore = HistoryStore(
            path: fixture.directory.appendingPathComponent("history.db").path
        )
        await historyStore.insert(HistoryRecord(
            id: historyID,
            createdAt: Date(),
            durationSeconds: 1,
            rawText: "我正在使用 Type less。",
            processingMode: ProcessingMode.formalWriting.name,
            processedText: "我正在使用 Type less。",
            finalText: "我正在使用 Type less。",
            status: "voice_polish_success",
            characterCount: 18
        ))
        let coordinator = TerminologyHistoryTransactionCoordinator(context: fixture.context)
        _ = try await coordinator.confirmCorrection(
            historyStore: historyStore,
            historyID: historyID,
            candidates: [TerminologyCorrectionCandidate(
                alias: "Type less",
                canonical: "Typeless"
            )],
            correctedText: "我正在使用 Typeless。",
            scene: .document,
            personalizationEnabled: true,
            retentionLimit: 200,
            learnStyle: false,
            learnTerminology: true
        )

        let raw = "下一次继续使用 Type less。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )
        let nextSession = RecognitionSession(historyStore: HistoryStore(path: ":memory:"))
        let nextResult = await nextSession.postProcessForTesting(
            rawText: raw,
            transcript: transcript,
            mode: .direct,
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(nextResult?.finalText, "下一次继续使用 Typeless。")
    }

    func testVoicePolishScopesTerminologyByApplicationBeforeCanonicalization() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try TerminologyRepository.save(
            TerminologyDocument(entries: [TerminologyEntry(
                canonicalText: "Typeless",
                aliases: [TerminologyAlias(text: "Type less")],
                origin: .manual,
                scope: .application("com.example.app-a")
            )]),
            context: fixture.context
        )
        let raw = "我正在使用 Type less。"
        let canonical = "我正在使用 Typeless。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let otherApplicationSession = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let otherResult = await otherApplicationSession.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            writingContext: WritingContext(applicationBundleID: "com.example.app-b"),
            vocabularyContext: fixture.context
        )
        XCTAssertEqual(otherResult?.finalText, raw)

        let client = RecognitionSessionVoicePolishLLM(response: canonical)
        let targetApplicationSession = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmClientFactory: { client },
            llmConfigLoader: {
                LLMConfig(
                    apiKey: "test",
                    model: "mock-model",
                    baseURL: "https://example.com/v1"
                )
            }
        )
        let targetResult = await targetApplicationSession.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            writingContext: WritingContext(applicationBundleID: "com.example.app-a"),
            vocabularyContext: fixture.context
        )
        XCTAssertEqual(targetResult?.finalText, canonical)
        let targetRequests = await client.recordedRequests()
        let request = try XCTUnwrap(targetRequests.first)
        let payload = try Self.voicePolishPayload(from: request)
        XCTAssertEqual(payload["canonical_text"] as? String, canonical)
    }

    func testVoicePolishDoesNotBypassRepositorySuppressionThroughLegacySnippets() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try SnippetStorage.save([
            (trigger: "Cloud Code", value: "Claude Code"),
            (trigger: "旧的整句模板。", value: "固定替换成功。"),
        ], context: fixture.context)
        // 空的统一词库会把仍留在兼容文件中的旧术语规则标记为 suppressed。
        // Voice Polish 不能再通过 SnippetStorage.applyEffective 绕过这个决定。
        try TerminologyRepository.save(.empty, context: fixture.context)
        XCTAssertTrue(SnippetStorage.load(context: fixture.context).contains {
            $0.trigger == "Cloud Code" && $0.value == "Claude Code"
        })
        let raw = "请打开 Cloud Code。旧的整句模板。"
        let expected = "请打开 Cloud Code。固定替换成功。"
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let result = await session.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(result?.finalText, expected)
    }

    func testVoicePolishUsesAndRemembersRecentDalInputsOnlyWhenEnabled() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        let applicationID = "com.example.chat"
        let previousInput = "Dal 的长语音测试刚刚结束。无关事项：客户预算九万元。"
        let raw = "达尔这次更新先发测试组。"
        let corrected = "Dal这次更新先发测试组。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )
        defer { VoicePolishContextDiagnostics.clearForTesting() }

        for enabled in [true, false] {
            VoicePolishSettings.setRecentInputContextEnabled(
                enabled,
                defaults: fixture.context.userDefaults
            )
            let recentStore = VoicePolishRecentInputContextStore()
            await recentStore.remember(previousInput, applicationBundleID: applicationID)
            let expected = enabled ? corrected : raw
            let client = RecognitionSessionVoicePolishLLM(response: expected)
            let session = RecognitionSession(
                historyStore: HistoryStore(path: ":memory:"),
                llmClientFactory: { client },
                llmConfigLoader: {
                    LLMConfig(
                        apiKey: "test",
                        model: "mock-model",
                        baseURL: "https://example.com/v1"
                    )
                },
                voicePolishRecentInputStore: recentStore
            )

            let result = await session.postProcessVoicePolishForTesting(
                rawText: raw,
                transcript: transcript,
                writingContext: WritingContext(
                    applicationBundleID: applicationID,
                    scene: .chat,
                    level: .metadataOnly,
                    safety: .safe
                ),
                vocabularyContext: fixture.context
            )

            XCTAssertEqual(result?.finalText, expected, "enabled=\(enabled)")
            XCTAssertEqual(result?.processedText, expected, "enabled=\(enabled)")
            XCTAssertEqual(result?.llmFailed, false, "enabled=\(enabled)")
            let diagnostic = try XCTUnwrap(VoicePolishContextDiagnostics.latest())
            XCTAssertEqual(diagnostic.applicationBundleID, applicationID)
            XCTAssertEqual(diagnostic.recentDalInputCount, enabled ? 1 : 0)
            let requests = await client.recordedRequests()
            XCTAssertEqual(requests.count, 1, "标准模式须直接从原文一次整理")
            for request in requests {
                let payload = try Self.voicePolishPayload(from: request)
                // canonical 已由本地 Resolver 纠正，不能靠模型自行猜对来通过测试。
                XCTAssertEqual(payload["canonical_text"] as? String, expected)
                XCTAssertEqual(Set(payload.keys), ["canonical_text"])
                XCTAssertNil(payload["authorized_context"], "已应用的本地映射不另传为模型上下文")
                XCTAssertFalse(request.user.contains(previousInput))
                XCTAssertFalse(request.user.contains("长语音测试刚刚结束"))
                XCTAssertFalse(request.user.contains("客户预算"))
                XCTAssertFalse(request.user.contains("九万元"))
            }
            let rememberedInputs = await recentStore.recentInputs(
                applicationBundleID: applicationID
            )
            XCTAssertEqual(
                rememberedInputs,
                enabled ? [previousInput, corrected] : [previousInput],
                "关闭后不得记忆本次输出"
            )
        }
    }

    func testPolishWaitsForModelAndCancellationProducesNoText() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try SnippetStorage.saveBuiltin([
            (trigger: "Type less", value: "Typeless"),
        ], context: fixture.context)
        let raw = "我正在使用 Type less。"
        let client = RecognitionSessionBlockingVoicePolishLLM()
        let recorder = RecognitionEventRecorder()
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmClientFactory: { client },
            llmConfigLoader: {
                LLMConfig(
                    apiKey: "test",
                    model: "mock-model",
                    baseURL: "https://example.com/v1"
                )
            }
        )
        await session.setOnASREvent { recorder.record($0) }
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )
        let vocabularyContext = fixture.context
        let pending = Task {
            await session.postProcessVoicePolishForTesting(
                rawText: raw, transcript: transcript,
                vocabularyContext: vocabularyContext, allowsUserChoice: true
            )
        }

        for _ in 0..<100 {
            if await client.requestCount() > 0,
               recorder.values.contains("voicePolishStage:analyzing") {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requestCount = await client.requestCount()
        XCTAssertEqual(requestCount, 1)
        try await Task.sleep(for: .milliseconds(1_350))
        XCTAssertFalse(recorder.values.contains { $0.hasPrefix("processing:") })
        await session.abortCurrentSession()
        let result = await boundedCompletion(pending, session: session) ?? nil

        XCTAssertNil(result)
        XCTAssertFalse(recorder.values.contains { $0.hasPrefix("processing:") })
        XCTAssertFalse(recorder.values.contains { $0.hasPrefix("finalized:") })
        XCTAssertTrue(recorder.values.contains("completed"))
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func testVoicePolishCommitsCompletedPipelineResult() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        let polished = "这是已经提交的润色结果。"
        let client = RecognitionSessionVoicePolishLLM(response: polished)
        let recorder = RecognitionEventRecorder()
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmClientFactory: { client },
            llmConfigLoader: {
                LLMConfig(
                    apiKey: "test",
                    model: "mock-model",
                    baseURL: "https://example.com/v1"
                )
            }
        )
        await session.setOnASREvent { recorder.record($0) }
        let raw = "这是已经提交的润色结杲。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let result = await session.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(result?.finalText, polished)
        XCTAssertTrue(recorder.values.contains("processing:\(polished)"))
    }

    func testVoicePolishFallbackUsesCanonicalTextInsteadOfRawTranscript() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try SnippetStorage.saveBuiltin([
            (trigger: "Type less", value: "Typeless"),
        ], context: fixture.context)
        let raw = "我正在使用 Type less。"
        let canonical = "我正在使用 Typeless。"
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"),
            llmConfigLoader: { nil }
        )
        let transcript = RecognitionTranscript(
            confirmedSegments: [raw],
            partialText: "",
            authoritativeText: raw,
            isFinal: true
        )

        let result = await session.postProcessVoicePolishForTesting(
            rawText: raw,
            transcript: transcript,
            vocabularyContext: fixture.context
        )

        XCTAssertEqual(result?.finalText, canonical)
        XCTAssertNil(result?.processedText)
        XCTAssertTrue(result?.llmFailed ?? false)
        XCTAssertEqual(result?.historyStatus, "voice_polish_fallback")
    }

    func testPolishFailureWaitsAndCancellationProducesNoText() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        let vocabularyContext = fixture.context
        let source = "周五上午先发内部试看，先让课程助教、讲师和运营同事一起核对页面、链接、字幕、下载资料与回放入口，确认所有内容都能正常打开以后再发邮件，邮件里不要承诺周五对外发布。"
        // 结构阶段返回空白正文，必须等待用户选择，不能静默交付原稿。
        let client = RecognitionSessionScriptedVoicePolishLLM(responses: [" \n"])
        let recorder = RecognitionEventRecorder()
        let historyStore = HistoryStore(path: ":memory:")
        let session = RecognitionSession(
            historyStore: historyStore,
            llmClientFactory: { client },
            llmConfigLoader: {
                LLMConfig(
                    apiKey: "test",
                    model: "mock-model",
                    baseURL: "https://example.com/v1"
                )
            }
        )
        await session.setOnASREvent { recorder.record($0) }
        let transcript = RecognitionTranscript(
            confirmedSegments: [source],
            partialText: "",
            authoritativeText: source,
            isFinal: true
        )

        let pendingTask = Task {
            await session.postProcessVoicePolishForTesting(
                rawText: source,
                transcript: transcript,
                vocabularyContext: vocabularyContext,
                allowsUserChoice: true
            )
        }
        let reachedReview = await AsyncTimeout.asyncValue(.seconds(10)) {
            await client.waitForRequestCount(1)
        }
        let unavailable = await AsyncTimeout.asyncValue(.seconds(10)) {
            while !recorder.values.contains("voicePolishUnavailable:validationFailed"),
                  !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
            }
            return recorder.values.contains("voicePolishUnavailable:validationFailed")
        }

        let requestCount = await client.requestCount()
        guard reachedReview.value == true, unavailable.value == true else {
            await session.abortCurrentSession()
            pendingTask.cancel()
            return XCTFail("未进入预期失败状态，events=\(recorder.values) requests=\(requestCount)")
        }
        XCTAssertFalse(reachedReview.timedOut, "requests=\(requestCount)")
        XCTAssertEqual(requestCount, 1)
        XCTAssertFalse(unavailable.timedOut, "events=\(recorder.values)")
        XCTAssertTrue(
            recorder.values.contains("voicePolishUnavailable:validationFailed"),
            "events=\(recorder.values) requests=\(requestCount)"
        )
        XCTAssertFalse(recorder.values.contains("processing:\(source)"))
        await session.abortCurrentSession()
        let result = await boundedCompletion(pendingTask, session: session) ?? nil

        XCTAssertNil(result)
        XCTAssertFalse(recorder.values.contains { $0.hasPrefix("processing:") })
        XCTAssertFalse(recorder.values.contains { $0.hasPrefix("finalized:") })
        XCTAssertTrue(recorder.values.contains("completed"))
        let state = await session.state
        XCTAssertEqual(state, .idle)
        // 取消不交付，但原转写必须留在历史里，不能整段丢失。
        let history = await historyStore.fetchAll()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.status, "voice_polish_cancelled")
        XCTAssertEqual(history.first?.rawText, source)
        XCTAssertFalse(history.first?.finalText.isEmpty ?? true)
        XCTAssertEqual(history.first?.characterCount, 0)
        XCTAssertEqual(history.first?.processingMode, L("润色", "Polish"))
    }

    func testVoicePolishExplicitRetryStartsFreshSingleRequestAndReturnsStructuredDraft() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        let vocabularyContext = fixture.context
        let source = "周五上午先发内部试看，先让课程助教、讲师和运营同事一起核对页面、链接、字幕、下载资料与回放入口，确认所有内容都能正常打开以后再发邮件，邮件里不要承诺周五对外发布。"
        let polished = "周五上午先发内部试看。先让课程助教、讲师和运营同事一起核对页面、链接、字幕、下载资料与回放入口，确认所有内容都能正常打开以后再发邮件。\n\n邮件里不要承诺周五对外发布。"
        let client = RecognitionSessionScriptedVoicePolishLLM(responses: [
            " \n", polished,
        ])
        let recorder = RecognitionEventRecorder()
        let historyStore = HistoryStore(path: ":memory:")
        let session = RecognitionSession(
            historyStore: historyStore,
            llmClientFactory: { client },
            llmConfigLoader: {
                LLMConfig(apiKey: "test", model: "mock-model", baseURL: "https://example.com/v1")
            }
        )
        await session.setOnASREvent { recorder.record($0) }
        let transcript = RecognitionTranscript(
            confirmedSegments: [source],
            partialText: "",
            authoritativeText: source,
            isFinal: true
        )

        let pendingTask = Task {
            await session.postProcessVoicePolishForTesting(
                rawText: source,
                transcript: transcript,
                vocabularyContext: vocabularyContext,
                allowsUserChoice: true
            )
        }
        let firstRun = await AsyncTimeout.asyncValue(.seconds(10)) {
            while !recorder.values.contains("voicePolishUnavailable:validationFailed"),
                  !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
            }
            return recorder.values.contains("voicePolishUnavailable:validationFailed")
        }

        guard firstRun.value == true else {
            await session.abortCurrentSession()
            pendingTask.cancel()
            return XCTFail("首轮没有进入用户选择状态，events=\(recorder.values)")
        }
        let firstRequestCount = await client.requestCount()
        XCTAssertEqual(firstRequestCount, 1)
        // 结构阶段失败后已经冻结标准档位，迟到的轻度快捷键不能改写本次重试。
        await session.switchMode(to: .lightPolish)
        XCTAssertFalse(recorder.values.contains("processing:\(source)"))
        let retryAccepted = await session.retryVoicePolishResult()
        XCTAssertTrue(retryAccepted)
        let secondRun = await AsyncTimeout.asyncValue(.seconds(10)) {
            await client.waitForRequestCount(2)
        }
        guard secondRun.value == true else {
            await session.abortCurrentSession()
            pendingTask.cancel()
            return XCTFail("重试未完成预期调用，events=\(recorder.values)")
        }
        let result = await boundedCompletion(pendingTask, session: session) ?? nil
        let requestCount = await client.requestCount()

        XCTAssertFalse(secondRun.timedOut)
        XCTAssertEqual(requestCount, 2)
        let requests = await client.recordedRequests()
        XCTAssertEqual(requests.map(\.task), [.voicePolishStructured, .voicePolishStructured])
        for request in requests {
            XCTAssertEqual(try Self.voicePolishPayload(from: request) as? [String: String],
                           ["canonical_text": source])
        }
        XCTAssertEqual(result?.finalText, polished)
        XCTAssertEqual(result?.processedText, polished)
        XCTAssertFalse(result?.llmFailed ?? true)
        XCTAssertEqual(result?.historyStatus, "voice_polish_success")
        XCTAssertTrue(recorder.values.contains("processing:\(polished)"))
        XCTAssertFalse(recorder.values.contains("processing:\(source)"))
        XCTAssertEqual(result?.performance?.firstAutomaticOutcome, .fallback)
        XCTAssertEqual(result?.performance?.outcome, .success)
        XCTAssertEqual(result?.performance?.userRetryCount, 1)
        XCTAssertEqual(result?.performance?.llmAttemptCount, 2)
        XCTAssertEqual(result?.performance?.repairAttemptCount, 0)
        let cancelledHistory = await historyStore.fetchAll().filter { $0.status == "voice_polish_cancelled" }
        XCTAssertTrue(cancelledHistory.isEmpty)
    }

    func testPolishPrefetchReusesActualPipelineWithoutSecondRequest() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        let raw = "明天下午开会"
        let client = RecognitionSessionScriptedVoicePolishLLM(responses: ["明天下午开会。"])
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"), llmClientFactory: { client },
            llmConfigLoader: { LLMConfig(apiKey: "test", model: "mock", baseURL: "https://example.com/v1") }
        )
        await session.prefetchPolishForTesting(text: raw, vocabularyContext: fixture.context)
        try await Task.sleep(for: .milliseconds(100))
        let before = await client.recordedRequests()
        XCTAssertEqual(before.count, 1)
        // 相同档位的停止快捷键可能再次调用 switchMode，不应撤销有效候选。
        await session.switchMode(to: .lightPolish)
        let transcript = RecognitionTranscript(confirmedSegments: [raw], partialText: "",
                                              authoritativeText: raw, isFinal: true)
        let output = await session.postProcessForTesting(rawText: raw, transcript: transcript,
            mode: .lightPolish, vocabularyContext: fixture.context)
        let after = await client.recordedRequests()
        XCTAssertEqual(after.count, 1, "命中候选不再发送第二次请求")
        XCTAssertEqual(after.first?.system, VoicePolishEditingPrompts.standard)
        XCTAssertEqual(output?.performance?.prefetchScheduledCount, 1)
        XCTAssertEqual(output?.performance?.reusedPrefetch, true)
        XCTAssertEqual(output?.performance?.llmAttemptCount, 0)
        XCTAssertEqual(output?.finalText, "明天下午开会。")
        await session.forceResetForTesting()
    }

    func testPolishPrefetchFinalCorrectionUsesFreshFullInput() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        let client = RecognitionSessionScriptedVoicePolishLLM(responses: ["周三开会。", "周四开会。"])
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"), llmClientFactory: { client },
            llmConfigLoader: { LLMConfig(apiKey: "test", model: "mock", baseURL: "https://example.com/v1") }
        )
        await session.prefetchPolishForTesting(text: "周三开会", vocabularyContext: fixture.context)
        try await Task.sleep(for: .milliseconds(100))
        let raw = "周三开会，不对，周四开会"
        let transcript = RecognitionTranscript(confirmedSegments: [raw], partialText: "",
                                              authoritativeText: raw, isFinal: true)
        let output = await session.postProcessForTesting(rawText: raw, transcript: transcript,
            mode: .lightPolish, vocabularyContext: fixture.context)
        let calls = await client.recordedRequests()
        XCTAssertEqual(calls.count, 2)
        let payload = try Self.voicePolishPayload(from: XCTUnwrap(calls.last))
        XCTAssertEqual(payload["canonical_text"] as? String, raw)
        XCTAssertEqual(output?.finalText, "周四开会。")
        await session.forceResetForTesting()
    }

    func testPrefetchAndDeliveryShareContextCorrectionsAndRejectChangedContext() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        VoicePolishSettings.setRecentInputContextEnabled(true, defaults: fixture.context.userDefaults)
        let app = "com.example.prefetch"
        let raw = "达尔这次更新先发测试组。"
        let corrected = "Dal这次更新先发测试组。"
        let context = WritingContext(applicationBundleID: app, scene: .chat,
                                     level: .metadataOnly, safety: .safe)
        for contextChanges in [false, true] {
            let recent = VoicePolishRecentInputContextStore()
            await recent.remember("Dal 的长语音测试刚刚结束。无关事项：客户预算九万元。", applicationBundleID: app)
            let client = RecognitionSessionScriptedVoicePolishLLM(responses: [corrected, raw])
            let session = RecognitionSession(
                historyStore: HistoryStore(path: ":memory:"), llmClientFactory: { client },
                llmConfigLoader: { LLMConfig(apiKey: "test", model: "mock", baseURL: "https://example.com/v1") },
                voicePolishRecentInputStore: recent
            )
            await session.prefetchPolishForTesting(text: raw, vocabularyContext: fixture.context,
                                                   writingContext: context)
            try await Task.sleep(for: .milliseconds(100))
            let finalContext = contextChanges
                ? WritingContext(applicationBundleID: app, scene: .chat, level: .metadataOnly, safety: .unknown)
                : context
            let result = await session.postProcessForTesting(
                rawText: raw,
                transcript: RecognitionTranscript(confirmedSegments: [raw], partialText: "", authoritativeText: raw, isFinal: true),
                mode: .formalWriting, writingContext: finalContext, vocabularyContext: fixture.context
            )
            let calls = await client.recordedRequests()
            XCTAssertEqual(calls.count, contextChanges ? 2 : 1)
            XCTAssertEqual(try Self.voicePolishPayload(from: XCTUnwrap(calls.first))["canonical_text"] as? String, corrected)
            XCTAssertEqual(try Self.voicePolishPayload(from: XCTUnwrap(calls.last))["canonical_text"] as? String,
                           contextChanges ? raw : corrected)
            XCTAssertEqual(result?.finalText, contextChanges ? raw : corrected)
            XCTAssertEqual(result?.performance?.reusedPrefetch, !contextChanges)
            await session.forceResetForTesting()
        }
    }

    func testLightSingleCallKeepsCompleteCanonicalInputAndVerbatimOutput() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        try SnippetStorage.save([(trigger: "Code X", value: "Codex")], context: fixture.context)
        let raw = "我在用 Code X。预算八百，不对，六百。\n第二段保持原位。"
        let canonical = "我在用 Codex。预算八百，不对，六百。\n第二段保持原位。"
        let response = "  我在用 Codex。预算六百。\r\n第二段保持原位。 e\u{301} 👩🏽‍💻\r\n"
        let client = RecognitionSessionScriptedVoicePolishLLM(responses: [response])
        let session = RecognitionSession(
            historyStore: HistoryStore(path: ":memory:"), llmClientFactory: { client },
            llmConfigLoader: { LLMConfig(apiKey: "test", model: "mock", baseURL: "https://example.com/v1") }
        )
        let transcript = RecognitionTranscript(confirmedSegments: [raw], partialText: "",
                                              authoritativeText: raw, isFinal: true)
        let result = await session.postProcessForTesting(
            rawText: raw, transcript: transcript, mode: .lightPolish,
            vocabularyContext: fixture.context
        )
        let calls = await client.recordedRequests()
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.task, .voicePolishStructured)
        let payload = try Self.voicePolishPayload(from: call)
        XCTAssertEqual(Set(payload.keys), ["canonical_text"])
        XCTAssertEqual(payload["canonical_text"] as? String, canonical)
        let output = try XCTUnwrap(result)
        XCTAssertEqual(Array(output.finalText.utf8), Array(response.utf8))
        XCTAssertEqual(Array(try XCTUnwrap(output.processedText).utf8), Array(response.utf8))
        XCTAssertFalse(output.llmFailed)
        XCTAssertEqual(output.historyStatus, "voice_polish_success")
        XCTAssertEqual(output.performance?.llmAttemptCount, 1)
        XCTAssertEqual(output.performance?.repairAttemptCount, 0)
    }

    func testLightRetryAndCancelKeepFirstFailureMetricsWithoutCountingRetryAsRepair() async throws {
        let fixture = try RecognitionSessionVocabularyFixture()
        defer { fixture.cleanup() }
        let source = "请先核对链接。"
        let transcript = RecognitionTranscript(confirmedSegments: [source], partialText: "",
                                              authoritativeText: source, isFinal: true)
        for shouldRetry in [true, false] {
            let client = RecognitionSessionScriptedVoicePolishLLM(responses: [" \n", "请先核对链接。"])
            let recorder = RecognitionEventRecorder()
            let session = RecognitionSession(
                historyStore: HistoryStore(path: ":memory:"), llmClientFactory: { client },
                llmConfigLoader: { LLMConfig(apiKey: "test", model: "mock", baseURL: "https://example.com/v1") }
            )
            await session.setOnASREvent { recorder.record($0) }
            let vocabulary = fixture.context
            let pending = Task {
                await session.postProcessForTesting(
                    rawText: source, transcript: transcript, mode: .lightPolish,
                    vocabularyContext: vocabulary, allowsVoicePolishUserChoice: true
                )
            }
            let waiting = await AsyncTimeout.asyncValue(.seconds(10)) {
                while !recorder.values.contains("voicePolishUnavailable:validationFailed"), !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(1))
                }
                return true
            }
            guard waiting.value == true else {
                await session.abortCurrentSession()
                pending.cancel()
                return XCTFail("没有进入用户选择状态，events=\(recorder.values)")
            }
            // 留出真实选择等待，核对 Session 确实记录并剔除这段时间。
            try await Task.sleep(for: .milliseconds(50))
            if shouldRetry {
                let accepted = await session.retryVoicePolishResult()
                XCTAssertTrue(accepted)
                let result = await boundedCompletion(pending, session: session) ?? nil
                let measurement = try XCTUnwrap(result?.performance)
                XCTAssertEqual(result?.processedText, source)
                XCTAssertEqual(measurement.firstAutomaticOutcome, .fallback)
                XCTAssertEqual(measurement.outcome, .success)
                XCTAssertEqual(measurement.userRetryCount, 1)
                XCTAssertEqual(measurement.llmAttemptCount, 2)
                XCTAssertEqual(measurement.repairAttemptCount, 0)
                XCTAssertGreaterThanOrEqual(measurement.decisionWaitMilliseconds, 40)
                XCTAssertNotNil(measurement.asrReadyLatencyMilliseconds)
            } else {
                await session.abortCurrentSession()
                let result = await boundedCompletion(pending, session: session) ?? nil
                XCTAssertNil(result)
                let sample = try XCTUnwrap(VoicePolishPerformanceStore.samples(defaults: vocabulary.userDefaults).last)
                XCTAssertEqual(sample.qualityMode, .standard)
                XCTAssertEqual(sample.firstAutomaticOutcome, .fallback)
                XCTAssertEqual(sample.resolvedOutcome, .cancelled)
                XCTAssertEqual(sample.userRetryCount, 0)
                XCTAssertEqual(sample.llmAttemptCount, 1)
                XCTAssertEqual(sample.repairAttemptCount, 0)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(sample.decisionWaitMilliseconds), 40)
                XCTAssertFalse(recorder.values.contains("processing:\(source)"))
            }
        }
    }

    /// 请求数到达不等于已交付；终态等待必须有界，失败时释放用户选择 continuation。
    private func boundedCompletion<Value: Sendable>(
        _ pending: Task<Value, Never>, session: RecognitionSession,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> Value? {
        let completion = await AsyncTimeout.asyncValue(.seconds(10)) { await pending.value }
        guard !completion.timedOut else {
            await session.abortCurrentSession()
            pending.cancel()
            XCTFail("会话未在10秒内结束，已取消本次测试会话", file: file, line: line)
            return nil
        }
        return completion.value
    }

    private static func voicePolishPayload(from request: LLMRequest) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(request.user.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - REPAIR_PLAN K2：注入取值守卫与时长合理性

    func testEffectiveTextPrefersAuthoritativeWhenComparable() {
        let transcript = RecognitionTranscript(
            confirmedSegments: ["今天先到这里，", "明天继续。"],
            partialText: "",
            authoritativeText: "今天先到这里，明天继续。",
            isFinal: true
        )

        XCTAssertEqual(
            RecognitionSession.effectiveTranscriptText(for: transcript),
            "今天先到这里，明天继续。"
        )
    }

    func testEffectiveTextFallsBackWhenAuthoritativeSuspiciouslyShort() {
        // 实锤形态：流式累积完整、asyncFinal 的 result.text 只承载开头一小段
        let composedPieces = ["OK，然后现在还是有问题，", "就是我现在有一个语音输入法嘛，", "然后我输入的文字少了很多"]
        let transcript = RecognitionTranscript(
            confirmedSegments: composedPieces,
            partialText: "",
            authoritativeText: "OK，然后",
            isFinal: true
        )

        XCTAssertEqual(
            RecognitionSession.effectiveTranscriptText(for: transcript),
            composedPieces.joined()
        )
    }

    func testEffectiveTextUsesComposedWhenAuthoritativeEmpty() {
        let transcript = RecognitionTranscript(
            confirmedSegments: ["第一段"],
            partialText: "第二段",
            authoritativeText: "",
            isFinal: false
        )

        XCTAssertEqual(
            RecognitionSession.effectiveTranscriptText(for: transcript),
            "第一段第二段"
        )
    }

    func testEffectiveTextUsesAuthoritativeWhenComposedEmpty() {
        let transcript = RecognitionTranscript(
            confirmedSegments: [],
            partialText: "",
            authoritativeText: "最终文本",
            isFinal: true
        )

        XCTAssertEqual(
            RecognitionSession.effectiveTranscriptText(for: transcript),
            "最终文本"
        )
    }

    func testImplausiblyShortRequiresLongRecording() {
        XCTAssertFalse(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 3, durationSeconds: 8.0
        ))
        XCTAssertTrue(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 4, durationSeconds: 10.0
        ))
        XCTAssertFalse(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 5, durationSeconds: 10.0
        ))
    }

    func testImplausiblyShortIgnoresEmptyText() {
        // 这个旧启发式只看时长/字数，0 字交给 K7 的 PCM 活动摘要另行判断。
        XCTAssertFalse(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 0, durationSeconds: 30.0
        ))
    }

    func testImplausiblyShortCatchesHistoricalLossCases() {
        // history.db 实锤：22.2s/5 字、53.6s/6 字、19.0s/3 字
        XCTAssertTrue(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 5, durationSeconds: 22.2
        ))
        XCTAssertTrue(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 6, durationSeconds: 53.6
        ))
        XCTAssertTrue(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 3, durationSeconds: 19.0
        ))
    }

    func testImplausiblyShortUsesVoicedDurationInsteadOfWallClockDuration() {
        // 2026-07-31 现场：57.2 秒录音中只有 269 个 20ms 有声帧（约 5.38 秒），
        // 27 字是完整的正常语速，不应因长停顿触发近一分钟全文重识别。
        let summary = PCMAudioActivitySummary(
            validByteCount: 1_812_980,
            analyzedFrameCount: 2_833,
            voicedFrameCount: 269,
            peakAmplitude: 20_196
        )

        XCTAssertEqual(summary.voicedDurationSeconds, 5.38, accuracy: 0.001)
        XCTAssertFalse(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 27,
            audioSummary: summary
        ))
    }

    func testImplausiblyShortStillCatchesLongVoicedAudioWithTooLittleText() {
        let summary = PCMAudioActivitySummary(
            validByteCount: 710_400,
            analyzedFrameCount: 1_110,
            voicedFrameCount: 1_110,
            peakAmplitude: 8_000
        )

        XCTAssertTrue(RecognitionSession.isTranscriptImplausiblyShort(
            textCount: 5,
            audioSummary: summary
        ))
    }

    func testPacedFallbackTimeoutCoversRealtimeReplayDuration() {
        // 60 秒 PCM + 15 秒服务端收尾余量
        XCTAssertEqual(
            RecognitionSession.batchFallbackTimeout(
                provider: .aliyun,
                audioByteCount: 60 * 16_000 * MemoryLayout<Int16>.size
            ),
            .seconds(75)
        )
        XCTAssertEqual(
            RecognitionSession.batchFallbackTimeout(
                provider: .volcano,
                audioByteCount: 60 * 16_000 * MemoryLayout<Int16>.size
            ),
            .seconds(75)
        )
    }

    private func makeSession() -> RecognitionSession {
        RecognitionSession(historyStore: HistoryStore(path: ":memory:"))
    }
}

private final class RecognitionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func record(_ event: RecognitionEvent) {
        lock.withLock {
            storage.append(Self.describe(event))
        }
    }

    private static func describe(_ event: RecognitionEvent) -> String {
        switch event {
        case .ready:
            return "ready"
        case .transcript(let transcript):
            return "transcript:\(transcript.displayText)"
        case .error(let error):
            return "error:\(error.localizedDescription)"
        case .completed:
            return "completed"
        case .processingResult(let text):
            return "processing:\(text)"
        case .voicePolishStage(let stage):
            return "voicePolishStage:\(stage.rawValue)"
        case .voicePolishUnavailable(let reason):
            return "voicePolishUnavailable:\(reason?.rawValue ?? "unknown")"
        case .finalized(let text, let injection):
            return "finalized:\(text):\(injection)"
        case .streamingInterrupted:
            return "streamingInterrupted"
        }
    }
}

private actor RecognitionSessionApplicationCaptureGate {
    private var continuation: CheckedContinuation<String?, Never>?
    private(set) var hasStarted = false

    func capture() async -> String? {
        hasStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ bundleIdentifier: String?) {
        continuation?.resume(returning: bundleIdentifier)
        continuation = nil
    }
}

private actor RecognitionSessionBlockingVoicePolishLLM: LLMClient {
    private var requests: [LLMRequest] = []

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        try await Task.sleep(for: .seconds(30))
        return LLMResponse(text: "不应等待到这里", model: config.model)
    }

    func process(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig
    ) async throws -> String {
        XCTFail("Voice Polish 不应回到兼容 process 接口")
        return text
    }

    func warmUp(baseURL: String) async {}

    func requestCount() -> Int { requests.count }
}

private actor RecognitionSessionVoicePolishLLM: LLMClient {
    private let response: String
    private var requests: [LLMRequest] = []
    private var models: [String] = []

    init(response: String) {
        self.response = response
    }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        models.append(config.model)
        return LLMResponse(text: response, model: config.model)
    }

    func process(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig
    ) async throws -> String {
        XCTFail("Voice Polish 不应回到兼容 process 接口")
        return response
    }

    func warmUp(baseURL: String) async {}

    func requestCount() -> Int { requests.count }
    func recordedRequests() -> [LLMRequest] { requests }
    func recordedModels() -> [String] { models }

    private static func split(_ text: String, count: Int) -> [String] {
        guard count > 1 else { return [text] }
        let characters = Array(text)
        guard characters.count >= count else { return Array(repeating: text, count: count) }
        return (0..<count).map { index in
            let lower = characters.count * index / count
            let upper = characters.count * (index + 1) / count
            return String(characters[lower..<upper])
        }
    }
}

private actor RecognitionSessionScriptedVoicePolishLLM: LLMClient {
    private var responses: [String]
    private var requests: [LLMRequest] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return LLMResponse(text: responses.removeFirst(), model: config.model)
    }

    func process(
        text: String,
        prompt: String,
        context: LLMRequestContext,
        config: LLMConfig
    ) async throws -> String {
        XCTFail("Voice Polish 不应回到兼容 process 接口")
        return text
    }

    func warmUp(baseURL: String) async {}

    func requestCount() -> Int { requests.count }
    func recordedRequests() -> [LLMRequest] { requests }

    func waitForRequestCount(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while requests.count < count, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return requests.count >= count
    }
}

private final class RecognitionSessionVocabularyFixture {
    let directory: URL
    let suiteName: String
    let context: VocabularyStorageContext

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DalRecognitionSessionVocabularyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "DalRecognitionSessionVocabularyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        context = VocabularyStorageContext(
            supportDirectory: directory,
            userDefaults: defaults,
            fileManager: .default,
            hotwordsDidChange: {},
            revealFile: { _ in }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
