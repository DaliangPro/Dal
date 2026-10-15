import XCTest
@testable import Muse

final class VoicePolishLearningTests: XCTestCase {
    func testAutomaticLearningOnlyObservesEnabledModesAfterSuccessfulInsertion() throws {
        let fixture = try AutomaticTerminologyLearningFixture()
        defer { fixture.cleanup() }
        let defaults = fixture.context.userDefaults
        VoicePolishSettings.setTerminologyLearningEnabled(false, defaults: defaults)
        VoicePolishSettings.setPersonalizationEnabled(true, defaults: defaults)
        XCTAssertFalse(PostInjectionEditLearningMonitor.shouldObserve(
            kind: .direct, injection: .inserted, defaults: defaults
        ))
        XCTAssertTrue(PostInjectionEditLearningMonitor.shouldObserve(
            kind: .voicePolish, injection: .inserted, defaults: defaults
        ))

        VoicePolishSettings.setTerminologyLearningEnabled(true, defaults: defaults)
        for kind in [ProcessingKind.direct, .voicePolish] {
            XCTAssertTrue(PostInjectionEditLearningMonitor.shouldObserve(
                kind: kind, injection: .inserted, defaults: defaults
            ))
            for outcome in [InjectionOutcome.copiedToClipboard, .copiedToClipboardPermissionMissing,
                            .noFocusedInput(copiedToClipboard: true), .noFocusedInput(copiedToClipboard: false)] {
                XCTAssertFalse(PostInjectionEditLearningMonitor.shouldObserve(
                    kind: kind, injection: outcome, defaults: defaults
                ))
            }
        }
        for kind in [ProcessingKind.smartDirect, .translate, .promptOptimize, .command, .custom] {
            XCTAssertFalse(PostInjectionEditLearningMonitor.shouldObserve(
                kind: kind, injection: .inserted, defaults: defaults
            ))
        }
    }

    func testDirectCorrectionLearnsTerminologyForNextDirectWithoutLearningStyle() async throws {
        let fixture = try AutomaticTerminologyLearningFixture()
        defer { fixture.cleanup() }
        let original = "我正在用 Type less 写这段话"
        let corrected = "我正在用 Typeless 写这段话"
        for status in ["completed", "stream_recovered"] {
            let historyID = "direct-\(status)"
            await fixture.insertDirectHistory(id: historyID, text: original, status: status)
            let didRecord = await fixture.monitor.recordCorrection(
                originalText: original, correctedText: corrected,
                historyID: historyID, historyStore: fixture.historyStore
            )
            XCTAssertTrue(didRecord, status)
        }

        let corrections = try await fixture.historyStore.fetchVoicePolishCorrections()
        XCTAssertEqual(corrections.count, 2)
        XCTAssertTrue(corrections.allSatisfy { !$0.learnStyle && $0.learnTerminology })
        XCTAssertTrue(corrections.allSatisfy { $0.correctedText == corrected })
        let histories = await fixture.historyStore.fetchAll()
        XCTAssertTrue(histories.allSatisfy { $0.rawText == original && $0.finalText == original })

        let session = RecognitionSession(historyStore: fixture.historyStore)
        let result = await session.postProcessForTesting(
            rawText: original,
            transcript: RecognitionTranscript(
                confirmedSegments: [original], partialText: "", authoritativeText: original, isFinal: true
            ),
            mode: .direct,
            vocabularyContext: fixture.context
        )
        XCTAssertEqual(result?.finalText, corrected)
        XCTAssertNil(result?.processedText, "直出沿用本地词库，不调用润色")
    }

    func testDirectCorrectionDoesNotLearnWhenTerminologySwitchIsOff() async throws {
        let fixture = try AutomaticTerminologyLearningFixture()
        defer { fixture.cleanup() }
        VoicePolishSettings.setTerminologyLearningEnabled(false, defaults: fixture.context.userDefaults)
        await fixture.insertDirectHistory(id: "direct-disabled", text: "我使用 Type less。")
        let didRecord = await fixture.monitor.recordCorrection(
            originalText: "我使用 Type less。", correctedText: "我使用 Typeless。",
            historyID: "direct-disabled", historyStore: fixture.historyStore
        )
        XCTAssertFalse(didRecord)
        let corrections = try await fixture.historyStore.fetchVoicePolishCorrections()
        XCTAssertTrue(corrections.isEmpty)
        XCTAssertTrue(TerminologyRepository.projections(context: fixture.context).corrections.isEmpty)
    }

