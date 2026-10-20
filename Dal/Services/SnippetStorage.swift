import Foundation
import os

/// Snippet replacement with two independent stores:
/// - **Built-in file** (`builtin-snippets.json`): defaults seeded only when the file is missing
/// - **User file** (`snippets.json`): managed by Settings UI, auto-loaded on save
/// Both are merged at runtime; user entries override built-in on trigger conflict.
enum SnippetStorage {
    static let draftTriggerPrefix = "__muse_draft__:"
    static let draftTriggerDisplayTitle = L("待补触发词", "Draft trigger")

    // MARK: - File paths

    static var builtinFileURL: URL { builtinFileURL(in: .production) }
    static func builtinFileURL(in context: VocabularyStorageContext) -> URL {
        context.supportDirectory.appendingPathComponent("builtin-snippets.json")
    }

    static var userFileURL: URL { userFileURL(in: .production) }
    static func userFileURL(in context: VocabularyStorageContext) -> URL {
        context.supportDirectory.appendingPathComponent("snippets.json")
    }

    // MARK: - Codable model

    private struct Entry: Codable {
        let trigger: String
        let replacement: String
    }

    // MARK: - Default snippets (used for initial seeding)

    /// Default ASR correction mappings. Seeded into builtin-snippets.json on first launch.
    /// Triggers are matched case-insensitively and space-insensitively via `buildFlexPattern`.
    ///
    /// Verified against: Volcengine Seed ASR 2.0, Qwen3-ASR 0.6B/1.7B, SenseVoice-Small.
    static let commonCorrectionsV2: [(trigger: String, value: String)] = [
        ("Type less", "Typeless"),
        ("食奇家", "食其家"),
        ("时其家", "食其家"),
        ("食齐家", "食其家"),
    ]

