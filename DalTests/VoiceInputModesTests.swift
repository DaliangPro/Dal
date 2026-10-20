import XCTest
@testable import Dal

final class VoiceInputModesTests: XCTestCase {
    func testPhraseReplacementRemainsAvailableWithoutBecomingAnASRHotword() {
        let phrase = "您好，材料已收到。稍后给您回复。"
        let document = TerminologyDocument(entries: [
            TerminologyEntry(canonicalText: phrase, aliases: [.init(text: "确认收件", source: .manual)], origin: .manual),
            TerminologyEntry(canonicalText: "Dal", aliases: [.init(text: "木思", source: .manual)], origin: .manual)
        ])
        let projection = TerminologyProjections.make(from: document)
        XCTAssertEqual(projection.hotwords, ["Dal"])
        XCTAssertEqual(projection.corrections["确认收件"], phrase)
        XCTAssertEqual(projection.corrections["木思"], "Dal")
    }

    func testLegacyIDResolvesToSavedPolishWithoutCombiningRequirementsOrShortcuts() {
        var legacy = ProcessingMode.lightPolish
        legacy.prompt = "旧附加要求"
        var polish = ProcessingMode.formalWriting
        polish.prompt = "当前要求"
        polish.hotkeyCode = 31
        let modes = [ProcessingMode.direct, legacy, polish, .translate]
        XCTAssertEqual(VoiceInputModes.resolve(legacy, in: modes), polish)
        XCTAssertEqual(VoiceInputModes.resolve(.direct, in: modes), .direct)
        XCTAssertEqual(VoiceInputModes.resolve(.translate, in: modes), .translate)
        XCTAssertEqual(VoiceInputModes.resolve(legacy), .formalWriting)
    }

    func testLegacySettingsStayOnDiskButNeverBecomeActiveAgain() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dal-mode-compat-\(UUID()).json")
        defer { _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        let storage = ModeStorage(fileURL: url)
        var legacy = ProcessingMode.lightPolish
        legacy.prompt = "保留这条旧要求，不拼进新的润色"
        var polish = ProcessingMode.formalWriting
        polish.prompt = "用自然段"
        var direct = ProcessingMode.direct
        direct.hotkeyCode = 33
        let custom = ProcessingMode.newCustomMode(name: "我的输出")
        try storage.save([direct, legacy, polish, .translate, .promptOptimize, .commandMode, custom])
        let before = try Data(contentsOf: url)
        let active = storage.load()
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(active.contains { $0.id == legacy.id })
        XCTAssertEqual(active.filter(\.isProtectedSystemMode).count, 2)
        XCTAssertEqual(active.first { $0.id == polish.id }?.prompt, polish.prompt)
        XCTAssertEqual(active.first { $0.id == direct.id }?.hotkeyCode, 33)
        XCTAssertTrue(active.contains { $0.id == custom.id })
        try storage.save(active)
        let raw = try JSONDecoder().decode([ProcessingMode].self, from: Data(contentsOf: url))
        XCTAssertEqual(raw.first { $0.id == legacy.id }, legacy)
        XCTAssertEqual(storage.load(), active)
    }

    func testMissingPolishDoesNotStealExistingOptionOneBinding() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dal-mode-conflict-\(UUID()).json")
        defer { _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        var custom = ProcessingMode.newCustomMode(name: "已有模式")
        custom.hotkeyCode = ProcessingMode.formalWriting.hotkeyCode
        custom.hotkeyModifiers = ProcessingMode.formalWriting.hotkeyModifiers
        let storage = ModeStorage(fileURL: url)
        try storage.save([.direct, .lightPolish, custom])
        let loaded = storage.load()
        XCTAssertEqual(loaded.first { $0.id == custom.id }?.hotkeyCode, custom.hotkeyCode)
        XCTAssertNil(loaded.first { $0.id == ProcessingMode.formalWriting.id }?.hotkeyCode)
        XCTAssertFalse(loaded.contains { $0.id == ProcessingMode.lightPolishId })
    }
}