    func testDirectPureAppendDoesNotCreateTerminologyOrStyleSamples() async throws {
        let fixture = try AutomaticTerminologyLearningFixture()
        defer { fixture.cleanup() }
        await fixture.insertDirectHistory(id: "direct-append", text: "这段文字已经完成。")
        let didRecord = await fixture.monitor.recordCorrection(
            originalText: "这段文字已经完成。", correctedText: "这段文字已经完成。我继续输入新的内容。",
            historyID: "direct-append", historyStore: fixture.historyStore
        )
        XCTAssertFalse(didRecord)
        let corrections = try await fixture.historyStore.fetchVoicePolishCorrections()
        XCTAssertTrue(corrections.isEmpty)
        XCTAssertTrue(TerminologyRepository.projections(context: fixture.context).corrections.isEmpty)
    }

    func testPostInjectionLearningExtractsInternalCorrection() {
        let candidate = PostInjectionEditLearningMonitor.extractCandidate(
            original: "我正在用 Type less 写这段话",
            prefix: "前文：",
            suffix: "；后文",
            windowText: "前文：我正在用 Typeless 写这段话；后文",
            caretOffset: nil
        )

        XCTAssertEqual(candidate, "我正在用 Typeless 写这段话")
        XCTAssertEqual(
            TerminologyCorrectionExtractor.candidates(
                generatedText: "我正在用 Type less 写这段话",
                correctedText: candidate ?? ""
            ),
            [TerminologyCorrectionCandidate(alias: "Type less", canonical: "Typeless")]
        )
    }

    func testPostInjectionLearningIgnoresPureAppendedContent() {
        let candidate = PostInjectionEditLearningMonitor.extractCandidate(
            original: "这段文字已经完成。",
            prefix: "",
            suffix: "",
            windowText: "这段文字已经完成。我继续输入新的内容。",
            caretOffset: ("这段文字已经完成。我继续输入新的内容。" as NSString).length
        )

        XCTAssertNil(candidate)
    }

    func testPostInjectionLearningKeepsWholeCorrectedTextAtFieldEnd() {
        let corrected = "餐饮品牌是食其家。"
        let candidate = PostInjectionEditLearningMonitor.extractCandidate(
            original: "餐饮品牌是食奇家。",
            prefix: "已有内容 ",
            suffix: "",
            windowText: "已有内容 \(corrected)",
            // 模拟用户改完中间词后，真实光标仍停在“食其家”后；生产读取会用
            // 窗口末尾作为本次成稿边界，避免误删最后的句号。
            caretOffset: ("已有内容 \(corrected)" as NSString).length
        )

        XCTAssertEqual(candidate, corrected)
    }

