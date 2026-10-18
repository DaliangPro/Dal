import XCTest
@testable import Muse

final class VoicePolishLearningTests: XCTestCase {
    func testChineseSingleCharacterCorrectionsRecoverShortWords() {
        let examples = [
            ("明天联系苏林开会", "明天联系苏霖开会", "苏林", "苏霖"),
            ("今天去食奇家吃饭", "今天去食其家吃饭", "食奇家", "食其家"),
            ("我在食奇家", "我在食其家", "食奇家", "食其家"),
            ("苏林", "苏霖", "苏林", "苏霖"),
            ("这片森霖很漂亮", "这片森林很漂亮", "森霖", "森林")
        ]
        for (original, corrected, alias, canonical) in examples {
            XCTAssertEqual(TerminologyCorrectionExtractor.automaticASRCandidates(
                generatedText: original, correctedText: corrected, recognitionText: original
            ), [TerminologyCorrectionCandidate(alias: alias, canonical: canonical)], original)
        }
    }

    func testChineseExpansionStillRejectsMissingSourceAmbiguousBoundariesAndSemanticChanges() {
        for (original, corrected, source) in [
            ("联系苏林", "联系苏霖", "联系其他人"),
            ("林", "霖", "林"),
            ("林，家", "霖，家", "林，家"),
            ("联系苏林", "联系苏雪", "联系苏林"),
            ("今天吃米饭", "今天吃晚饭", "今天吃米饭"),
            ("食奇家", "食奇家继续输入", "食奇家")
        ] {
            XCTAssertTrue(TerminologyCorrectionExtractor.automaticASRCandidates(
                generatedText: original, correctedText: corrected, recognitionText: source
            ).isEmpty, original)
        }
    }

    @MainActor
    func testUndoReceiptOnlyRemovesItsEvidenceAndIsOneShot() async throws {
        let fixture = try AutomaticTerminologyLearningFixture(builtIn: ["Claude"])
        defer { fixture.cleanup() }
        var manual = TerminologyRepository.load(context: fixture.context)
        manual.entries.append(TerminologyEntry(
            canonicalText: "手工术语", aliases: [TerminologyAlias(text: "人工错法", source: .manual)], origin: .manual
        ))
        try TerminologyRepository.save(manual, context: fixture.context)
        for id in ["first", "second"] { await fixture.insertDirectHistory(id: id, text: "cloud") }
        let first = await fixture.monitor.recordCorrectionReceipt(
            originalText: "cloud", correctedText: "Claude", historyID: "first", historyStore: fixture.historyStore
        )
        let second = await fixture.monitor.recordCorrectionReceipt(
            originalText: "cloud", correctedText: "Claude", historyID: "second", historyStore: fixture.historyStore
        )
        let undo = try XCTUnwrap(first?.undo)
        await undo.perform()
        await undo.perform()
        XCTAssertTrue(undo.didUndo)
        XCTAssertFalse(undo.canUndo)
        let entries = TerminologyRepository.load(context: fixture.context).entries
        XCTAssertTrue(entries.contains { $0.origin == .builtIn && $0.canonicalText == "Claude" })
        let alias = try XCTUnwrap(entries.flatMap(\.aliases).first { $0.text == "cloud" })
        XCTAssertEqual(alias.sourceRecordIDs, ["second"])
        XCTAssertEqual(TerminologyRepository.projections(context: fixture.context).corrections["cloud"], "Claude")
        let remaining = try await fixture.historyStore.fetchVoicePolishCorrections()
        XCTAssertEqual(remaining.map(\.historyID), ["second"])
        await second?.undo?.perform()
        XCTAssertNil(TerminologyRepository.projections(context: fixture.context).corrections["cloud"])
        let histories = await fixture.historyStore.fetchAll()
        XCTAssertEqual(histories.count, 2, "撤销学习不能删除原录音记录")
        XCTAssertEqual(TerminologyRepository.projections(context: fixture.context).corrections["人工错法"], "手工术语")
    }

