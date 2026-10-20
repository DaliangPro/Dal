import Foundation

/// Hotword storage with two independent stores:
/// - **Built-in file** (`builtin-hotwords.json`): defaults seeded only when the file is missing
/// - **User file** (`hotwords.json`): managed by Settings UI, auto-loaded on save
/// Both are merged at runtime (deduplicated, case-insensitive).
enum HotwordStorage {

    // MARK: - File paths

    static var builtinFileURL: URL { builtinFileURL(in: .production) }
    static func builtinFileURL(in context: VocabularyStorageContext) -> URL {
        context.supportDirectory.appendingPathComponent("builtin-hotwords.json")
    }

    static var userFileURL: URL { userFileURL(in: .production) }
    static func userFileURL(in context: VocabularyStorageContext) -> URL {
        context.supportDirectory.appendingPathComponent("hotwords.json")
    }

    // MARK: - Default hotwords (used for initial seeding)

    /// Common tech terms that ASR engines frequently mis-transcribe.
    /// 默认内置热词（2026-06-13 大梁老师精简定稿）：从原 ~150 删减到 52 个高频常用词,
    /// 作为项目默认、打包分发给他人时的初始内置热词。
    static let commonVocabularyV2: [String] = [
        // ── 常用品牌与本地生活 ──
        "Typeless", "食其家", "麦当劳", "肯德基", "星巴克", "瑞幸咖啡",
        "海底捞", "喜茶", "霸王茶姬", "美团", "饿了么", "携程",

        // ── 国内常用应用与平台 ──
        "微信", "企业微信", "飞书", "钉钉", "抖音", "小红书", "淘宝",
        "京东", "哔哩哔哩", "剪映",

        // ── 常用 AI 产品 ──
        "豆包", "通义千问", "Kimi",
    ]

    static let defaultHotwords: [String] = [
        // ── AI models & companies ──
        "Claude", "Claude Code", "GPT", "Gemini", "Anthropic", "OpenAI",
        "DeepSeek", "Qwen", "Perplexity", "Midjourney", "Stable Diffusion",
        "Hugging Face", "xAI", "Grok", "Groq", "Copilot", "ChatGPT",

        // ── AI coding tools ──
        "Cursor", "Codex", "vibe coding", "MCP",

        // ── AI frameworks & infra ──
        "LangChain", "Dify", "Coze", "Ollama", "ComfyUI", "OpenRouter",

        // ── AI concepts ──
        "LLM", "RAG", "LoRA", "agentic", "TTS", "ASR",

        // ── Dev tools ──
        "GitHub", "VS Code", "Docker", "npm", "pip",

        // ── Programming terms ──
        "API", "SDK", "token", "prompt", "webhook", "OAuth", "JSON", "DMG",

        // ── Frameworks & languages ──
        "Next.js", "SwiftUI",

        // ── Hardware ──
        "NVIDIA", "CUDA", "GPU", "TPU",
    ] + commonVocabularyV2

    // MARK: - Initialization

    private static let schemaVersionKey = "tf_hotwords_schema_version"
    private static let currentSchemaVersion = 2
    private static let legacyMigratedKey = "tf_hotwords_migrated_to_file_v2"
    private static let oldUDKey = "tf_hotwords"

    private enum MigrationError: Error {
        case unsupportedSchemaVersion(Int)
        case invalidLegacyPayload
        case corruptFile(URL, Error)
    }

    /// 内置文件只在缺失时 seed；后续默认词更新必须增加显式 schema migration。
    static func migrateIfNeeded(context: VocabularyStorageContext = .production) {
        do {
            try seedBuiltinIfMissing(context: context)
            try runSchemaMigrations(context: context)
        } catch {
            AppLogger.log("[HotwordStorage] 热词迁移失败: \(error.localizedDescription)")
        }
    }