    func testPostInjectionCorrectionPersistsHistoryAndTerminologyAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseAutoLearningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "MuseAutoLearningTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let context = VocabularyStorageContext(
            supportDirectory: directory,
            userDefaults: defaults,
            fileManager: .default,
            hotwordsDidChange: {},
            revealFile: { _ in }
        )
        try HotwordStorage.saveBuiltin([], context: context)
        try SnippetStorage.saveBuiltin([], context: context)
        _ = try TerminologyRepository.migrateIfNeeded(context: context)
        VoicePolishSettings.setPersonalizationEnabled(true, defaults: defaults)
        VoicePolishSettings.setTerminologyLearningEnabled(true, defaults: defaults)

        let historyStore = HistoryStore(
            path: directory.appendingPathComponent("history.db").path
        )
        await historyStore.insert(HistoryRecord(
            id: "history-auto-learning",
            createdAt: Date(),
            durationSeconds: 2,
            rawText: "我正在用 Type less 写这段话",
            processingMode: "语音润色",
            processedText: "我正在用 Type less 写这段话",
            finalText: "我正在用 Type less 写这段话",
            status: "voice_polish_success",
            characterCount: 20
        ))
        let monitor = PostInjectionEditLearningMonitor(
            coordinator: TerminologyHistoryTransactionCoordinator(context: context),
            settingsContext: context
        )

        let didRecord = await monitor.recordCorrection(
            originalText: "我正在用 Type less 写这段话",
            correctedText: "我正在用 Typeless 写这段话",
            historyID: "history-auto-learning",
            historyStore: historyStore
        )

        XCTAssertTrue(didRecord)
        let corrections = try await historyStore.fetchVoicePolishCorrections()
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections[0].correctedText, "我正在用 Typeless 写这段话")
        XCTAssertTrue(corrections[0].learnStyle)
        XCTAssertTrue(corrections[0].learnTerminology)
        let terminology = TerminologyRepository.load(context: context)
        XCTAssertTrue(terminology.entries.contains { entry in
            entry.canonicalText == "Typeless"
                && entry.aliases.contains { $0.text == "Type less" }
        })
    }

    private func makeRecords(
        count: Int,
        scene: WritingScene,
        corrected: String
    ) -> [VoicePolishCorrectionRecord] {
        (0..<count).map { index in
            correction(
                id: "\(scene.rawValue)-\(index)",
                date: Date(timeIntervalSince1970: Double(index)),
                scene: scene,
                generated: "确认",
                corrected: corrected
            )
        }
    }

    private func correction(
        id: String,
        date: Date,
        scene: WritingScene,
        generated: String,
        corrected: String,
        learnStyle: Bool = true,
        learnTerminology: Bool = true
    ) -> VoicePolishCorrectionRecord {
        VoicePolishCorrectionRecord(
            id: id,
            historyID: "history-\(id)",
            createdAt: date,
            scene: scene,
            sourceText: "原始口述",
            generatedText: generated,
            correctedText: corrected,
            learnStyle: learnStyle,
            learnTerminology: learnTerminology
        )
    }

    private func makeRequest(styleProfile: StyleProfile?) -> VoicePolishRequest {
        let segment = RecognitionSegment(
            id: "s1",
            text: "请确认。",
            startTimeMs: nil,
            endTimeMs: nil,
            confidence: nil,
            isFinal: true
        )
        return VoicePolishRequest(
            input: VoiceInputEnvelope(
                providerFinalText: segment.text,
                segments: [segment],
                durationMs: 1_000,
                provider: .volcano
            ),
            context: WritingContext(),
            preferences: UserPolishPreferences(
                additionalRequirements: "",
                styleProfile: styleProfile
            ),
            qualityMode: .balanced
        )
    }
}

private struct AutomaticTerminologyLearningFixture {
    let directory: URL
    let suiteName: String
    let context: VocabularyStorageContext
    let historyStore: HistoryStore
    let monitor: PostInjectionEditLearningMonitor

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseDirectLearningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "MuseDirectLearningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        context = VocabularyStorageContext(
            supportDirectory: directory, userDefaults: defaults, fileManager: .default,
            hotwordsDidChange: {}, revealFile: { _ in }
        )
        try HotwordStorage.saveBuiltin([], context: context)
        try SnippetStorage.saveBuiltin([], context: context)
        _ = try TerminologyRepository.migrateIfNeeded(context: context)
        VoicePolishSettings.setPersonalizationEnabled(true, defaults: defaults)
        VoicePolishSettings.setTerminologyLearningEnabled(true, defaults: defaults)
        historyStore = HistoryStore(path: directory.appendingPathComponent("history.db").path)
        monitor = PostInjectionEditLearningMonitor(
            coordinator: TerminologyHistoryTransactionCoordinator(context: context), settingsContext: context
        )
    }

    func insertDirectHistory(id: String, text: String, status: String = "completed") async {
        await historyStore.insert(HistoryRecord(
            id: id, createdAt: Date(), durationSeconds: 2,
            rawText: text, processingMode: "直出", processedText: nil,
            finalText: text, status: status, characterCount: text.count
        ))
    }

    func cleanup() {
        context.userDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.trashItem(at: directory, resultingItemURL: nil)
    }
}