    @MainActor
    func testStaleUndoReceiptCannotRemoveUpdatedCorrection() async throws {
        let fixture = try AutomaticTerminologyLearningFixture()
        defer { fixture.cleanup() }
        await fixture.insertDirectHistory(id: "updated", text: "cloud")
        let first = await fixture.monitor.recordCorrectionReceipt(
            originalText: "cloud", correctedText: "Claude", historyID: "updated", historyStore: fixture.historyStore
        )
        let second = await fixture.monitor.recordCorrectionReceipt(
            originalText: "cloud", correctedText: "Claude", historyID: "updated", historyStore: fixture.historyStore
        )
        let undo = try XCTUnwrap(first?.undo)
        await undo.perform()
        XCTAssertFalse(undo.didUndo)
        XCTAssertTrue(undo.didFail)
        XCTAssertEqual(TerminologyRepository.projections(context: fixture.context).corrections["cloud"], "Claude")
        let remaining = try await fixture.historyStore.fetchVoicePolishCorrections()
        XCTAssertEqual(remaining.count, 1)
        await second?.undo?.perform()
        XCTAssertEqual(second?.undo?.didUndo, true)
    }

    func testChineseCorrectionIsAppliedOnNextDirectOutput() async throws {
        let fixture = try AutomaticTerminologyLearningFixture()
        defer { fixture.cleanup() }
        let original = "今天去食奇家吃饭"
        await fixture.insertDirectHistory(id: "chinese-brand", text: original)
        let feedback = await fixture.monitor.recordCorrectionFeedback(
            originalText: original, correctedText: "今天去食其家吃饭", historyID: "chinese-brand",
            historyStore: fixture.historyStore
        )
        XCTAssertEqual(feedback?.didPersist, true)
        let prepared = VoicePolishTerminologyRuntime.prepare(rawText: original, applicationBundleIdentifier: nil, context: fixture.context)
        XCTAssertEqual(prepared.canonicalText, "今天去食其家吃饭")
        XCTAssertNil(TerminologyRepository.projections(context: fixture.context).corrections["奇"], "不能生成全局单字替换")
    }

    func testCloudCorrectionAddsUserAliasWithoutChangingBuiltInClaude() async throws {
        let fixture = try AutomaticTerminologyLearningFixture(builtIn: ["Claude"])
        defer { fixture.cleanup() }
        let builtIn = try XCTUnwrap(TerminologyRepository.load(context: fixture.context).entries.first {
            $0.origin == .builtIn && $0.canonicalText == "Claude"
        })
        await fixture.insertDirectHistory(id: "gpt-cloud", text: "cloud.")
        let feedback = await fixture.monitor.recordCorrectionFeedback(
            originalText: "cloud.", correctedText: "Claude", historyID: "gpt-cloud",
            historyStore: fixture.historyStore
        )
        guard case .learned(let candidates, let hasConflict) = feedback else {
            return XCTFail("应成功学习用户提供的 cloud. → Claude 例子")
        }
        XCTAssertEqual(candidates, [TerminologyCorrectionCandidate(alias: "cloud", canonical: "Claude")])
        XCTAssertFalse(hasConflict)
        XCTAssertTrue(try XCTUnwrap(feedback).message.contains("Claude"))
        let document = TerminologyRepository.load(context: fixture.context)
        XCTAssertEqual(document.entries.first { $0.id == builtIn.id }, builtIn)
        let personal = try XCTUnwrap(document.entries.first { $0.origin == .confirmedCorrection })
        XCTAssertEqual(personal.canonicalText, "Claude")
        XCTAssertEqual(personal.aliases.first?.sourceRecordIDs, ["gpt-cloud"])
        XCTAssertTrue(document.conflicts.isEmpty)
        let session = RecognitionSession(historyStore: fixture.historyStore)
        let result = await session.postProcessForTesting(
            rawText: "cloud.",
            transcript: RecognitionTranscript(
                confirmedSegments: ["cloud."], partialText: "", authoritativeText: "cloud.", isFinal: true
            ), mode: .direct, vocabularyContext: fixture.context
        )
        XCTAssertEqual(result?.finalText, "Claude.", "后续直出纠词，标点沿用原文")
        let coordinator = TerminologyHistoryTransactionCoordinator(context: fixture.context)
        try await coordinator.undoCorrection(historyStore: fixture.historyStore, historyID: "gpt-cloud")
        let afterUndo = TerminologyRepository.load(context: fixture.context)
        XCTAssertEqual(afterUndo.entries.first { $0.id == builtIn.id }, builtIn)
        XCTAssertFalse(afterUndo.entries.contains { $0.origin == .confirmedCorrection })
        XCTAssertNil(TerminologyRepository.projections(context: fixture.context).corrections["cloud"])
    }

