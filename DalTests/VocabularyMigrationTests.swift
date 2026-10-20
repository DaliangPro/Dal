import Foundation
import XCTest
@testable import Dal

final class VocabularyMigrationTests: XCTestCase {
    func testFirstMigrationSeedsBothBuiltinFiles() throws {
        let context = try makeContext()

        HotwordStorage.migrateIfNeeded(context: context)
        SnippetStorage.migrateIfNeeded(context: context)

        XCTAssertEqual(HotwordStorage.loadBuiltin(context: context), HotwordStorage.defaultHotwords)
        XCTAssertEqual(
            SnippetStorage.loadBuiltin(context: context).map(pairKey),
            SnippetStorage.defaultSnippets.map(pairKey)
        )
        XCTAssertEqual(context.userDefaults.integer(forKey: "tf_hotwords_schema_version"), 2)
        XCTAssertEqual(context.userDefaults.integer(forKey: "tf_snippets_schema_version"), 2)
    }

    func testModifiedBuiltinFilesAreNeverOverwrittenByLaterMigration() throws {
        let context = try makeContext()
        HotwordStorage.migrateIfNeeded(context: context)
        SnippetStorage.migrateIfNeeded(context: context)
        try HotwordStorage.saveBuiltin(["用户修改的内置热词"], context: context)
        try SnippetStorage.saveBuiltin(
            [(trigger: "用户修改的触发词", value: "用户修改的替换词")],
            context: context
        )

        HotwordStorage.migrateIfNeeded(context: context)
        SnippetStorage.migrateIfNeeded(context: context)

        XCTAssertEqual(HotwordStorage.loadBuiltin(context: context), ["用户修改的内置热词"])
        XCTAssertEqual(
            SnippetStorage.loadBuiltin(context: context).map(pairKey),
            ["用户修改的触发词\t用户修改的替换词"]
        )
    }

    func testExistingUserFilesArePreservedDuringMigration() throws {
        let context = try makeContext()
        try HotwordStorage.save(["用户热词"], context: context)
        try SnippetStorage.save(
            [(trigger: "用户错词", value: "用户正词")],
            context: context
        )

        HotwordStorage.migrateIfNeeded(context: context)
        SnippetStorage.migrateIfNeeded(context: context)

        XCTAssertEqual(HotwordStorage.load(context: context), ["用户热词"])
        XCTAssertEqual(
            SnippetStorage.load(context: context).map(pairKey),
            ["用户错词\t用户正词"]
        )
    }

    func testOneHundredTwentyUserWordsAreTruncatedToOneHundred() throws {
        let context = try makeContext()
        try HotwordStorage.save((0..<120).map { "用户词\($0)" }, context: context)
        try HotwordStorage.saveBuiltin(["内置词"], context: context)

        let selection = HotwordStorage.loadEffectiveForASR(limit: 100, context: context)

        XCTAssertEqual(selection.words.count, 100)
        XCTAssertEqual(selection.userCount, 100)
        XCTAssertEqual(selection.truncatedUserCount, 20)
        XCTAssertEqual(selection.words.first, "用户词0")
        XCTAssertEqual(selection.words.last, "用户词99")
    }

    func testEightyUserWordsFillRemainingLimitWithTwentyBuiltinWords() throws {
        let context = try makeContext()
        try HotwordStorage.save((0..<80).map { "用户词\($0)" }, context: context)
        try HotwordStorage.saveBuiltin((0..<52).map { "内置词\($0)" }, context: context)

        let selection = HotwordStorage.loadEffectiveForASR(limit: 100, context: context)

        XCTAssertEqual(selection.words.count, 100)
        XCTAssertEqual(selection.userCount, 80)
        XCTAssertEqual(selection.truncatedUserCount, 0)
        XCTAssertEqual(Array(selection.words.suffix(20)), (0..<20).map { "内置词\($0)" })
    }

    func testEffectiveHotwordsTrimAndDeduplicateCaseInsensitively() throws {
        let context = try makeContext()
        try HotwordStorage.save([" Alpha ", "alpha", "   ", "BETA"], context: context)
        try HotwordStorage.saveBuiltin([" beta ", "Gamma", " gamma "], context: context)

        let selection = HotwordStorage.loadEffectiveForASR(limit: 100, context: context)

        XCTAssertEqual(selection.words, ["Alpha", "BETA", "Gamma"])
        XCTAssertEqual(selection.userCount, 2)
        XCTAssertEqual(selection.truncatedUserCount, 0)
    }

