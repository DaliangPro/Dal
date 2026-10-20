import Foundation
import XCTest
@testable import Dal

final class InteractiveTestRuntimeTests: XCTestCase {
    private let candidate = URL(fileURLWithPath: "/Users/test/dal/build/interactive/Dal.app")

    func testLiveLearningAcceptanceRequiresExplicitFlagAndProductionBundle() {
        XCTAssertTrue(InteractiveTestRuntime.allowsLiveLearningAcceptance(
            bundleID: "pro.daliang.muse", arguments: ["Dal", "--live-learning-acceptance"]
        ))
        XCTAssertFalse(InteractiveTestRuntime.allowsLiveLearningAcceptance(bundleID: "pro.daliang.muse", arguments: ["Dal"]))
        for bundle in [nil, "other.app", InteractiveTestRuntime.bundleIdentifier] {
            XCTAssertFalse(InteractiveTestRuntime.allowsLiveLearningAcceptance(
                bundleID: bundle, arguments: ["Dal", "--live-learning-acceptance"]
            ))
        }
    }

    func testLiveLearningUsesSavedRequirementsAndNormalProviderResolution() {
        var stored = ProcessingMode.formalWriting
        stored.prompt = "保留我的附加要求"
        stored.processingLabel = "我的处理中提示"
        let modes = [ProcessingMode.direct, stored]
        let result = InteractiveTestRuntime.liveLearningMode(.formalWriting, modes: modes, provider: .volcano)
        XCTAssertEqual(result.prompt, stored.prompt)
        XCTAssertEqual(result.processingLabel, stored.processingLabel)
        for provider in ASRProvider.allCases {
            let resolved = ASRProviderRegistry.resolvedMode(for: .formalWriting, provider: provider)
            let expected = VoiceInputModes.resolve(modes.first { $0.id == resolved.id } ?? resolved, in: modes)
            XCTAssertEqual(InteractiveTestRuntime.liveLearningMode(.formalWriting, modes: modes, provider: provider), expected)
        }
    }

    @MainActor
    func testLiveLearningPanelHasRealRecordingActionsAndNoPermissionOrFixtureOverrides() {
        let menu = AppDelegate.makeLiveLearningAcceptanceMenu(target: nil)
        XCTAssertEqual(menu.items.map(\.title), ["开始直出录音", "开始润色录音", "停止并上屏", "关闭验收面板"])
        let existing = AppDelegate.makeInteractiveTestStatusMenu(target: nil)
        for title in ["开始直出录音", "停止并上屏"] {
            XCTAssertEqual(menu.items.first { $0.title == title }?.action,
                           existing.items.first { $0.title == title }?.action)
        }
    }

    func testProductionBundleIgnoresTestEnvironment() throws {
        XCTAssertNil(try InteractiveTestRuntime.validatedSupportDirectory(
            bundleID: "pro.daliang.muse", bundleURL: candidate,
            environment: [InteractiveTestRuntime.rootEnvironmentKey: "/unexpected"]
        ))
    }

    func testTestBundleRequiresExplicitAdjacentDirectory() throws {
        let expected = candidate.deletingLastPathComponent().appendingPathComponent("test-data")
        XCTAssertEqual(try resolve(expected.path)?.path, expected.path)
        for invalid in [nil, "", "test-data", "/Users/test/Library/Application Support/Muse",
                        candidate.appendingPathComponent("test-data").path,
                        candidate.deletingLastPathComponent().appendingPathComponent("another-data").path] {
            XCTAssertThrowsError(try resolve(invalid), "必须拒绝 \(invalid ?? "未配置")")
        }
    }