    func testUnextractableEditCanBeFollowedBySuccessfulWordLearning() async throws {
        let fixture = try AutomaticTerminologyLearningFixture()
        defer { fixture.cleanup() }
        await fixture.insertDirectHistory(id: "intermediate-edit", text: "cloud.")
        let intermediate = await fixture.monitor.recordCorrectionFeedback(
            originalText: "cloud.", correctedText: "cloud!", historyID: "intermediate-edit",
            historyStore: fixture.historyStore
        )
        XCTAssertEqual(intermediate, .noTerms)
        let before = try await fixture.historyStore.fetchVoicePolishCorrections()
        XCTAssertTrue(before.isEmpty)
        let final = await fixture.monitor.recordCorrectionFeedback(
            originalText: "cloud.", correctedText: "Claude", historyID: "intermediate-edit",
            historyStore: fixture.historyStore
        )
        XCTAssertEqual(final?.didPersist, true)
        XCTAssertEqual(TerminologyRepository.projections(context: fixture.context).corrections["cloud"], "Claude")
    }

    func testLearningSaveFailureReportsFailureWithoutCreatingHistoryEvidence() async throws {
        let fixture = try AutomaticTerminologyLearningFixture()
        defer { fixture.cleanup() }
        await fixture.insertDirectHistory(id: "cannot-save", text: "cloud.")
        try Data("{".utf8).write(to: TerminologyRepository.fileURL(in: fixture.context))
        let feedback = await fixture.monitor.recordCorrectionFeedback(
            originalText: "cloud.", correctedText: "Claude", historyID: "cannot-save",
            historyStore: fixture.historyStore
        )
        XCTAssertEqual(feedback, .failed)
        XCTAssertEqual(feedback?.didPersist, false)
        let corrections = try await fixture.historyStore.fetchVoicePolishCorrections()
        XCTAssertTrue(corrections.isEmpty)
    }

    func testCapturePolicyUsesFieldCapabilitiesWithoutApplicationOrWebWhitelist() {
        for role in ["AXTextArea", "AXTextField"] {
            for editable in [true, nil] as [Bool?] {
                XCTAssertTrue(PostInjectionEditLearningMonitor.supportsCapture(
                    role: role, subrole: nil, editable: editable, protectedContent: nil
                ), "同一套能力策略适用于原生、网页和未知来源 APP，不需要应用标识")
            }
        }
        XCTAssertTrue(PostInjectionEditLearningMonitor.supportsCapture(
            role: "AXComboBox", subrole: nil, editable: true, protectedContent: false
        ), "可编辑组合框仍需通过后续本次插入范围校验")
        XCTAssertTrue(PostInjectionEditLearningMonitor.supportsCapture(
            role: "AXWebArea", subrole: nil, editable: true, protectedContent: false
        ), "网页输入框可用 AXEditable 明确声明能力时应进入范围捕获")
        XCTAssertTrue(PostInjectionEditLearningMonitor.supportsCapture(
            role: "AXButton", subrole: "AXSearchField", editable: nil, protectedContent: false
        ), "搜索框的角色异常时仍可由 SearchField 子角色确认能力")
    }

    func testCaptureRejectionDistinguishesProtectedReadOnlyUnsupportedAndReadErrors() {
        XCTAssertEqual(PostInjectionEditLearningMonitor.rejectionReason(
            role: "AXTextField", subrole: "AXSecureTextField", editable: true, protectedContent: nil
        ), .protectedField)
        XCTAssertEqual(PostInjectionEditLearningMonitor.rejectionReason(
            role: "AXTextArea", subrole: nil, editable: true, protectedContent: true
        ), .protectedField)
        XCTAssertEqual(PostInjectionEditLearningMonitor.rejectionReason(
            role: "AXTextArea", subrole: nil, editable: false, protectedContent: nil
        ), .readOnlyField)
        for role in ["AXButton", "AXWebArea", "AXStaticText", "AXGroup", "AXComboBox", nil] as [String?] {
            XCTAssertEqual(PostInjectionEditLearningMonitor.rejectionReason(
                role: role, subrole: nil, editable: nil, protectedContent: nil
            ), .unsupportedField)
        }
        XCTAssertEqual(PostInjectionEditLearningMonitor.rejectionReason(
            role: "AXTextArea", subrole: nil, editable: nil, protectedContent: nil, metadataReadable: false
        ), .fieldUnresponsive, "可选属性不支持与 IPC 读取失败必须区分，后者拒绝读取正文")
        for feedback in [AutomaticLearningFeedback.protectedField, .readOnlyField, .unsupportedField,
                         .fieldUnresponsive, .rangeUnavailable] {
            XCTAssertFalse(feedback.didPersist)
            XCTAssertFalse(feedback.message.isEmpty)
        }
    }