    func testSchemaMigrationRunsLegacyImportOnlyOnce() throws {
        let context = try makeContext()
        context.userDefaults.set("旧热词", forKey: "tf_hotwords")
        context.userDefaults.set(
            try JSONEncoder().encode([["旧错词", "旧正词"]]),
            forKey: "tf_snippets"
        )
        HotwordStorage.migrateIfNeeded(context: context)
        SnippetStorage.migrateIfNeeded(context: context)
        XCTAssertEqual(HotwordStorage.load(context: context), ["旧热词"])
        XCTAssertEqual(SnippetStorage.load(context: context).map(pairKey), ["旧错词\t旧正词"])

        try context.fileManager.removeItem(at: HotwordStorage.userFileURL(in: context))
        try context.fileManager.removeItem(at: SnippetStorage.userFileURL(in: context))
        context.userDefaults.set("不应再次导入", forKey: "tf_hotwords")
        context.userDefaults.set(
            try JSONEncoder().encode([["不应再次导入", "错误"]]),
            forKey: "tf_snippets"
        )

        HotwordStorage.migrateIfNeeded(context: context)
        SnippetStorage.migrateIfNeeded(context: context)

        XCTAssertTrue(HotwordStorage.load(context: context).isEmpty)
        XCTAssertTrue(SnippetStorage.load(context: context).isEmpty)
        XCTAssertEqual(context.userDefaults.integer(forKey: "tf_hotwords_schema_version"), 2)
        XCTAssertEqual(context.userDefaults.integer(forKey: "tf_snippets_schema_version"), 2)
    }

    func testLegacyCompletedFlagsBridgeToSchemaWithoutResurrectingDeletedData() throws {
        let context = try makeContext()
        context.userDefaults.set(true, forKey: "tf_hotwords_migrated_to_file_v2")
        context.userDefaults.set(true, forKey: "tf_snippets_migrated_to_file_v2")
        context.userDefaults.set("已被用户删除的旧热词", forKey: "tf_hotwords")
        context.userDefaults.set(
            try JSONEncoder().encode([["已删除旧错词", "不应复活"]]),
            forKey: "tf_snippets"
        )

        HotwordStorage.migrateIfNeeded(context: context)
        SnippetStorage.migrateIfNeeded(context: context)

        XCTAssertTrue(HotwordStorage.load(context: context).isEmpty)
        XCTAssertTrue(SnippetStorage.load(context: context).isEmpty)
        XCTAssertEqual(context.userDefaults.integer(forKey: "tf_hotwords_schema_version"), 2)
        XCTAssertEqual(context.userDefaults.integer(forKey: "tf_snippets_schema_version"), 2)
    }

    func testSchemaTwoAppendsOnlyNewCommonVocabularyAndPreservesCustomBuiltins() throws {
        let context = try makeContext()
        try HotwordStorage.saveBuiltin(["自定义内置热词"], context: context)
        try SnippetStorage.saveBuiltin(
            [(trigger: "自定义错词", value: "自定义正词")],
            context: context
        )
        context.userDefaults.set(1, forKey: "tf_hotwords_schema_version")
        context.userDefaults.set(1, forKey: "tf_snippets_schema_version")

        HotwordStorage.migrateIfNeeded(context: context)
        SnippetStorage.migrateIfNeeded(context: context)

        let hotwords = HotwordStorage.loadBuiltin(context: context)
        XCTAssertEqual(hotwords.first, "自定义内置热词")
        XCTAssertTrue(hotwords.contains("Typeless"))
        XCTAssertTrue(hotwords.contains("食其家"))
        XCTAssertEqual(hotwords.filter { $0 == "Typeless" }.count, 1)

        let snippets = SnippetStorage.loadBuiltin(context: context).map(pairKey)
        XCTAssertEqual(snippets.first, "自定义错词\t自定义正词")
        XCTAssertTrue(snippets.contains("Type less\tTypeless"))
        XCTAssertTrue(snippets.contains("食奇家\t食其家"))
        XCTAssertEqual(context.userDefaults.integer(forKey: "tf_hotwords_schema_version"), 2)
        XCTAssertEqual(context.userDefaults.integer(forKey: "tf_snippets_schema_version"), 2)
    }

    func testLegacySnippetKeepsUserReplacementCapitalizationOverride() throws {
        let context = try makeContext()
        context.userDefaults.set(
            try JSONEncoder().encode([["chat GPT", "CHATGPT"]]),
            forKey: "tf_snippets"
        )

        SnippetStorage.migrateIfNeeded(context: context)

        XCTAssertEqual(
            SnippetStorage.load(context: context).map(pairKey),
            ["chat GPT\tCHATGPT"]
        )
    }

