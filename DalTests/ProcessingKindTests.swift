import XCTest
@testable import Dal

final class ProcessingKindTests: XCTestCase {

    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
    }

    func testDefaultModesUseStableKindsAndLLMRequirements() {
        XCTAssertEqual(ProcessingMode.direct.kind, .direct)
        XCTAssertEqual(ProcessingMode.smartDirect.kind, .smartDirect)
        XCTAssertEqual(ProcessingMode.formalWriting.kind, .voicePolish)
        XCTAssertEqual(ProcessingMode.translate.kind, .translate)
        XCTAssertEqual(ProcessingMode.promptOptimize.kind, .promptOptimize)
        XCTAssertEqual(ProcessingMode.commandMode.kind, .command)

        XCTAssertFalse(ProcessingMode.direct.requiresLLM)
        XCTAssertTrue(ProcessingMode.formalWriting.requiresLLM)
        XCTAssertTrue(ProcessingMode.translate.requiresLLM)
        XCTAssertTrue(ProcessingMode.promptOptimize.requiresLLM)
        XCTAssertTrue(ProcessingMode.commandMode.requiresLLM)
    }

    func testCustomModeNameCannotChangeBusinessKind() {
        let mode = ProcessingMode(
            id: UUID(),
            name: "我的语音润色 Prompt 翻译",
            prompt: "",
            isBuiltin: false
        )

        XCTAssertEqual(mode.kind, .custom)
        XCTAssertFalse(mode.requiresLLM)
        XCTAssertFalse(mode.isPromptOptimizeMode)
        XCTAssertFalse(mode.isTranslateMode)
    }

    func testRenamingVoicePolishDoesNotChangeBusinessKind() {
        var mode = ProcessingMode.formalWriting
        mode.name = "随手整理"

        XCTAssertEqual(mode.kind, .voicePolish)
        XCTAssertTrue(mode.requiresLLM)
    }

    func testLegacyJSONWithoutKindUsesOnlyStableIDMapping() throws {
        let customID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            legacyMode(id: ProcessingMode.formalWriting.id, name: "已改名", prompt: "自定义要求"),
            legacyMode(id: customID, name: "语音润色", prompt: ""),
        ])

        let decoded = try JSONDecoder().decode([ProcessingMode].self, from: data)

        XCTAssertEqual(decoded[0].kind, .voicePolish)
        XCTAssertEqual(decoded[1].kind, .custom)
    }

    func testUnknownIDCannotClaimBuiltinKindFromStoredJSON() throws {
        let dictionary = legacyMode(id: UUID(), name: "任意模式", prompt: "处理文本")
            .merging(["kind": ProcessingKind.voicePolish.rawValue]) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: dictionary)

        let decoded = try JSONDecoder().decode(ProcessingMode.self, from: data)

        XCTAssertEqual(decoded.kind, .custom)
    }

    func testOfficialVoicePolishPromptsBecomeEmptyAdditionalRequirements() throws {
        let officialPrompts = [
            ProcessingMode.legacyFormalWritingPromptTemplate,
            ProcessingMode.legacyVoiceDraftEnginePromptTemplate,
            ProcessingMode.formalWritingPromptTemplateZH,
            ProcessingMode.formalWritingPromptTemplateEN,
        ]

        for (index, prompt) in officialPrompts.enumerated() {
            let storage = ModeStorage(fileURL: temporaryURL(suffix: "official-\(index)"))
            var mode = ProcessingMode.formalWriting
            mode.prompt = prompt.replacingOccurrences(of: "\n", with: "\r\n")
            try storage.save([ProcessingMode.direct, mode])

            let loaded = storage.load().first { $0.id == mode.id }

            XCTAssertEqual(loaded?.prompt, "", "第 \(index) 个官方 Prompt 未迁移")
            XCTAssertEqual(loaded?.kind, .voicePolish)
        }
    }

    func testOneCharacterVoicePolishPromptVariantIsPreserved() throws {
        let officialPrompts = [
            ProcessingMode.legacyFormalWritingPromptTemplate,
            ProcessingMode.legacyVoiceDraftEnginePromptTemplate,
            ProcessingMode.formalWritingPromptTemplateZH,
            ProcessingMode.formalWritingPromptTemplateEN,
        ]

        for (index, prompt) in officialPrompts.enumerated() {
            let storage = ModeStorage(fileURL: temporaryURL(suffix: "custom-\(index)"))
            var mode = ProcessingMode.formalWriting
            mode.prompt = prompt + "X"
            try storage.save([ProcessingMode.direct, mode])

            let loaded = storage.load().first { $0.id == mode.id }

            XCTAssertEqual(loaded?.prompt, prompt + "X", "第 \(index) 个自定义变体被误迁移")
        }
    }

    private func legacyMode(id: UUID, name: String, prompt: String) -> [String: Any] {
        [
            "id": id.uuidString,
            "name": name,
            "prompt": prompt,
            "isBuiltin": false,
            "processingLabel": "处理中",
            "hotkeyStyle": "toggle",
        ]
    }

    private func temporaryURL(suffix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dal-processing-kind-\(suffix)-\(UUID().uuidString).json")
        temporaryURLs.append(url)
        return url
    }
}