    func testSystemFocusWinsAndApplicationFallbackOnlyRunsWhenSystemFocusIsAbsent() {
        var applicationQueries = 0
        let panel = PostInjectionEditLearningMonitor.resolveFocusedElement(
            system: { "浮动面板输入框" },
            application: { applicationQueries += 1; return "前台应用里的其他输入框" }
        )
        XCTAssertEqual(panel, "浮动面板输入框")
        XCTAssertEqual(applicationQueries, 0, "系统有键盘焦点时不能改读前台应用")

        let fallback = PostInjectionEditLearningMonitor.resolveFocusedElement(
            system: { nil as String? },
            application: { applicationQueries += 1; return "当前应用的焦点输入框" }
        )
        XCTAssertEqual(fallback, "当前应用的焦点输入框")
        XCTAssertEqual(applicationQueries, 1)
        let absent = PostInjectionEditLearningMonitor.resolveFocusedElement(
            system: { nil as String? }, application: { nil }
        )
        XCTAssertNil(absent)
    }

    func testAutomaticLearningOnlyObservesEnabledModesAfterSuccessfulInsertion() throws {
        let fixture = try AutomaticTerminologyLearningFixture()
        defer { fixture.cleanup() }
        let defaults = fixture.context.userDefaults
        VoicePolishSettings.setTerminologyLearningEnabled(false, defaults: defaults)
        VoicePolishSettings.setPersonalizationEnabled(true, defaults: defaults)
        XCTAssertFalse(PostInjectionEditLearningMonitor.shouldObserve(
            kind: .direct, injection: .inserted, defaults: defaults
        ))
        XCTAssertFalse(PostInjectionEditLearningMonitor.shouldObserve(
            kind: .voicePolish, injection: .inserted, defaults: defaults
        ), "个人表达学习不应由自动记词开关隐式启动")

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

    func testAutomaticCandidatesOnlyKeepLikelyASRErrorsFromRecognitionText() {
        XCTAssertEqual(
            TerminologyCorrectionExtractor.automaticASRCandidates(
                generatedText: "我使用 cloud。", correctedText: "我使用 Claude。", recognitionText: "我使用 cloud。"
            ),
            [TerminologyCorrectionCandidate(alias: "cloud", canonical: "Claude")]
        )
        XCTAssertTrue(TerminologyCorrectionExtractor.automaticASRCandidates(
            generatedText: "我想吃苹果。", correctedText: "我想去散步。", recognitionText: "我想吃苹果。"
        ).isEmpty, "正常语义换词不能被自动记为 ASR 错词")
        XCTAssertTrue(TerminologyCorrectionExtractor.automaticASRCandidates(
            generatedText: "今天开会讨论。", correctedText: "今天开会讨论。", recognitionText: "今天开会讨论。"
        ).isEmpty)
    }

    func testAutomaticVoicePolishSemanticEditDoesNotLearnStyleOrTerminology() async throws {
        let fixture = try AutomaticTerminologyLearningFixture()
        defer { fixture.cleanup() }
        await fixture.historyStore.insert(HistoryRecord(
            id: "voice-polish-semantic", createdAt: Date(), durationSeconds: 2,
            rawText: "我想吃苹果。", processingMode: "语音润色",
            processedText: "我想吃苹果。", finalText: "我想吃苹果。",
            status: "voice_polish_success", characterCount: 6
        ))

        let feedback = await fixture.monitor.recordCorrectionFeedback(
            originalText: "我想吃苹果。", correctedText: "我想去散步。",
            historyID: "voice-polish-semantic", historyStore: fixture.historyStore
        )
        XCTAssertEqual(feedback, .noTerms)
        let corrections = try await fixture.historyStore.fetchVoicePolishCorrections()
        XCTAssertTrue(corrections.isEmpty)
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
        XCTAssertFalse(corrections[0].learnStyle)
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

    init(builtIn: [String] = []) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseDirectLearningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "MuseDirectLearningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        context = VocabularyStorageContext(
            supportDirectory: directory, userDefaults: defaults, fileManager: .default,
            hotwordsDidChange: {}, revealFile: { _ in }
        )
        try HotwordStorage.saveBuiltin(builtIn, context: context)
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