    func testMalformedLegacyPayloadDoesNotAdvanceSchemaVersion() throws {
        let context = try makeContext()
        context.userDefaults.set(["不是字符串"], forKey: "tf_hotwords")
        context.userDefaults.set(
            try JSONEncoder().encode([["缺少替换值"]]),
            forKey: "tf_snippets"
        )

        HotwordStorage.migrateIfNeeded(context: context)
        SnippetStorage.migrateIfNeeded(context: context)

        XCTAssertEqual(context.userDefaults.integer(forKey: "tf_hotwords_schema_version"), 0)
        XCTAssertEqual(context.userDefaults.integer(forKey: "tf_snippets_schema_version"), 0)
        XCTAssertFalse(context.fileManager.fileExists(atPath: HotwordStorage.userFileURL(in: context).path))
        XCTAssertFalse(context.fileManager.fileExists(atPath: SnippetStorage.userFileURL(in: context).path))
    }

    func testUserSnippetOverridesWhitespaceEquivalentBuiltinTrigger() throws {
        let context = try makeContext()
        try SnippetStorage.saveBuiltin(
            [(trigger: "Cloud Code", value: "内置替换")],
            context: context
        )
        try SnippetStorage.save(
            [(trigger: "cloudcode", value: "用户替换")],
            context: context
        )

        XCTAssertEqual(
            SnippetStorage.applyEffective(to: "cloud code", context: context),
            "用户替换"
        )
    }

    func testFinderBulkEditCreatesAndRevealsOnlyUserFiles() throws {
        let revealed = LockedBox<[URL]>([])
        let context = try makeContext(revealFile: { url in
            revealed.withLock { $0.append(url) }
        })

        HotwordStorage.revealUserInFinder(context: context)
        SnippetStorage.revealUserInFinder(context: context)

        XCTAssertEqual(
            revealed.withLock { $0.map(\.lastPathComponent) },
            ["hotwords.json", "snippets.json"]
        )
        XCTAssertTrue(context.fileManager.fileExists(atPath: HotwordStorage.userFileURL(in: context).path))
        XCTAssertTrue(context.fileManager.fileExists(atPath: SnippetStorage.userFileURL(in: context).path))
    }

    func testReloadInvalidatesSnippetCacheAndNotifiesHotwordConsumer() throws {
        let hotwordReloads = LockedBox(0)
        let context = try makeContext(
            hotwordsDidChange: { hotwordReloads.withLock { $0 += 1 } }
        )
        try SnippetStorage.saveBuiltin([], context: context)
        try SnippetStorage.save([(trigger: "cloud", value: "第一次")], context: context)
        XCTAssertEqual(SnippetStorage.applyEffective(to: "cloud", context: context), "第一次")
        try JSONFileStore.writeOrThrow(
            [RawSnippetEntry(trigger: "cloud", replacement: "第二次")],
            to: SnippetStorage.userFileURL(in: context)
        )
        XCTAssertEqual(SnippetStorage.applyEffective(to: "cloud", context: context), "第一次")
        let reloadCountBefore = hotwordReloads.withLock { $0 }

        SnippetStorage.reloadFromDisk(context: context)
        HotwordStorage.reloadFromDisk(context: context)

        XCTAssertEqual(SnippetStorage.applyEffective(to: "cloud", context: context), "第二次")
        XCTAssertEqual(hotwordReloads.withLock { $0 }, reloadCountBefore + 1)
    }

    func testSnippetCacheIsSeparatedByInjectedStorageContext() throws {
        let firstContext = try makeContext()
        let secondContext = try makeContext()
        try SnippetStorage.saveBuiltin([], context: firstContext)
        try SnippetStorage.save([(trigger: "cloud", value: "第一个目录")], context: firstContext)
        XCTAssertEqual(
            SnippetStorage.applyEffective(to: "cloud", context: firstContext),
            "第一个目录"
        )

        // 绕过 save/invalidate，证明第二个目录不能误用第一个目录的缓存。
        try JSONFileStore.writeOrThrow(
            [RawSnippetEntry(trigger: "cloud", replacement: "第二个目录")],
            to: SnippetStorage.userFileURL(in: secondContext)
        )
        try JSONFileStore.writeOrThrow(
            [RawSnippetEntry](),
            to: SnippetStorage.builtinFileURL(in: secondContext)
        )

        XCTAssertEqual(
            SnippetStorage.applyEffective(to: "cloud", context: secondContext),
            "第二个目录"
        )
    }

    private func pairKey(_ pair: (trigger: String, value: String)) -> String {
        "\(pair.trigger)\t\(pair.value)"
    }

    private func makeContext(
        hotwordsDidChange: @escaping () -> Void = {},
        revealFile: @escaping (URL) -> Void = { _ in }
    ) throws -> VocabularyStorageContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DalVocabularyMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "DalVocabularyMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return VocabularyStorageContext(
            supportDirectory: directory,
            userDefaults: defaults,
            fileManager: .default,
            hotwordsDidChange: hotwordsDidChange,
            revealFile: revealFile
        )
    }
}

private struct RawSnippetEntry: Encodable {
    let trigger: String
    let replacement: String
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