    static let defaultSnippets: [(trigger: String, value: String)] = [

        // ── vibe coding (ASR 几乎必错) ──
        ("web coding",      "vibe coding"),
        ("webb coding",     "vibe coding"),
        ("vab coding",      "vibe coding"),
        ("vabe coding",     "vibe coding"),
        ("vibes coding",    "vibe coding"),
        ("Vipcoding",       "vibe coding"),
        ("vipe coding",     "vibe coding"),
        ("vb coding",       "vibe coding"),
        ("vib coding",      "vibe coding"),
        ("va coding",       "vibe coding"),
        ("vivcoding",       "vibe coding"),
        ("wife coding",     "vibe coding"),

        // ── Claude ──
        ("Cloud Code",      "Claude Code"),
        ("clod",            "Claude"),
        ("clawed",          "Claude"),
        ("claud",           "Claude"),

        // ── Anthropic ──
        ("Asthropic",       "Anthropic"),
        ("Anthropropic",    "Anthropic"),
        ("Anthropick",      "Anthropic"),
        ("Anthrobic",       "Anthropic"),
        ("and tropic",      "Anthropic"),
        ("an tropic",       "Anthropic"),
        ("anthrophic",      "Anthropic"),

        // ── ChatGPT ──
        ("chat GPT",        "ChatGPT"),

        // ── DeepSeek ──
        ("deepse",          "DeepSeek"),
        ("deep sick",       "DeepSeek"),
        ("deep seek",       "DeepSeek"),
        ("deep sec",        "DeepSeek"),

        // ── Gemini ──
        ("jiminy",          "Gemini"),
        ("gem any",         "Gemini"),

        // ── Qwen ──
        ("Queen三",         "Qwen3"),
        ("Queen 三",        "Qwen3"),
        ("Queen3",          "Qwen3"),
        ("Queen 3",         "Qwen3"),
        ("qun三",           "Qwen3"),
        ("Qu3",             "Qwen3"),
        ("Queen三点五",     "Qwen3.5"),
        ("Queen 3.5",       "Qwen3.5"),
        ("quin三点五",      "Qwen3.5"),
        ("qun三点五",       "Qwen3.5"),
        ("quin三点",        "Qwen3"),

        // ── Grok ──
        ("grock",           "Grok"),

        // ── Llama / Ollama ──
        ("ELMA",            "Llama"),
        ("OELMA",           "Ollama"),

        // ── Midjourney / Copilot / Perplexity ──
        ("mid journey",     "Midjourney"),
        ("co pilot",        "Copilot"),
        ("perplex city",    "Perplexity"),

        // ── Hugging Face ──
        ("hugging phase",   "Hugging Face"),
        ("hug and face",    "Hugging Face"),

        // ── Codex ──
        ("codecs",          "Codex"),
        ("CodeX",           "Codex"),
        ("Codec",           "Codex"),

        // ── JSON ──
        ("Jason",           "JSON"),

        // ── fine-tuning ──
        ("finight tuning",  "fine-tuning"),
        ("find tuning",     "fine-tuning"),
        ("fine tuning",     "fine-tuning"),
        ("fine tune",       "fine-tune"),

        // ── LoRA / QLoRA ──
        ("lore a",          "LoRA"),
        ("lor a",           "LoRA"),
        ("Q lore a",        "QLoRA"),

        // ── agentic ──
        ("a genetic",       "agentic"),
        ("a gentic",        "agentic"),

        // ── multimodal / multi-agent ──
        ("multi modal",     "multimodal"),
        ("multi agent",     "multi-agent"),
        ("multiag",         "multi-agent"),

        // ── few-shot / zero-shot / in-context learning ──
        ("few shot",        "few-shot"),
        ("zero shot",       "zero-shot"),
        ("in context learning", "in-context learning"),

        // ── embedding / context window ──
        ("imbedding",       "embedding"),
        ("contexwin",       "context window"),
        ("context win",     "context window"),

        // ── LangChain / LlamaIndex ──
        ("long chain",      "LangChain"),
        ("long train",      "LangChain"),
        ("llama index",     "LlamaIndex"),
        ("lama index",      "LlamaIndex"),

        // ── AI frameworks (CrewAI, AutoGen, ComfyUI, ControlNet) ──
        ("crew AI",         "CrewAI"),
        ("auto gen",        "AutoGen"),
        ("auto Jen",        "AutoGen"),
        ("comfy UI",        "ComfyUI"),
        ("control net",     "ControlNet"),

        // ── AI coding tools ──
        ("wind surf",       "Windsurf"),
        ("Klein",           "Cline"),
        ("C line",          "Cline"),
        ("aid her",         "Aider"),
        ("open router",     "OpenRouter"),
        ("light LLM",       "LiteLLM"),
        ("lite LLM",        "LiteLLM"),
        ("VLLM",            "vLLM"),
        ("llama CPP",       "llama.cpp"),
        ("curser",          "Cursor"),
        ("克色",            "Cursor"),

        // ── Dev tools ──
        ("get hub",         "GitHub"),
        ("git hub",         "GitHub"),
        ("VS code",         "VS Code"),
        ("Kubanetes",       "Kubernetes"),
        ("Kubenetes",       "Kubernetes"),
        ("Nextjs",          "Next.js"),
        ("type script",     "TypeScript"),
        ("typepescript",    "TypeScript"),
        ("graph QL",        "GraphQL"),
        ("web socket",      "WebSocket"),
        ("pinecom",         "Pinecone"),

        // ── Infra & formats ──
        ("DM g",            "DMG"),
        ("verse cell",      "Vercel"),
        ("verse L",         "Vercel"),
        ("super base",      "Supabase"),
        ("cloud flare",     "Cloudflare"),
        ("cloud flair",     "Cloudflare"),
        ("N video",         "NVIDIA"),
        ("onyx",            "ONNX"),
    ] + commonCorrectionsV2

    // MARK: - Initialization

    private static let schemaVersionKey = "tf_snippets_schema_version"
    private static let currentSchemaVersion = 2
    private static let legacyMigratedKey = "tf_snippets_migrated_to_file_v2"
    private static let oldUDKey = "tf_snippets"

    private enum MigrationError: Error {
        case unsupportedSchemaVersion(Int)
        case invalidLegacyPayload
        case corruptFile(URL, Error)
    }

    /// 内置文件只在缺失时 seed；后续默认规则更新必须增加显式 schema migration。
    static func migrateIfNeeded(context: VocabularyStorageContext = .production) {
        do {
            try seedBuiltinIfMissing(context: context)
            try runSchemaMigrations(context: context)
        } catch {
            AppLogger.log("[SnippetStorage] 替换规则迁移失败: \(error.localizedDescription)")
        }
    }

