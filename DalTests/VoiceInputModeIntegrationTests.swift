import XCTest
@testable import Dal

final class VoiceInputModeIntegrationTests: XCTestCase {
    func testTwoSystemModesHaveStableDistinctSemanticsAndPreserveExistingShortcuts() {
        let modes = ProcessingMode.builtins
        XCTAssertEqual(modes.map(\.id), [
            ProcessingMode.directId, ProcessingMode.formalWriting.id,
        ])
        XCTAssertTrue(modes.allSatisfy(\.isProtectedSystemMode))
        XCTAssertTrue(modes.allSatisfy { !$0.isUserDeletable })
        XCTAssertFalse(ProcessingMode.direct.requiresLLM)
        XCTAssertNil(ProcessingMode.direct.voicePolishQualityMode)
        XCTAssertEqual(ProcessingMode.lightPolish.voicePolishQualityMode, .standard)
        XCTAssertEqual(ProcessingMode.formalWriting.voicePolishQualityMode, .standard)
        XCTAssertEqual(ProcessingMode.formalWriting.id.uuidString, "7FC0076F-A85E-454B-8789-47A2F15A6E2F")
        XCTAssertEqual(ProcessingMode.formalWriting.hotkeyCode, 18)
        XCTAssertEqual(ProcessingMode.promptOptimize.hotkeyCode, 19)
        XCTAssertEqual(ProcessingMode.translate.hotkeyCode, 20)
        XCTAssertEqual(ProcessingMode.lightPolish.hotkeyCode, 21)
    }

    func testLoadingLegacyModesAddsLightInMemoryAndPreservesUserStandardMode() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dal-three-modes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let storage = ModeStorage(fileURL: file)
        var standard = ProcessingMode.formalWriting
        standard.name = "我的工作表达"
        standard.prompt = "保留我的直接语气。"
        standard.processingLabel = "正在整理我的内容"
        standard.hotkeyCode = 30
        standard.hotkeyModifiers = 131072
        standard.hotkeyStyle = .hold
        standard.isBuiltin = false
        try storage.save([.direct, standard, .translate])
        let original = try Data(contentsOf: file)

