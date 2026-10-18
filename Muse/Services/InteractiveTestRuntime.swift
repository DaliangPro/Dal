import Foundation

/// 独立签名测试包的启动配置；日常 Bundle 不接受这些覆盖。
enum InteractiveTestRuntime {
    static let bundleIdentifier = "pro.daliang.muse.interactive-test"
    static let rootEnvironmentKey = "MUSE_INTERACTIVE_TEST_ROOT"

    static var isEnabled: Bool { Bundle.main.bundleIdentifier == bundleIdentifier }

    /// 真实输入框验收使用日常 Bundle 及现有授权，只增加可点击录音入口。
    /// 不替换识别结果、Provider、设置或数据目录，默认启动不显示面板。
    static var isLiveLearningAcceptanceEnabled: Bool {
        allowsLiveLearningAcceptance(bundleID: Bundle.main.bundleIdentifier, arguments: CommandLine.arguments)
    }

    static func allowsLiveLearningAcceptance(bundleID: String?, arguments: [String]) -> Bool {
        bundleID == "pro.daliang.muse" && arguments.contains("--live-learning-acceptance")
    }

    /// 与日常快捷键相同的能力解析和已保存模式选择，不使用静态默认附加要求。
    static func liveLearningMode(_ requested: ProcessingMode, modes: [ProcessingMode], provider: ASRProvider) -> ProcessingMode {
        let resolved = ASRProviderRegistry.resolvedMode(for: requested, provider: provider)
        let stored = modes.first { $0.id == resolved.id } ?? resolved
        return VoiceInputModes.resolve(stored, in: modes)
    }

    /// 必须先于 AppDelegate 创建数据库与词库执行。配置错误时由入口直接退出。
    static func bootstrap() throws {
        guard let root = try validatedSupportDirectory(
            bundleID: Bundle.main.bundleIdentifier,
            bundleURL: Bundle.main.bundleURL,
            environment: ProcessInfo.processInfo.environment
        ) else { return }
        try ensureSupportDirectoryExists(at: root)
        UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        try initializeBundledVocabulary(supportDirectory: root, defaults: .standard)
    }

    /// 路径校验通过后，首次启动创建目录；复开只复用目录，不改动其中的数据。
    static func ensureSupportDirectoryExists(at root: URL) throws {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw ConfigurationError.invalidRoot }
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    /// 仅补齐正常产品自带的两份内置词库，不执行历史迁移或触发词表同步。
    /// 统一术语运行时会从这些文件读取默认纠正，无需另建测试专用规则。
    static func initializeBundledVocabulary(supportDirectory: URL, defaults: UserDefaults) throws {
        let context = VocabularyStorageContext(
            supportDirectory: supportDirectory,
            userDefaults: defaults,
            fileManager: .default,
            hotwordsDidChange: {},
            revealFile: { _ in }
        )
        switch HotwordStorage.loadBuiltinResult(context: context) {
        case .missing:
            try HotwordStorage.saveBuiltin(HotwordStorage.defaultHotwords, context: context)
        case .value:
            break
        case .corrupt(let backupURL, _):
            throw TerminologyRepositoryError.recoveryRequired(backupURL)
        }
        switch SnippetStorage.loadBuiltinResult(context: context) {
        case .missing:
            try SnippetStorage.saveBuiltin(SnippetStorage.defaultSnippets, context: context)
        case .value:
            break
        case .corrupt(let backupURL, _):
            throw TerminologyRepositoryError.recoveryRequired(backupURL)
        }
    }

    static var supportDirectory: URL {
        do {
            guard let root = try validatedSupportDirectory(
                bundleID: Bundle.main.bundleIdentifier,
                bundleURL: Bundle.main.bundleURL,
                environment: ProcessInfo.processInfo.environment
            ) else { preconditionFailure("仅独立交互测试包可访问测试目录") }
            return root
        } catch {
            preconditionFailure("交互测试目录无效：\(error.localizedDescription)")
        }
    }

    /// 数据只允许放在测试 App 旁的 test-data；拒绝缺省、相对路径和符号链接。
    static func validatedSupportDirectory(
        bundleID: String?, bundleURL: URL, environment: [String: String]
    ) throws -> URL? {
        guard bundleID == bundleIdentifier else { return nil }
        guard let path = environment[rootEnvironmentKey], path.hasPrefix("/") else {
            throw ConfigurationError.invalidRoot
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let parent = bundleURL.deletingLastPathComponent().standardizedFileURL
        let expected = parent.appendingPathComponent("test-data", isDirectory: true)
        guard bundleURL.pathExtension == "app", root == expected else {
            throw ConfigurationError.invalidRoot
        }
        // Foundation 会保留 /tmp 等系统别名，逐级检查实际链接以免漏过路径重定向。
        var component = root
        while component.path != "/" {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: component.path)) != nil {
                throw ConfigurationError.invalidRoot
            }
            component.deleteLastPathComponent()
        }
        return root
    }

    /// 当前实录对照只使用已配置的云服务，覆盖仅存于测试进程内。
    static var preferences: [String: Any] {
        [
            DefaultsKeys.selectedASRProvider: ASRProvider.volcano.rawValue,
            DefaultsKeys.selectedLLMProvider: LLMProvider.deepseek.rawValue,
            DefaultsKeys.voicePolishModelOverride: "deepseek-flash",
            DefaultsKeys.voicePolishContextLevel: WritingContextLevel.metadataOnly.rawValue,
            DefaultsKeys.voicePolishPersonalizationEnabled: false,
            DefaultsKeys.voicePolishTerminologyLearningEnabled: false,
            DefaultsKeys.voicePolishRecentInputContextEnabled: false,
            DefaultsKeys.hasCompletedSetup: true,
            DefaultsKeys.didInitialLoginItemSetup: true,
            DefaultsKeys.showDockIcon: false,
            DefaultsKeys.qwen3FinalEnabled: false,
            DefaultsKeys.sensevoiceEnabled: false,
        ]
    }

    enum ConfigurationError: LocalizedError {
        case invalidRoot

        var errorDescription: String? {
            "交互测试必须显式设置 MUSE_INTERACTIVE_TEST_ROOT 为测试 App 旁的 test-data 绝对路径，且路径不能含符号链接。"
        }
    }
}