    private static func seedBuiltinIfMissing(context: VocabularyStorageContext) throws {
        let url = builtinFileURL(in: context)
        switch JSONFileStore.read(
            [Entry].self,
            from: url,
            fileManager: context.fileManager
        ) {
        case .missing:
            try writeFile(defaultSnippets, to: url)
            invalidateCache()
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
                try appendCommonCorrectionsV2(context: context)
            default:
                throw MigrationError.unsupportedSchemaVersion(nextVersion)
            }
            context.userDefaults.set(nextVersion, forKey: schemaVersionKey)
            version = nextVersion
        }
    }

    /// 只追加本版本新增的高置信纠正规则，保留既有内置与用户自定义内容。
    private static func appendCommonCorrectionsV2(context: VocabularyStorageContext) throws {
        switch loadBuiltinResult(context: context) {
        case .value(let existing):
            var merged = existing
            var keys = Set(existing.map(pairKey))
            for correction in commonCorrectionsV2 {
                let key = pairKey(correction)
                guard keys.insert(key).inserted else { continue }
                merged.append(correction)
            }
            guard merged.map(pairKey) != existing.map(pairKey) else { return }
            try writeFile(merged, to: builtinFileURL(in: context))
            invalidateCache()
        case .missing:
            try writeFile(defaultSnippets, to: builtinFileURL(in: context))
            invalidateCache()
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
        guard let data = context.userDefaults.data(forKey: oldUDKey),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data),
              pairs.allSatisfy({ $0.count == 2 })
        else {
            throw MigrationError.invalidLegacyPayload
        }

        let oldSnippets = pairs.map { pair in
            (trigger: pair[0], value: pair[1])
        }

        // Filter out entries that duplicate built-in
        let builtinKeys = Set(defaultSnippets.map(pairKey))
        let userOnly = cleanedUniqueSnippets(oldSnippets)
            .filter { !builtinKeys.contains(pairKey($0)) }

        if !userOnly.isEmpty {
            try writeFile(userOnly, to: url)
            invalidateCache()
        }
    }

    // MARK: - User file (Settings UI)

    static func loadResult(
        context: VocabularyStorageContext = .production
    ) -> JSONFileReadResult<[(trigger: String, value: String)]> {
        JSONFileStore.read(
            [Entry].self,
            from: userFileURL(in: context),
            fileManager: context.fileManager
        ).map { entries in
            entries.map { (trigger: $0.trigger, value: $0.replacement) }
        }
    }

    /// 运行时兼容边界：missing/corrupt 均只在内存降级为空，写入仍受恢复保护。
    static func load(context: VocabularyStorageContext = .production) -> [(trigger: String, value: String)] {
        switch loadResult(context: context) {
        case .value(let snippets):
            return snippets
        case .missing, .corrupt:
            return []
        }
    }

    static func save(
        _ snippets: [(trigger: String, value: String)],
        context: VocabularyStorageContext = .production
    ) throws {
        try writeFile(snippets, to: userFileURL(in: context))
        invalidateCache()
    }

    /// 用户明确配置的错词纠正。下发给支持请求级 correct_words 的 ASR，
    /// 同时保留 applyEffective 的本地最终兜底，保证云端不支持时行为不变。
    static func userCorrectionWords(
        context: VocabularyStorageContext = .production
    ) -> [String: String] {
        var corrections: [String: String] = [:]
        for snippet in cleanedUniqueSnippets(load(context: context))
            where !isDraftTrigger(snippet.trigger) {
            corrections[snippet.trigger] = snippet.value
        }
        return corrections
    }

    // MARK: - Built-in file (seed once, preserve thereafter)

    static func loadBuiltin(
        context: VocabularyStorageContext = .production
    ) -> [(trigger: String, value: String)] {
        switch loadBuiltinResult(context: context) {
        case .value(let snippets):
            return snippets
        case .missing, .corrupt:
            return []
        }
    }

    static func loadBuiltinResult(
        context: VocabularyStorageContext = .production
    ) -> JSONFileReadResult<[(trigger: String, value: String)]> {
        JSONFileStore.read(
            [Entry].self,
            from: builtinFileURL(in: context),
            fileManager: context.fileManager
        ).map { entries in
            entries.map { (trigger: $0.trigger, value: $0.replacement) }
        }
    }

    static func saveBuiltin(
        _ snippets: [(trigger: String, value: String)],
        context: VocabularyStorageContext = .production
    ) throws {
        try writeFile(snippets, to: builtinFileURL(in: context))
        invalidateCache()
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
        invalidateCache()
    }

    // MARK: - Compiled cache

    private struct CompiledRule {
        let regex: NSRegularExpression
        let template: String  // pre-escaped replacement
    }

    /// Cached compiled rules. Rebuilt only when snippets change.
    /// REPAIR_PLAN J1：写侧在主线程（设置页保存触发 invalidateCache），读侧在
    /// RecognitionSession actor 线程（听写热路径 applyEffective），必须加锁，
    /// 否则 COW 数组被并发重置/遍历会撕裂崩溃。
    /// uncheckedState：CompiledRule 持有 NSRegularExpression（不可变、线程安全，
    /// 但无 Sendable 标注），锁本身保证独占访问。
    private struct CachedRuleSet {
        let builtinURL: URL
        let userURL: URL
        let rules: [CompiledRule]
    }

    private struct RuleCacheState {
        var generation = 0
        var cached: CachedRuleSet?
    }

    private static let cachedRules = OSAllocatedUnfairLock<RuleCacheState>(
        uncheckedState: RuleCacheState()
    )

    /// Call after saving either file to force recompilation on next apply.
    static func invalidateCache() {
        cachedRules.withLock {
            $0.generation &+= 1
            $0.cached = nil
        }
    }

    static func isDraftTrigger(_ trigger: String) -> Bool {
        trigger.hasPrefix(draftTriggerPrefix)
    }

    static func displayTrigger(_ trigger: String) -> String {
        isDraftTrigger(trigger) ? draftTriggerDisplayTitle : trigger
    }

    private static func compiledRules(context: VocabularyStorageContext) -> [CompiledRule] {
        let builtinURL = builtinFileURL(in: context)
        let userURL = userFileURL(in: context)
        let snapshot = cachedRules.withLock { state -> (rules: [CompiledRule]?, generation: Int) in
            let rules: [CompiledRule]?
            if let cached = state.cached,
               cached.builtinURL == builtinURL,
               cached.userURL == userURL {
                rules = cached.rules
            } else {
                rules = nil
            }
            return (rules, state.generation)
        }
        if let rules = snapshot.rules { return rules }
        // 编译在锁外进行（含文件 IO，不宜持 unfair lock）；
        // 两个线程同时未命中会各编译一遍，结果幂等，后写覆盖无害。
        let builtinSnippets = cleanedUniqueSnippets(loadBuiltin(context: context))
        let userSnippets = cleanedUniqueSnippets(load(context: context))
        let userTriggers = Set(userSnippets.map { normalizedTriggerKey($0.trigger) })
        let effectiveBuiltin = builtinSnippets.filter {
            !userTriggers.contains(normalizedTriggerKey($0.trigger))
        }
        let allSnippets = effectiveBuiltin + userSnippets

        let rules = allSnippets.compactMap { snippet -> CompiledRule? in
            guard !isDraftTrigger(snippet.trigger) else { return nil }
            let pattern = buildFlexPattern(snippet.trigger)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return CompiledRule(regex: regex, template: NSRegularExpression.escapedTemplate(for: snippet.value))
        }
        cachedRules.withLock { state in
            guard state.generation == snapshot.generation else { return }
            state.cached = CachedRuleSet(
                builtinURL: builtinURL,
                userURL: userURL,
                rules: rules
            )
        }
        return rules
    }

    // MARK: - Apply (merge both stores)

    /// Apply built-in + user snippets. User entries override built-in on trigger conflict.
    static func applyEffective(
        to text: String,
        context: VocabularyStorageContext = .production
    ) -> String {
        var result = text
        for rule in compiledRules(context: context) {
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template
            )
        }
        return result
    }

    // MARK: - Pattern building

    /// Builds a regex that matches the trigger case-insensitively and space-insensitively.
    /// Strips all whitespace from trigger, then inserts `\s*` between each character.
    /// Uses ASCII-only word boundaries (not `\b`) so CJK/Latin boundaries work correctly.
    private static func buildFlexPattern(_ trigger: String) -> String {
        let chars = trigger.filter { !$0.isWhitespace }
        guard !chars.isEmpty else { return NSRegularExpression.escapedPattern(for: trigger) }
        let core = chars.map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s*")
        return "(?<![a-zA-Z0-9])" + core + "(?![a-zA-Z0-9])"
    }

    // MARK: - File I/O helpers

    private static func writeFile(_ snippets: [(trigger: String, value: String)], to url: URL) throws {
        let entries = snippets.map { Entry(trigger: $0.trigger, replacement: $0.value) }
        try JSONFileStore.writeOrThrow(entries, to: url)
    }

    private static func cleanedUniqueSnippets(
        _ snippets: [(trigger: String, value: String)]
    ) -> [(trigger: String, value: String)] {
        var seen = Set<String>()
        var result: [(trigger: String, value: String)] = []
        for snippet in snippets {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = snippet.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty, !value.isEmpty else { continue }
            let key = normalizedTriggerKey(trigger)
            guard seen.insert(key).inserted else { continue }
            result.append((trigger: trigger, value: value))
        }
        return result
    }

    private static func normalizedTriggerKey(_ trigger: String) -> String {
        trigger.filter { !$0.isWhitespace }.lowercased()
    }

    private static func pairKey(_ snippet: (trigger: String, value: String)) -> String {
        let trigger = snippet.trigger
            .filter { !$0.isWhitespace }
            .lowercased()
        let value = snippet.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trigger)\t\(value)"
    }
}