        let loaded = storage.load()
        let restored = try XCTUnwrap(loaded.first { $0.id == standard.id })
        XCTAssertEqual(restored.name, standard.name)
        XCTAssertEqual(restored.prompt, standard.prompt)
        XCTAssertEqual(restored.processingLabel, standard.processingLabel)
        XCTAssertEqual(restored.hotkeyCode, standard.hotkeyCode)
        XCTAssertEqual(restored.hotkeyModifiers, standard.hotkeyModifiers)
        XCTAssertEqual(restored.hotkeyStyle, .hold)
        XCTAssertTrue(restored.isBuiltin)
        XCTAssertEqual(loaded.filter { $0.id == ProcessingMode.lightPolishId }.count, 0)
        XCTAssertNil(loaded.first { $0.id == ProcessingMode.lightPolishId })
        XCTAssertEqual(try Data(contentsOf: file), original, "加载迁移不得写回用户配置")
    }

    func testLegacyDefaultNameChangesButOptionFourConflictDoesNotOverwriteBinding() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dal-three-conflict-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let storage = ModeStorage(fileURL: file)
        var standard = ProcessingMode.formalWriting
        standard.name = "语音润色"
        standard.processingLabel = "润色中"
        var custom = ProcessingMode.newCustomMode(name: "已有快捷入口")
        custom.hotkeyCode = 21
        custom.hotkeyModifiers = 524288
        try storage.save([.direct, standard, custom])
        let loaded = storage.load()

        XCTAssertEqual(loaded.first { $0.id == standard.id }?.name, ProcessingMode.formalWriting.name)
        XCTAssertEqual(loaded.first { $0.id == standard.id }?.processingLabel, ProcessingMode.formalWriting.processingLabel)
        XCTAssertNil(loaded.first { $0.id == ProcessingMode.lightPolishId }?.hotkeyCode)
        XCTAssertNil(loaded.first { $0.id == ProcessingMode.lightPolishId }?.hotkeyModifiers)
        XCTAssertEqual(loaded.first { $0.id == custom.id }?.hotkeyCode, 21)
        XCTAssertEqual(loaded.first { $0.id == custom.id }?.hotkeyModifiers, 524288)
    }

    func testPersistedLightModeKeepsItsOwnRequirementsAndCannotBeForgedByName() throws {
        var light = ProcessingMode.lightPolish
        light.name = "我的快速纠错"
        light.prompt = "保留语气词。"
        let decoded = try JSONDecoder().decode(ProcessingMode.self, from: JSONEncoder().encode(light))
        XCTAssertEqual(decoded.voicePolishQualityMode, .standard)
        XCTAssertEqual(decoded.prompt, light.prompt)

        let impostor = ProcessingMode(
            id: UUID(), name: "轻度润色", prompt: "自定义提示词", kind: .voicePolish, isBuiltin: false
        )
        let decodedImpostor = try JSONDecoder().decode(ProcessingMode.self, from: JSONEncoder().encode(impostor))
        XCTAssertEqual(decodedImpostor.kind, .custom)
        XCTAssertNil(decodedImpostor.voicePolishQualityMode)
    }

    func testRecordingCanSwitchModesButFinishingAndProcessingCannotRelabelTheResult() async {
        let session = RecognitionSession(historyStore: HistoryStore(path: ":memory:"))
        for acceptingState in [RecognitionSession.SessionState.starting, .recording] {
            await session.setState(acceptingState)
            await session.switchMode(to: .lightPolish)
            var mode = await session.currentModeForTesting()
            XCTAssertEqual(mode.id, ProcessingMode.formalWriting.id)
            await session.switchMode(to: .formalWriting)
            mode = await session.currentModeForTesting()
            XCTAssertEqual(mode.id, ProcessingMode.formalWriting.id)
        }
        for frozenState in [RecognitionSession.SessionState.finishing, .postProcessing, .injecting, .idle] {
            await session.setState(frozenState)
            await session.switchMode(to: .lightPolish)
            let mode = await session.currentModeForTesting()
            XCTAssertEqual(mode.id, ProcessingMode.formalWriting.id, "\(frozenState) 不得更改已经冻结的结果档位")
        }
    }

    func testSessionPassesEachPolishModeToTheModelAndDirectNeedsNoModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dal-mode-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "VoiceInputModeIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let vocabulary = VocabularyStorageContext(
            supportDirectory: directory, userDefaults: defaults, fileManager: .default,
            hotwordsDidChange: {}, revealFile: { _ in }
        )
        // “点”在自然时间和“重点”中都不是代码符号，原样保留不应被事实门禁拒绝。
        let source = "明天下午三点开会，重点是核对链接。"
        let transcript = RecognitionTranscript(
            confirmedSegments: [source], partialText: "", authoritativeText: source, isFinal: true
        )
        for mode in ProcessingMode.builtins {
            let client = VoiceInputModeProbeLLM()
            let needsLLM = mode.requiresLLM
            let session = RecognitionSession(
                historyStore: HistoryStore(path: ":memory:"),
                llmClientFactory: { client },
                llmConfigLoader: {
                    needsLLM ? LLMConfig(apiKey: "test", model: "mock", baseURL: "https://example.com/v1") : nil
                }
            )
            let result = await session.postProcessForTesting(
                rawText: source, transcript: transcript, mode: mode,
                writingContext: WritingContext(scene: .unknown), vocabularyContext: vocabulary
            )
            XCTAssertEqual(result?.finalText, source, mode.name)
            let requests = await client.recordedRequests()
            if mode.voicePolishQualityMode != nil {
                XCTAssertEqual(result?.processedText, source, mode.name)
                XCTAssertFalse(result?.llmFailed ?? true, mode.name)
                XCTAssertEqual(result?.historyStatus, "voice_polish_success", mode.name)
                XCTAssertEqual(requests.count, 1, mode.name)
                XCTAssertEqual(requests.map(\.task), [.voicePolishStructured], mode.name)
                XCTAssertEqual(requests.map(\.system), [VoicePolishEditingPrompts.standard], mode.name)
                for request in requests {
                    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.user.utf8)) as? [String: String])
                    XCTAssertEqual(payload, ["canonical_text": source], mode.name)
                    XCTAssertEqual(request.options.responseFormat, .text, mode.name)
                }
            } else {
                XCTAssertTrue(requests.isEmpty, "直出不配置、不调用润色模型")
            }
        }
    }
}

private actor VoiceInputModeProbeLLM: LLMClient {
    private var requests: [LLMRequest] = []

    func generate(_ request: LLMRequest, config: LLMConfig) async throws -> LLMResponse {
        requests.append(request)
        let payload = try JSONSerialization.jsonObject(with: Data(request.user.utf8)) as? [String: Any]
        XCTAssertEqual(request.options.responseFormat, .text)
        return LLMResponse(text: payload?["canonical_text"] as? String ?? "", model: config.model)
    }

    func process(text: String, prompt: String, context: LLMRequestContext, config: LLMConfig) async throws -> String {
        XCTFail("三档入口不应调用旧 process 接口")
        return text
    }

    func warmUp(baseURL: String) async {}
    func recordedRequests() -> [LLMRequest] { requests }
}
