import XCTest
@testable import Dal

final class ModeStorageTests: XCTestCase {

    private let testURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dal-test-modes.json")

    private func withChineseAppLanguage(_ action: () -> Void) {
        let savedLanguage = UserDefaults.standard.string(forKey: DefaultsKeys.language)
        UserDefaults.standard.set(AppLanguage.zh.rawValue, forKey: DefaultsKeys.language)
        defer {
            if let savedLanguage {
                UserDefaults.standard.set(savedLanguage, forKey: DefaultsKeys.language)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKeys.language)
            }
        }
        action()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testURL)
    }

    func testSaveAndLoad() throws {
        let storage = ModeStorage(fileURL: testURL)
        let modes = ProcessingMode.builtins + [
            ProcessingMode(id: UUID(), name: "Custom", prompt: "Do {text}", isBuiltin: false)
        ]
        try storage.save(modes)
        let loaded = storage.load()
        // built-in modes are auto-injected if missing
        XCTAssertTrue(loaded.contains { $0.name == "Custom" })
        XCTAssertTrue(loaded.contains { $0.id == ProcessingMode.direct.id })
    }

    func testLoadMissing_returnsBuiltins() {
        let storage = ModeStorage(fileURL: testURL)
        let loaded = storage.load()
        XCTAssertEqual(loaded, ProcessingMode.defaults)
    }

    func testLoadMigratesLegacyBuiltinModesToDeletableModes() throws {
        let storage = ModeStorage(fileURL: testURL)
        let legacyModes = [
            ProcessingMode.direct,
            ProcessingMode(
                id: ProcessingMode.smartDirect.id,
                name: "智能模式",
                prompt: "",
                isBuiltin: true
            ),
            ProcessingMode(
                id: ProcessingMode.translateId,
                name: "英文翻译",
                prompt: "legacy",
                isBuiltin: true,
                processingLabel: "翻译中"
            ),
        ]

        try storage.save(legacyModes)
        let loaded = storage.load()

        let smart = loaded.first(where: { $0.id == ProcessingMode.smartDirect.id })
        let translate = loaded.first(where: { $0.id == ProcessingMode.translate.id })

        XCTAssertEqual(smart?.isBuiltin, false)
        XCTAssertEqual(smart?.prompt, ProcessingMode.smartDirect.prompt)
        XCTAssertEqual(translate?.isBuiltin, false)
        XCTAssertEqual(translate?.prompt, ProcessingMode.translate.prompt)
    }

    func testDeletedDefaultModesAreNotReinserted() throws {
        let storage = ModeStorage(fileURL: testURL)
        try storage.save([ProcessingMode.direct])

        let loaded = storage.load()

        // direct is kept
        XCTAssertTrue(loaded.contains { $0.id == ProcessingMode.direct.id })
        // Voice Polish 拥有独立设置与学习数据，稳定 ID 始终恢复。
        XCTAssertTrue(loaded.contains { $0.id == ProcessingMode.formalWriting.id })
        // smartDirect and translate were removed and not re-injected
        XCTAssertFalse(loaded.contains { $0.id == ProcessingMode.smartDirect.id })
        XCTAssertFalse(loaded.contains { $0.id == ProcessingMode.translate.id })
    }

    func testVoicePolishIsRestoredAsProtectedSystemModeWithoutOverwritingPrompt() throws {
        let storage = ModeStorage(fileURL: testURL)
        var voicePolish = ProcessingMode.formalWriting
        voicePolish.isBuiltin = false
        voicePolish.prompt = "保留我的口语感，不要过度正式。"
        voicePolish.hotkeyCode = 27

        try storage.save([ProcessingMode.direct, voicePolish])
        let loaded = storage.load()

        let restored = try XCTUnwrap(loaded.first { $0.id == ProcessingMode.formalWriting.id })
        XCTAssertTrue(restored.isBuiltin)
        XCTAssertTrue(restored.isProtectedSystemMode)
        XCTAssertFalse(restored.isUserDeletable)
        XCTAssertEqual(restored.prompt, voicePolish.prompt)
        XCTAssertEqual(restored.hotkeyCode, 27)
    }

    func testCustomSmartModePromptIsPreserved() throws {
        let storage = ModeStorage(fileURL: testURL)
        let customSmart = ProcessingMode(
            id: ProcessingMode.smartDirect.id,
            name: "智能模式",
            prompt: "自定义智能 Prompt: {text}",
            isBuiltin: false,
            processingLabel: "修正中"
        )

        try storage.save([ProcessingMode.direct, customSmart])
        let loaded = storage.load()

        XCTAssertEqual(loaded.first(where: { $0.id == ProcessingMode.smartDirect.id })?.prompt, customSmart.prompt)
        XCTAssertEqual(loaded.first(where: { $0.id == ProcessingMode.smartDirect.id })?.processingLabel, customSmart.processingLabel)
    }

    func testLoadMigratesLegacySeededDefaultPromptsWhenUnchanged() throws {
        let storage = ModeStorage(fileURL: testURL)
        var legacyFormalWriting = ProcessingMode.formalWriting
        legacyFormalWriting.prompt = ProcessingMode.legacyFormalWritingPromptTemplate
        legacyFormalWriting.processingLabel = "我的润色中"
        legacyFormalWriting.hotkeyCode = 30

        var legacyTranslate = ProcessingMode.translate
        legacyTranslate.prompt = ProcessingMode.legacyTranslatePromptTemplate
        legacyTranslate.processingLabel = "我的翻译中"
        legacyTranslate.hotkeyCode = 31

        try storage.save([ProcessingMode.direct, legacyFormalWriting, legacyTranslate])
        let loaded = storage.load()

        let formalWriting = loaded.first(where: { $0.id == ProcessingMode.formalWriting.id })
        let translate = loaded.first(where: { $0.id == ProcessingMode.translate.id })

        XCTAssertEqual(formalWriting?.prompt, ProcessingMode.formalWriting.prompt)
        XCTAssertEqual(formalWriting?.processingLabel, "我的润色中")
        XCTAssertEqual(formalWriting?.hotkeyCode, 30)

        XCTAssertEqual(translate?.prompt, ProcessingMode.translate.prompt)
        XCTAssertEqual(translate?.processingLabel, "我的翻译中")
        XCTAssertEqual(translate?.hotkeyCode, 31)
    }

    func testCustomizedSeededDefaultPromptsArePreserved() throws {
        let storage = ModeStorage(fileURL: testURL)
        var customFormalWriting = ProcessingMode.formalWriting
        customFormalWriting.prompt = "请把文本整理成更正式的版本：\n{text}"

        var customTranslate = ProcessingMode.translate
        customTranslate.prompt = "Translate this into concise English:\n{text}"

        try storage.save([ProcessingMode.direct, customFormalWriting, customTranslate])
        let loaded = storage.load()

        XCTAssertEqual(
            loaded.first(where: { $0.id == ProcessingMode.formalWriting.id })?.prompt,
            customFormalWriting.prompt
        )
        XCTAssertEqual(
            loaded.first(where: { $0.id == ProcessingMode.translate.id })?.prompt,
            customTranslate.prompt
        )
    }

    func testNewCustomModeStartsWithEmptyPrompt() {
        let id = UUID()

        let mode = ProcessingMode.newCustomMode(id: id)

        XCTAssertEqual(mode.id, id)
        XCTAssertFalse(mode.isBuiltin)
        XCTAssertEqual(mode.prompt, "")
    }

    func testNewCustomModeCanUseProvidedName() {
        let mode = ProcessingMode.newCustomMode(name: "会议纪要")

        XCTAssertEqual(mode.name, "会议纪要")
        XCTAssertFalse(mode.isBuiltin)
        XCTAssertEqual(mode.prompt, "")
    }

    func testVoicePolishDoesNotAppendLegacyHiddenGuards() {
        withChineseAppLanguage {
            var mode = ProcessingMode.formalWriting
            mode.prompt = "请润色：{text}"

            let guardedPrompt = mode.applyingLLMFormatGuard(to: mode.prompt)

            XCTAssertTrue(guardedPrompt.contains(mode.prompt))
            XCTAssertFalse(guardedPrompt.contains("枚举事项强制规则"))
            XCTAssertFalse(guardedPrompt.contains("自然分段与口语清理强制规则"))
            XCTAssertFalse(guardedPrompt.contains("润色任务边界（最高优先级）"))
        }
    }

    func testDirectModeDoesNotApplyListFormatGuard() {
        withChineseAppLanguage {
            let prompt = "原样输出：{text}"
            let guardedPrompt = ProcessingMode.direct.applyingLLMFormatGuard(to: prompt)

            XCTAssertTrue(guardedPrompt.contains(prompt))
            XCTAssertFalse(guardedPrompt.contains("枚举事项强制规则"))
            XCTAssertTrue(guardedPrompt.contains("只输出最终要写入输入框的正文"))
        }
    }

    func testVoicePolishDoesNotMechanicallyReplaceSemanticPhrases() {
        let result = "搭建系统其实它就是一个文件系统。问题就是用 CodeX 还是 Cloud Code。"
        let cleanedResult = ProcessingMode.formalWriting.applyingLLMResultCleanup(to: result)

        XCTAssertEqual(cleanedResult, result)
    }

    func testDirectModeDoesNotCleanLLMResult() {
        let result = "这就是原文里的 CodeX。"

        XCTAssertEqual(ProcessingMode.direct.applyingLLMResultCleanup(to: result), result)
    }

    // MARK: - Hotkey field tests

    func testHotkeyFieldsArePersisted() throws {
        let storage = ModeStorage(fileURL: testURL)
        var mode = ProcessingMode(
            id: UUID(), name: "Test", prompt: "{text}", isBuiltin: false
        )
        mode.hotkeyCode = 61
        mode.hotkeyModifiers = 0
        mode.hotkeyStyle = .hold

        try storage.save([ProcessingMode.direct, mode])
        let loaded = storage.load()
        let loadedMode = loaded.first { $0.name == "Test" }

        XCTAssertEqual(loadedMode?.hotkeyCode, 61)
        XCTAssertEqual(loadedMode?.hotkeyModifiers, 0)
        XCTAssertEqual(loadedMode?.hotkeyStyle, .hold)
    }

    func testMissingHotkeyFieldsDefaultGracefully() throws {
        let storage = ModeStorage(fileURL: testURL)
        // Simulate old JSON without hotkey fields
        let json = """
        [{"id":"00000000-0000-0000-0000-000000000001","name":"快速模式","prompt":"","isBuiltin":true,"processingLabel":"处理中","isDualChannel":false}]
        """
        try json.data(using: .utf8)!.write(to: testURL)
        let loaded = storage.load()
        let direct = loaded.first { $0.id == ProcessingMode.direct.id }

        // Old JSON has no hotkey fields - should decode gracefully to today's builtin default.
        XCTAssertEqual(direct?.hotkeyStyle, ProcessingMode.direct.hotkeyStyle)
    }

    func testToggleStyleIsPersisted() throws {
        let storage = ModeStorage(fileURL: testURL)
        var mode = ProcessingMode(
            id: UUID(), name: "Toggle Mode", prompt: "{text}", isBuiltin: false
        )
        mode.hotkeyCode = 58
        mode.hotkeyStyle = .toggle

        try storage.save([ProcessingMode.direct, mode])
        let loaded = storage.load()
        let loadedMode = loaded.first { $0.name == "Toggle Mode" }

        XCTAssertEqual(loadedMode?.hotkeyCode, 58)
        XCTAssertEqual(loadedMode?.hotkeyStyle, .toggle)
    }
}