    func testSymlinkAncestorCannotRedirectTestData() throws {
        let alias = URL(fileURLWithPath: "/tmp", isDirectory: true)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: alias.path)) != nil else {
            throw XCTSkip("当前系统没有 /tmp 符号链接")
        }
        XCTAssertThrowsError(try InteractiveTestRuntime.validatedSupportDirectory(
            bundleID: InteractiveTestRuntime.bundleIdentifier,
            bundleURL: alias.appendingPathComponent("Dal.app"),
            environment: [InteractiveTestRuntime.rootEnvironmentKey: alias.appendingPathComponent("test-data").path]
        ))
    }

    func testFirstLaunchCreatesDirectoryAndReopeningPreservesExistingData() throws {
        let context = try makeVocabularyContext()
        let root = context.supportDirectory.appendingPathComponent("test-data", isDirectory: true)
        XCTAssertFalse(context.fileManager.fileExists(atPath: root.path))

        try InteractiveTestRuntime.ensureSupportDirectoryExists(at: root)
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(context.fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let existingFile = root.appendingPathComponent("existing-record.txt")
        let existingData = Data("复开前已存在的测试记录".utf8)
        try existingData.write(to: existingFile)

        try InteractiveTestRuntime.ensureSupportDirectoryExists(at: root)

        XCTAssertEqual(try Data(contentsOf: existingFile), existingData)
        XCTAssertEqual(try context.fileManager.contentsOfDirectory(atPath: root.path), ["existing-record.txt"])
    }

    func testExistingRegularFileCannotBecomeSupportDirectory() throws {
        let context = try makeVocabularyContext()
        let root = context.supportDirectory.appendingPathComponent("test-data", isDirectory: false)
        let existingData = Data("同名普通文件必须保留".utf8)
        try existingData.write(to: root)

        XCTAssertThrowsError(try InteractiveTestRuntime.ensureSupportDirectoryExists(at: root))

        XCTAssertEqual(try Data(contentsOf: root), existingData)
        var isDirectory = ObjCBool(true)
        XCTAssertTrue(context.fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
    }

    func testTestPreferencesStayVolatileAndDisableLearning() throws {
        let suite = "DalTests.InteractiveRuntime.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        defaults.setVolatileDomain(InteractiveTestRuntime.preferences, forName: UserDefaults.argumentDomain)
        XCTAssertEqual(defaults.string(forKey: DefaultsKeys.selectedASRProvider), "volcano")
        XCTAssertEqual(defaults.string(forKey: DefaultsKeys.selectedLLMProvider), "deepseek")
        XCTAssertEqual(VoicePolishSettings.modelOverride(defaults: defaults), "deepseek-flash")
        XCTAssertEqual(VoicePolishSettings.contextLevel(defaults: defaults), .metadataOnly)
        XCTAssertFalse(VoicePolishSettings.personalizationEnabled(defaults: defaults))
        XCTAssertFalse(VoicePolishSettings.terminologyLearningEnabled(defaults: defaults))
        XCTAssertFalse(VoicePolishSettings.recentInputContextEnabled(defaults: defaults))
        XCTAssertTrue((defaults.persistentDomain(forName: suite) ?? [:]).isEmpty)
    }

    func testBundledVocabularyInitializationUsesOnlyExistingDefaultsWithoutMigration() throws {
        let context = try makeVocabularyContext()
        context.userDefaults.set("不得导入的旧热词", forKey: "tf_hotwords")
        context.userDefaults.set(
            try JSONEncoder().encode([["不得导入的旧错词", "不得导入的旧正词"]]),
            forKey: "tf_snippets"
        )
        let preferencesBefore = NSDictionary(dictionary: context.userDefaults.dictionaryRepresentation())

        try initializeVocabulary(in: context)

        XCTAssertEqual(HotwordStorage.loadBuiltin(context: context), HotwordStorage.defaultHotwords)
        XCTAssertEqual(
            SnippetStorage.loadBuiltin(context: context).map { [$0.trigger, $0.value] },
            SnippetStorage.defaultSnippets.map { [$0.trigger, $0.value] }
        )
        XCTAssertEqual(
            Set(try context.fileManager.contentsOfDirectory(atPath: context.supportDirectory.path)),
            Set(["builtin-hotwords.json", "builtin-snippets.json"])
        )
        XCTAssertEqual(NSDictionary(dictionary: context.userDefaults.dictionaryRepresentation()), preferencesBefore)
    }

    func testBundledVocabularyPreparesLiveTranscriptWithoutGuessingOtherWords() throws {
        let context = try makeVocabularyContext()
        try initializeVocabulary(in: context)
        let raw = "你觉得是 Cloud Code 比较好用，还是 CodeX 比较好用呢？或者说 有很多的，主要是他们的文件吧。到底是 agents 点 MD 更好，还是 cloud 点 MD 更好？"
        let expected = "你觉得是 Claude Code 比较好用，还是 Codex 比较好用呢？或者说 有很多的，主要是他们的文件吧。到底是 agents 点 MD 更好，还是 cloud 点 MD 更好？"
        let prepared = VoicePolishTerminologyRuntime.prepare(
            rawText: raw, applicationBundleIdentifier: nil, context: context
        )
        XCTAssertEqual(prepared.canonicalText, expected)

        let reason = "我觉得这个事还是交给小李去处理吧，小李比较心细。哦，不对，小李请假了，还是交给小王去处理吧。"
        XCTAssertEqual(VoicePolishTerminologyRuntime.prepare(
            rawText: reason, applicationBundleIdentifier: nil, context: context
        ).canonicalText, reason)
    }

    func testRepeatedBundledVocabularyInitializationPreservesCustomizedFiles() throws {
        let context = try makeVocabularyContext()
        try initializeVocabulary(in: context)
        try HotwordStorage.saveBuiltin(["测试自定义内置热词"], context: context)
        try SnippetStorage.saveBuiltin(
            [(trigger: "测试自定义内置错词", value: "测试自定义内置正词")], context: context
        )
        try HotwordStorage.save(["测试用户热词"], context: context)
        try SnippetStorage.save(
            [(trigger: "测试用户错词", value: "测试用户正词")], context: context
        )
        let files = [
            HotwordStorage.builtinFileURL(in: context), SnippetStorage.builtinFileURL(in: context),
            HotwordStorage.userFileURL(in: context), SnippetStorage.userFileURL(in: context),
        ]
        let contentsBefore = try files.map { try Data(contentsOf: $0) }

        try initializeVocabulary(in: context)
        try initializeVocabulary(in: context)

        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, contentsBefore)
    }

    private func initializeVocabulary(in context: VocabularyStorageContext) throws {
        try InteractiveTestRuntime.initializeBundledVocabulary(
            supportDirectory: context.supportDirectory, defaults: context.userDefaults
        )
    }

    private func makeVocabularyContext() throws -> VocabularyStorageContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DalInteractiveVocabularyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "DalTests.InteractiveVocabulary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return VocabularyStorageContext(
            supportDirectory: directory,
            userDefaults: defaults,
            fileManager: .default,
            hotwordsDidChange: {},
            revealFile: { _ in }
        )
    }

    private func resolve(_ path: String?) throws -> URL? {
        try InteractiveTestRuntime.validatedSupportDirectory(
            bundleID: InteractiveTestRuntime.bundleIdentifier,
            bundleURL: candidate,
            environment: path.map { [InteractiveTestRuntime.rootEnvironmentKey: $0] } ?? [:]
        )
    }
}