    private static func seedBuiltinIfMissing(context: VocabularyStorageContext) throws {
        let url = builtinFileURL(in: context)
        switch JSONFileStore.read(
            [String].self,
            from: url,
            fileManager: context.fileManager
        ) {
        case .missing:
            try writeFile(defaultHotwords, to: url)
        case .value:
            return
        case .corrupt(let backupURL, let error):
            throw MigrationError.corruptFile(backupURL, error)
        }
    }

    private static func runSchemaMigrations(context: VocabularyStorageContext) throws {
        var version = context.userDefaults.integer(forKey: schemaVersionKey)
        if context.userDefaults.object(forKey: schemaVersionKey) == nil,
           context.userDefaults.bool(forKey: legacyMigratedKey) {
            // v2 布尔标记代表旧 UserDefaults 已经处理；桥接后不得重新导入并复活删除项。
            version = 1
            context.userDefaults.set(version, forKey: schemaVersionKey)
        }
        while version < currentSchemaVersion {
            let nextVersion = version + 1
            switch nextVersion {
            case 1:
                try migrateLegacyUserDefaults(context: context)
            case 2:
                try appendCommonVocabularyV2(context: context)
            default:
                throw MigrationError.unsupportedSchemaVersion(nextVersion)
            }
            context.userDefaults.set(nextVersion, forKey: schemaVersionKey)
            version = nextVersion
        }
    }

    /// 只追加本版本新增的通用词，不重置用户已调整过的内置文件。
    private static func appendCommonVocabularyV2(context: VocabularyStorageContext) throws {
        switch loadBuiltinResult(context: context) {
        case .value(let existing):
            var merged = existing
            var keys = Set(existing.map(normalizedKey))
            for word in commonVocabularyV2 {
                let key = normalizedKey(word)
                guard keys.insert(key).inserted else { continue }
                merged.append(word)
            }
            guard merged != existing else { return }
            try writeFile(merged, to: builtinFileURL(in: context))
            context.hotwordsDidChange()
        case .missing:
            try writeFile(defaultHotwords, to: builtinFileURL(in: context))
            context.hotwordsDidChange()
        case .corrupt(let backupURL, let error):
            throw MigrationError.corruptFile(backupURL, error)
        }
    }

    private static func migrateLegacyUserDefaults(context: VocabularyStorageContext) throws {
        let url = userFileURL(in: context)
        // 只有明确 missing 才允许导入；损坏文件必须先恢复，不能推进 schema 后丢失恢复源。
        switch loadResult(context: context) {
        case .missing:
            break
        case .value:
            return
        case .corrupt(let backupURL, let error):
            throw MigrationError.corruptFile(backupURL, error)
        }
        guard context.userDefaults.object(forKey: oldUDKey) != nil else { return }
        guard let raw = context.userDefaults.string(forKey: oldUDKey) else {
            throw MigrationError.invalidLegacyPayload
        }
        let oldWords = cleanedUniqueWords(raw.components(separatedBy: "\n"))

        // Filter out entries that duplicate built-in
        let builtinSet = Set(defaultHotwords.map(normalizedKey))
        let userOnly = oldWords.filter { !builtinSet.contains(normalizedKey($0)) }

        if !userOnly.isEmpty {
            try writeFile(userOnly, to: url)
        }
    }

    // MARK: - User file (Settings UI)

    static func loadResult(
        context: VocabularyStorageContext = .production
    ) -> JSONFileReadResult<[String]> {
        JSONFileStore.read(
            [String].self,
            from: userFileURL(in: context),
            fileManager: context.fileManager
        )
    }

    /// 运行时兼容边界：missing/corrupt 均只在内存降级为空，写入仍受恢复保护。
    static func load(context: VocabularyStorageContext = .production) -> [String] {
        switch loadResult(context: context) {
        case .value(let words):
            return words
        case .missing, .corrupt:
            return []
        }
    }

    static func save(
        _ words: [String],
        context: VocabularyStorageContext = .production
    ) throws {
        try writeFile(words, to: userFileURL(in: context))
        context.hotwordsDidChange()
    }

