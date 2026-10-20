import XCTest
@testable import Dal

/// 默认模式的语言感知迁移（2026-06-12）：名称/Prompt 仍是任一语言默认值时
/// 跟随当前界面语言；用户自定义内容一律保留。
final class ModeStorageLanguageMigrationTests: XCTestCase {

    private var savedLanguage: String?
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        savedLanguage = UserDefaults.standard.string(forKey: DefaultsKeys.language)
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("modes-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        if let savedLanguage {
            UserDefaults.standard.set(savedLanguage, forKey: DefaultsKeys.language)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.language)
        }
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    private func seedChineseDefaults(_ storage: ModeStorage) throws {
        UserDefaults.standard.set("zh", forKey: DefaultsKeys.language)
        var translate = ProcessingMode.translate
        var optimize = ProcessingMode.promptOptimize
        // 模拟历史 typo 世代的默认名
        optimize.name = "Promp优化"
        XCTAssertEqual(translate.name, "英文翻译")
        try storage.save([ProcessingMode.direct, optimize, translate])
        _ = translate
    }

    func testChineseDefaultsFollowLanguageSwitchToEnglish() throws {
        let storage = ModeStorage(fileURL: tempURL)
        try seedChineseDefaults(storage)

        UserDefaults.standard.set("en", forKey: DefaultsKeys.language)
        let loaded = storage.load()

        let translate = loaded.first { $0.id == ProcessingMode.translate.id }
        XCTAssertEqual(translate?.name, "Translation")
        XCTAssertEqual(translate?.prompt, ProcessingMode.translatePromptTemplateEN)

        let optimize = loaded.first { $0.id == ProcessingMode.promptOptimize.id }
        XCTAssertEqual(optimize?.name, "Prompt Optimizer")
        XCTAssertEqual(optimize?.prompt, ProcessingMode.promptOptimizePromptTemplateEN)

        let direct = loaded.first { $0.id == ProcessingMode.direct.id }
        XCTAssertEqual(direct?.name, "Direct")
    }

    func testCustomizedNameAndPromptArePreserved() throws {
        let storage = ModeStorage(fileURL: tempURL)
        UserDefaults.standard.set("zh", forKey: DefaultsKeys.language)

        var custom = ProcessingMode.translate
        custom.name = "我的翻译"
        custom.prompt = "完全自定义的 prompt {text}"
        try storage.save([ProcessingMode.direct, custom])

        UserDefaults.standard.set("en", forKey: DefaultsKeys.language)
        let loaded = storage.load()

        let translate = loaded.first { $0.id == ProcessingMode.translate.id }
        XCTAssertEqual(translate?.name, "我的翻译")
        XCTAssertEqual(translate?.prompt, "完全自定义的 prompt {text}")
    }

    func testEnglishDefaultsFollowSwitchBackToChinese() throws {
        let storage = ModeStorage(fileURL: tempURL)
        UserDefaults.standard.set("en", forKey: DefaultsKeys.language)
        try storage.save([ProcessingMode.direct, ProcessingMode.translate])

        UserDefaults.standard.set("zh", forKey: DefaultsKeys.language)
        let loaded = storage.load()

        let translate = loaded.first { $0.id == ProcessingMode.translate.id }
        XCTAssertEqual(translate?.name, "英文翻译")
        XCTAssertEqual(translate?.prompt, ProcessingMode.translatePromptTemplateZH)
    }
}