    // MARK: - Built-in file (seed once, preserve thereafter)

    static func loadBuiltin(context: VocabularyStorageContext = .production) -> [String] {
        switch loadBuiltinResult(context: context) {
        case .value(let words):
            return words
        case .missing, .corrupt:
            return []
        }
    }

    static func loadBuiltinResult(
        context: VocabularyStorageContext = .production
    ) -> JSONFileReadResult<[String]> {
        JSONFileStore.read(
            [String].self,
            from: builtinFileURL(in: context),
            fileManager: context.fileManager
        )
    }

    static func saveBuiltin(
        _ words: [String],
        context: VocabularyStorageContext = .production
    ) throws {
        try writeFile(words, to: builtinFileURL(in: context))
        context.hotwordsDidChange()
    }

    static func builtinCount(context: VocabularyStorageContext = .production) -> Int {
        loadBuiltin(context: context).count
    }

    /// Finder 批量编辑只打开用户文件，避免把内置 seed 文件误当长期编辑入口。
    static func revealUserInFinder(context: VocabularyStorageContext = .production) {
        let url = userFileURL(in: context)
        if !context.fileManager.fileExists(atPath: url.path) {
            if let backupURL = JSONFileStore.recoveryURL(for: url, fileManager: context.fileManager) {
                context.revealFile(backupURL)
                return
            }
            try? writeFile([], to: url)
        }
        context.revealFile(url)
    }

    static func reloadFromDisk(context: VocabularyStorageContext = .production) {
        context.hotwordsDidChange()
    }

    // MARK: - Effective (merge both stores)

    /// Returns user + built-in hotwords merged (deduplicated, case-insensitive).
    static func loadEffective(context: VocabularyStorageContext = .production) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        // 用户新增热词优先，避免被大批内置通用词稀释。
        appendUniqueCleaned(load(context: context), seen: &seen, result: &result)
        appendUniqueCleaned(loadBuiltin(context: context), seen: &seen, result: &result)

        return result
    }

    /// 下发 ASR 的热词总数上限（2026-06-13 用户拍板）：防一大批内置通用词稀释、
    /// 或超出火山引擎内联热词的数量限制。用户词优先，最终总数严格不超过上限。
    static let asrHotwordLimit = 100

    struct EffectiveSelection: Equatable, Sendable {
        let words: [String]
        let userCount: Int
        let truncatedUserCount: Int
    }

    static func loadEffectiveForASR(
        limit: Int = asrHotwordLimit,
        context: VocabularyStorageContext = .production
    ) -> EffectiveSelection {
        let safeLimit = max(0, limit)
        var seen = Set<String>()
        var userWords: [String] = []
        appendUniqueCleaned(load(context: context), seen: &seen, result: &userWords)
        var builtinWords: [String] = []
        appendUniqueCleaned(loadBuiltin(context: context), seen: &seen, result: &builtinWords)

        let selectedUsers = Array(userWords.prefix(safeLimit))
        let truncatedUserCount = userWords.count - selectedUsers.count
        let remaining = safeLimit - selectedUsers.count
        let words = selectedUsers + Array(builtinWords.prefix(remaining))
        return EffectiveSelection(
            words: words,
            userCount: selectedUsers.count,
            truncatedUserCount: truncatedUserCount
        )
    }

    // MARK: - File I/O helpers

    private static func writeFile(_ words: [String], to url: URL) throws {
        try JSONFileStore.writeOrThrow(words, to: url)
    }

    private static func cleanedUniqueWords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        appendUniqueCleaned(words, seen: &seen, result: &result)
        return result
    }

    private static func appendUniqueCleaned(
        _ words: [String],
        seen: inout Set<String>,
        result: inout [String]
    ) {
        for word in words {
            let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let key = normalizedKey(cleaned)
            guard seen.insert(key).inserted else { continue }
            result.append(cleaned)
        }
    }

    private static func normalizedKey(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
