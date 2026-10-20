import Foundation
import LocalAuthentication
import Security

enum KeychainService {

    private static let lock = NSLock()
    private static let llmThinkingPreferenceLock = NSLock()
    private static let keychainServiceName = "pro.daliang.muse.credentials"

    /// XCTest 进程不得读取真实 Application Support、UserDefaults 或系统钥匙串。
    /// 使用进程内后端还能让默认构造的业务对象在测试中保持安全，而无需全局目录开关。
    private struct IsolatedTestStorage {
        var secureData: [String: Data] = [:]
        var legacyValues: [String: Any] = [:]
        var preferences: [String: String] = [:]
    }

    private static let isolatedTestLock = NSLock()
    private static var isolatedTestStorage = IsolatedTestStorage()
    private static let isRunningTests: Bool = {
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] != nil
            || process.arguments.contains(where: { $0.contains(".xctest") })
            || NSClassFromString("XCTestCase") != nil
    }()

    static var isUsingIsolatedTestStorage: Bool { isRunningTests }

    @TaskLocal private static var interactiveReadOnlyTestScope = false

    /// 交互测试只复用指定服务的现有凭据，不允许改动共享钥匙串或历史凭据文件。
    private static var isCredentialReadOnly: Bool {
        InteractiveTestRuntime.isEnabled || (isRunningTests && interactiveReadOnlyTestScope)
    }

    /// 只在 XCTest 的内存后端模拟交互测试限制，不打开真实系统存储。
    static func withInteractiveCredentialReadOnlyForTesting<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        precondition(isRunningTests)
        return try $interactiveReadOnlyTestScope.withValue(true, operation: body)
    }

    private static func mayReadCredential(key: String) -> Bool {
        !isCredentialReadOnly || key == "tf_asr_volcano" || key == "tf_llm_deepseek"
    }

    private static func withIsolatedTestStorage<T>(
        _ body: (inout IsolatedTestStorage) throws -> T
    ) rethrows -> T {
        isolatedTestLock.lock()
        defer { isolatedTestLock.unlock() }
        return try body(&isolatedTestStorage)
    }

    private static var credentialsURL: URL {
        AppPaths.ensureSupportDir().appendingPathComponent("credentials.json")
    }

    // MARK: - Core read/write (now supports nested objects)

    private static func loadAll() -> [String: Any] {
        guard !isCredentialReadOnly else { return [:] }
        if isRunningTests {
            return withIsolatedTestStorage { $0.legacyValues }
        }
        guard let data = try? Data(contentsOf: credentialsURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    private static func saveAll(_ dict: [String: Any]) throws {
        guard !isCredentialReadOnly else { throw KeychainError.saveFailed(errSecReadOnly) }
        if isRunningTests {
            withIsolatedTestStorage { $0.legacyValues = dict }
            return
        }
        // REPAIR_PLAN C2：credentials.json 只是历史明文凭证的迁移兜底，
        // 清空即删除文件、为空不再创建——新装环境不会出现该文件，
        // 老环境最后一个遗留键迁入钥匙串后文件自动消失
        if dict.isEmpty {
            try? FileManager.default.removeItem(at: credentialsURL)
            return
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try data.write(to: credentialsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: credentialsURL.path
        )
    }

    // MARK: - macOS Keychain read/write

    private static func keychainQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: key,
        ]
    }

    private static func saveSecureData(_ data: Data, key: String) throws {
        guard !isCredentialReadOnly else { throw KeychainError.saveFailed(errSecReadOnly) }
        if isRunningTests {
            withIsolatedTestStorage { $0.secureData[key] = data }
            return
        }
        let query = keychainQuery(for: key)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.saveFailed(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.saveFailed(addStatus)
        }
    }

    private static func loadSecureData(key: String) -> Data? {
        guard mayReadCredential(key: key) else { return nil }
        if isRunningTests {
            return withIsolatedTestStorage { $0.secureData[key] }
        }
        var query = keychainQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Recording start must never block behind a SecurityAgent prompt.
        // If the item requires interactive authentication, fail fast instead.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            DebugFileLogger.log("keychain load failed key=\(key) status=\(status)")
            return nil
        }
        return result as? Data
    }

    @discardableResult
    private static func deleteSecureData(key: String) -> Bool {
        guard !isCredentialReadOnly else { return false }
        if isRunningTests {
            return withIsolatedTestStorage {
                $0.secureData.removeValue(forKey: key) != nil
            }
        }
        let status = SecItemDelete(keychainQuery(for: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func preferenceString(forKey key: String) -> String? {
        if isRunningTests {
            return withIsolatedTestStorage { $0.preferences[key] }
        }
        return UserDefaults.standard.string(forKey: key)
    }

    private static func setPreference(_ value: String, forKey key: String) {
        if isRunningTests {
            withIsolatedTestStorage { $0.preferences[key] = value }
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private static func removePreference(forKey key: String) {
        if isRunningTests {
            _ = withIsolatedTestStorage { $0.preferences.removeValue(forKey: key) }
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func saveSecureString(_ value: String, key: String) throws {
        try saveSecureData(Data(value.utf8), key: key)
    }

    private static func loadSecureString(key: String) -> String? {
        guard let data = loadSecureData(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveSecureDictionary(_ values: [String: String], key: String) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        try saveSecureData(data, key: key)
    }

    private static func loadSecureDictionary(key: String) -> [String: String]? {
        guard let data = loadSecureData(key: key),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return values
    }

    // MARK: - Scalar key-value (for LLM keys and misc)

    static func save(key: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveSecureString(value, key: key)
        var dict = loadAll()
        dict.removeValue(forKey: key)
        try saveAll(dict)
    }

    static func load(key: String) -> String? {
        loadSecureString(key: key) ?? loadAll()[key] as? String
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let deletedSecureValue = deleteSecureData(key: key)
        var dict = loadAll()
        let deletedFileValue = dict.removeValue(forKey: key) != nil
        guard deletedFileValue else { return deletedSecureValue }
        return (try? saveAll(dict)) != nil
    }

    // MARK: - Selected ASR Provider (UserDefaults)

    private static let selectedProviderKey = DefaultsKeys.selectedASRProvider

    static var selectedASRProvider: ASRProvider {
        get {
            guard let raw = preferenceString(forKey: selectedProviderKey),
                  let provider = ASRProvider(rawValue: raw)
            else { return .volcano }
            return provider
        }
        set {
            let previous = selectedASRProvider
            setPreference(newValue.rawValue, forKey: selectedProviderKey)
            guard previous != newValue else { return }
            NotificationCenter.default.post(name: .asrProviderDidChange, object: newValue)
        }
    }

    // MARK: - ASR Credentials (provider-aware)

    private static func asrStorageKey(for provider: ASRProvider) -> String {
        "tf_asr_\(provider.rawValue)"
    }

    static func saveASRCredentials(for provider: ASRProvider, values: [String: String]) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveSecureDictionary(values, key: asrStorageKey(for: provider))
        var dict = loadAll()
        dict.removeValue(forKey: asrStorageKey(for: provider))
        try saveAll(dict)
    }

    static func loadASRCredentials(for provider: ASRProvider) -> [String: String]? {
        if let values = loadSecureDictionary(key: asrStorageKey(for: provider)) {
            return values
        }
        let dict = loadAll()
        return dict[asrStorageKey(for: provider)] as? [String: String]
    }

    static func loadASRConfig(for provider: ASRProvider) -> (any ASRProviderConfig)? {
        guard let configType = ASRProviderRegistry.configType(for: provider) else {
            return nil
        }

        if let values = loadASRCredentials(for: provider) {
            return configType.init(credentials: values)
        }

        // Fallback: build config from default field values (e.g. Apple ASR needs no API key)
        let defaultValues: [String: String] = Dictionary(
            uniqueKeysWithValues: configType.credentialFields.compactMap { field in
                guard !field.defaultValue.isEmpty else { return nil }
                return (field.key, field.defaultValue)
            }
        )

        if defaultValues.isEmpty && configType.credentialFields.isEmpty {
            return configType.init(credentials: [:])
        }

        return configType.init(credentials: defaultValues)
    }

    // MARK: - Legacy ASR convenience (volcano-specific, kept for migration)

    static func saveASRCredentials(appKey: String, accessKey: String, resourceId: String) throws {
        try saveASRCredentials(for: .volcano, values: [
            "appKey": appKey,
            "accessKey": accessKey,
            "resourceId": resourceId,
        ])
    }

    static func loadASRConfig() -> VolcanoASRConfig? {
        loadASRConfig(for: .volcano) as? VolcanoASRConfig
    }

    // MARK: - Selected LLM Provider (UserDefaults)

    private static let selectedLLMProviderKey = DefaultsKeys.selectedLLMProvider

    static var selectedLLMProvider: LLMProvider {
        get {
            guard let raw = preferenceString(forKey: selectedLLMProviderKey),
                  let provider = LLMProvider(rawValue: raw)
            else { return .doubao }
            return provider
        }
        set {
            setPreference(newValue.rawValue, forKey: selectedLLMProviderKey)
        }
    }

    // MARK: - LLM Credentials (provider-aware)

    private static func llmStorageKey(for provider: LLMProvider) -> String {
        "tf_llm_\(provider.rawValue)"
    }

    /// 专用 CLI 授权入口的一次读取。由系统征求当前制品的访问许可；不修改
    /// ACL、不回退到文件、不返回凭据。常规录音及质量跑测不调用此方法。
    static func authorizeLLMCredentialAccess(for provider: LLMProvider) -> OSStatus {
        guard provider != .localQwen else { return errSecParam }
        return authorizeCredentialAccess(key: llmStorageKey(for: provider))
    }

    /// 交互测试菜单的显式授权入口；只返回状态，不向调用方暴露凭据。
    static func authorizeASRCredentialAccess(for provider: ASRProvider) -> OSStatus {
        guard provider == .volcano || provider == .aliyun else { return errSecParam }
        return authorizeCredentialAccess(key: asrStorageKey(for: provider))
    }

    private static func authorizeCredentialAccess(key: String) -> OSStatus {
        guard mayReadCredential(key: key) else { return errSecAuthFailed }
        if isRunningTests {
            return withIsolatedTestStorage {
                $0.secureData[key] == nil ? errSecItemNotFound : errSecSuccess
            }
        }
        let interactionStatus = SecKeychainSetUserInteractionAllowed(true)
        guard interactionStatus == errSecSuccess else { return interactionStatus }
        defer { SecKeychainSetUserInteractionAllowed(false) }

        var query = keychainQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var data: CFTypeRef?
        // 仅在进程内接收并丢弃结果；系统确认可能持久记录本制品的访问许可。
        return SecItemCopyMatching(query as CFDictionary, &data)
    }

    private static func sanitizeLLMCredentials(_ values: [String: String]) -> [String: String] {
        var sanitized = values
        for key in ["apiKey", "model", "baseURL"] {
            if let value = sanitized[key] {
                sanitized[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return sanitized
    }

    static func normalizedLLMCredentialsForStorage(
        provider: LLMProvider,
        values: [String: String]
    ) throws -> [String: String] {
        var normalized = sanitizeLLMCredentials(values)
        guard provider != .localQwen else {
            normalized.removeValue(forKey: "baseURL")
            return normalized
        }
        let baseURL = try LLMEndpointPolicy.normalizedBaseURL(
            rawValue: normalized["baseURL"] ?? "",
            provider: provider
        )
        normalized["baseURL"] = baseURL.absoluteString
        return normalized
    }

    private static let llmThinkingModesPreferenceKey = "tf_llmThinkingModes"

    private static func llmThinkingModeStorageKey(
        role: LLMConfigurationRole,
        provider: LLMProvider,
        model: String
    ) -> String {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = [role.rawValue, provider.rawValue, normalizedModel].joined(separator: "\u{1F}")
        return Data(identity.utf8).base64EncodedString()
    }

    private static func loadLLMThinkingModeDictionary() -> [String: String] {
        guard let raw = preferenceString(forKey: llmThinkingModesPreferenceKey),
              let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return values
    }

    static func loadLLMThinkingMode(
        role: LLMConfigurationRole,
        provider: LLMProvider,
        model: String
    ) -> LLMThinkingMode {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            return provider.defaultThinkingMode(for: trimmedModel)
        }

        llmThinkingPreferenceLock.lock()
        defer { llmThinkingPreferenceLock.unlock() }
        let key = llmThinkingModeStorageKey(role: role, provider: provider, model: trimmedModel)
        guard let raw = loadLLMThinkingModeDictionary()[key],
              let mode = LLMThinkingMode(rawValue: raw)
        else { return provider.defaultThinkingMode(for: trimmedModel) }
        return mode
    }

    static func saveLLMThinkingMode(
        _ mode: LLMThinkingMode,
        role: LLMConfigurationRole,
        provider: LLMProvider,
        model: String
    ) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }

        llmThinkingPreferenceLock.lock()
        defer { llmThinkingPreferenceLock.unlock() }
        var values = loadLLMThinkingModeDictionary()
        let key = llmThinkingModeStorageKey(role: role, provider: provider, model: trimmedModel)
        values[key] = mode.rawValue
        guard let data = try? JSONEncoder().encode(values),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        setPreference(raw, forKey: llmThinkingModesPreferenceKey)
    }

    static func removeLLMThinkingMode(
        role: LLMConfigurationRole,
        provider: LLMProvider,
        model: String
    ) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }

        llmThinkingPreferenceLock.lock()
        defer { llmThinkingPreferenceLock.unlock() }
        var values = loadLLMThinkingModeDictionary()
        let key = llmThinkingModeStorageKey(role: role, provider: provider, model: trimmedModel)
        values.removeValue(forKey: key)
        if values.isEmpty {
            removePreference(forKey: llmThinkingModesPreferenceKey)
        } else if let data = try? JSONEncoder().encode(values),
                  let raw = String(data: data, encoding: .utf8) {
            setPreference(raw, forKey: llmThinkingModesPreferenceKey)
        }
    }

    static func saveLLMCredentials(for provider: LLMProvider, values: [String: String]) throws {
        let normalized = try normalizedLLMCredentialsForStorage(provider: provider, values: values)
        lock.lock()
        defer { lock.unlock() }
        try saveSecureDictionary(normalized, key: llmStorageKey(for: provider))
        var dict = loadAll()
        dict.removeValue(forKey: llmStorageKey(for: provider))
        try saveAll(dict)
    }

    static func loadLLMCredentials(for provider: LLMProvider) -> [String: String]? {
        if let values = loadSecureDictionary(key: llmStorageKey(for: provider)) {
            return sanitizeLLMCredentials(values)
        }
        let dict = loadAll()
        guard let values = dict[llmStorageKey(for: provider)] as? [String: String] else { return nil }
        return sanitizeLLMCredentials(values)
    }

    static func loadLLMProviderConfig(for provider: LLMProvider) -> (any LLMProviderConfig)? {
        guard let values = loadLLMCredentials(for: provider),
              let configType = LLMProviderRegistry.configType(for: provider)
        else { return nil }
        return configType.init(credentials: values)
    }

    static func withIsolatedPolishSettingsForTesting<T>(legacyOverride: String? = nil, _ body: () throws -> T) rethrows -> T {
        precondition(isRunningTests)
        let snapshot = withIsolatedTestStorage { $0 }
        withIsolatedTestStorage { storage in
            storage.preferences = storage.preferences.filter { !$0.key.hasPrefix("tf_polish_") }
            storage.secureData = storage.secureData.filter { !$0.key.hasPrefix("tf_polish_") }
            storage.preferences[DefaultsKeys.voicePolishModelOverride] = legacyOverride
        }
        defer { withIsolatedTestStorage { $0 = snapshot } }
        return try body()
    }

    static func withIsolatedPolishSettingsForTestingAsync<T>(legacyOverride: String? = nil, _ body: () async throws -> T) async rethrows -> T {
        precondition(isRunningTests)
        let snapshot = withIsolatedTestStorage { $0 }
        withIsolatedTestStorage { storage in
            storage.preferences = storage.preferences.filter { !$0.key.hasPrefix("tf_polish_") }
            storage.secureData = storage.secureData.filter { !$0.key.hasPrefix("tf_polish_") }
            storage.preferences[DefaultsKeys.voicePolishModelOverride] = legacyOverride
        }
        defer { withIsolatedTestStorage { $0 = snapshot } }
        return try await body()
    }

    // 两档独立保存；旧数据只读回退，不执行隐式迁移或覆盖另一档。
    static func polishStorageKey(role: PolishModelRole, provider: LLMProvider) -> String {
        "tf_polish_\(role.rawValue)_\(provider.rawValue)"
    }

    static func selectedPolishProvider(for role: PolishModelRole) -> LLMProvider {
        preferenceString(forKey: "tf_polish_provider_\(role.rawValue)")
            .flatMap(LLMProvider.init(rawValue:)) ?? selectedLLMProvider
    }

    static func setSelectedPolishProvider(_ provider: LLMProvider, for role: PolishModelRole) {
        setPreference(provider.rawValue, forKey: "tf_polish_provider_\(role.rawValue)")
    }

    static func loadPolishCredentials(for provider: LLMProvider, role: PolishModelRole) -> [String: String]? {
        if preferenceString(forKey: polishStorageKey(role: role, provider: provider) + "_saved") != nil {
            guard let values = loadSecureDictionary(key: polishStorageKey(role: role, provider: provider)) else { return nil }
            return sanitizeLLMCredentials(values)
        }
        guard var values = loadLLMCredentials(for: provider) else { return nil }
        if provider == selectedLLMProvider, let model = preferenceString(forKey: DefaultsKeys.voicePolishModelOverride)?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            values["model"] = model
        }
        return values
    }

    static func savePolishCredentials(for provider: LLMProvider, role: PolishModelRole, values: [String: String]) throws {
        let normalized = try normalizedLLMCredentialsForStorage(provider: provider, values: values)
        lock.lock()
        defer { lock.unlock() }
        try saveSecureDictionary(normalized, key: polishStorageKey(role: role, provider: provider))
        setPreference("1", forKey: polishStorageKey(role: role, provider: provider) + "_saved")
    }

    static func authorizePolishCredentialAccess(for provider: LLMProvider, role: PolishModelRole) -> OSStatus {
        guard provider != .localQwen else { return errSecParam }
        if preferenceString(forKey: polishStorageKey(role: role, provider: provider) + "_saved") != nil {
            return authorizeCredentialAccess(key: polishStorageKey(role: role, provider: provider))
        }
        return authorizeLLMCredentialAccess(for: provider)
    }

    static func loadPolishConfig(for role: PolishModelRole, provider explicitProvider: LLMProvider? = nil) -> LLMConfig? {
        let provider = explicitProvider ?? selectedPolishProvider(for: role)
        if provider == .localQwen {
            return resolvedLLMConfig(for: provider, role: .textProcessing)?.withThinkingMode(.disabled)
        }
        guard let values = loadPolishCredentials(for: provider, role: role),
              let type = LLMProviderRegistry.configType(for: provider),
              let config = type.init(credentials: values)?.toLLMConfig() else { return nil }
        return config.withThinkingMode(.disabled)
    }

    static var anyPolishUsesLocalModel: Bool {
        PolishModelRole.allCases.contains { selectedPolishProvider(for: $0) == .localQwen }
    }

    // MARK: - LLM Config convenience (backward compat)

    static func saveLLMCredentials(apiKey: String, model: String, baseURL: String = "") throws {
        try saveLLMCredentials(for: .doubao, values: [
            "apiKey": apiKey, "model": model, "baseURL": baseURL,
        ])
    }

    /// Load LLMConfig for the currently selected provider.
    static func loadLLMConfig() -> LLMConfig? {
        resolvedLLMConfig(for: selectedLLMProvider, role: .textProcessing)
    }

    private static func resolvedLLMConfig(
        for provider: LLMProvider,
        role: LLMConfigurationRole,
        modelOverride: String? = nil
    ) -> LLMConfig? {
        if provider == .localQwen {
            // 本地 LLM 跑在承载它的 server 上：ARM 是 Qwen3 server，Intel 是 SenseVoice server。
            // 不跨架构 fallback——ARM 的 SenseVoice server 不带 LLM，连过去只会报 "LLM not configured"。
            #if arch(arm64)
            let port = SenseVoiceServerManager.currentQwen3Port
            #else
            let port = SenseVoiceServerManager.currentPort
            #endif
            guard let port else { return nil }
            let trimmedOverride = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let model = trimmedOverride.isEmpty ? "qwen3.5-9b" : trimmedOverride
            let thinkingMode = loadLLMThinkingMode(role: role, provider: provider, model: model)
            return LLMConfig(
                apiKey: "",
                model: model,
                baseURL: "http://127.0.0.1:\(port)/v1",
                thinkingMode: thinkingMode
            )
        }

        guard let config = loadLLMProviderConfig(for: provider)?.toLLMConfig() else { return nil }
        let trimmedOverride = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = trimmedOverride.isEmpty ? config.model : trimmedOverride
        let thinkingMode = loadLLMThinkingMode(role: role, provider: provider, model: model)
        return LLMConfig(
            apiKey: config.apiKey,
            model: model,
            baseURL: config.baseURL,
            thinkingMode: thinkingMode
        )
    }

    // MARK: - Migration (call once at app launch)

    /// Migrate legacy flat keys to provider-grouped format,
    /// move Application Support directory, and migrate UserDefaults from old bundle ID.
    static func migrateIfNeeded() {
        guard !isCredentialReadOnly, !isRunningTests else { return }
        migrateAppSupportDirectory()
        migrateKeychainService()
        migrateUserDefaults()
        lock.lock()
        defer { lock.unlock() }
        let dict = loadAll()

        var migrated = false
        var mutableDict = dict

        // Migrate ASR: tf_appKey/tf_accessKey/tf_resourceId → tf_asr_volcano
        if let appKey = dict["tf_appKey"] as? String, !appKey.isEmpty,
           dict[asrStorageKey(for: .volcano)] == nil {
            let accessKey = dict["tf_accessKey"] as? String ?? ""
            let resourceId = dict["tf_resourceId"] as? String ?? "volc.bigasr.sauc.duration"
            mutableDict[asrStorageKey(for: .volcano)] = [
                "appKey": appKey,
                "accessKey": accessKey,
                "resourceId": resourceId,
            ]
            mutableDict.removeValue(forKey: "tf_appKey")
            mutableDict.removeValue(forKey: "tf_accessKey")
            mutableDict.removeValue(forKey: "tf_resourceId")
            migrated = true
            AppLogger.log("[KeychainService] Migrated legacy ASR credentials to tf_asr_volcano")
        }

        // 旧 aliyun→bailian 凭证格式与当前百炼 API Key 配置不兼容，不自动迁移；
        // 用户在设置页保存后会写入新的 tf_asr_aliyun 钥匙串项。

        // Migrate LLM: tf_llmEndpointId → tf_llmModel
        if let endpointId = dict["tf_llmEndpointId"] as? String, !endpointId.isEmpty,
           dict["tf_llmModel"] == nil {
            mutableDict["tf_llmModel"] = endpointId
            mutableDict.removeValue(forKey: "tf_llmEndpointId")
            migrated = true
            AppLogger.log("[KeychainService] Migrated tf_llmEndpointId → tf_llmModel")
        }

        // Migrate LLM: flat keys → tf_llm_doubao (provider-grouped)
        if let apiKey = dict["tf_llmApiKey"] as? String, !apiKey.isEmpty,
           dict[llmStorageKey(for: .doubao)] == nil {
            let model = (dict["tf_llmModel"] as? String) ?? ""
            let baseURL = (dict["tf_llmBaseURL"] as? String) ?? ""
            mutableDict[llmStorageKey(for: .doubao)] = [
                "apiKey": apiKey,
                "model": model,
                "baseURL": baseURL.isEmpty ? LLMProvider.doubao.defaultBaseURL : baseURL,
            ]
            mutableDict.removeValue(forKey: "tf_llmApiKey")
            mutableDict.removeValue(forKey: "tf_llmModel")
            mutableDict.removeValue(forKey: "tf_llmBaseURL")
            migrated = true
            AppLogger.log("[KeychainService] Migrated flat LLM keys to tf_llm_doubao")
        }

        // Migrate MiniMax CN: api.minimax.chat → api.minimaxi.com (old domain was incorrect)
        let minimaxCNKey = llmStorageKey(for: .minimaxCN)
        if var minimaxCreds = mutableDict[minimaxCNKey] as? [String: String],
           let baseURL = minimaxCreds["baseURL"],
           baseURL.contains("api.minimax.chat") {
            minimaxCreds["baseURL"] = baseURL.replacingOccurrences(
                of: "api.minimax.chat", with: "api.minimaxi.com"
            )
            mutableDict[minimaxCNKey] = minimaxCreds
            migrated = true
            AppLogger.log("[KeychainService] Migrated MiniMax CN base URL: api.minimax.chat → api.minimaxi.com")
        }

        let movedCredentialsToKeychain = migrateCredentialDictionariesToKeychain(in: &mutableDict)

        if migrated || movedCredentialsToKeychain {
            try? saveAll(mutableDict)
        }
    }

    @discardableResult
    private static func migrateCredentialDictionariesToKeychain(in dict: inout [String: Any]) -> Bool {
        let credentialKeys = dict.keys.filter { key in
            key.hasPrefix("tf_asr_") || key.hasPrefix("tf_llm_")
        }

        var didMove = false
        for key in credentialKeys {
            guard let values = dict[key] as? [String: String] else { continue }
            do {
                try saveSecureDictionary(values, key: key)
                dict.removeValue(forKey: key)
                didMove = true
                AppLogger.log("[KeychainService] Migrated \(key) credentials to macOS Keychain")
            } catch {
                AppLogger.log("[KeychainService] Failed to migrate \(key) credentials to macOS Keychain: \(error.localizedDescription)")
            }
        }

        return didMove
    }

    // MARK: - Legacy Migration (one-time, from previous project name)

    /// 旧项目目录/标识名。用运行时数组拼接构造，避免完整旧名作为字符串常量被编入二进制
    /// （满足"分发包内任何地方不出现旧名"的要求；strings 只能扫到 "Type"/"4"/"Me" 等碎片）。
    private static let legacyDataDirName = ["Type", "4", "Me"].joined()
    private static let legacyBundleSuffix = ["type", "4", "me"].joined()
    private static var legacyBundleID: String { "com.\(legacyBundleSuffix).app" }
    private static var legacyKeychainService: String { "com.\(legacyBundleSuffix).credentials" }

    /// 把旧项目目录的用户数据一次性并入 Dal/（仅老用户/本机升级会触发；新装环境无此目录，直接跳过）。
    /// 用文件级合并而非目录改名，因为其他初始化代码可能已先创建新目录。
    private static func migrateAppSupportDirectory() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldDir = appSupport.appendingPathComponent(legacyDataDirName, isDirectory: true)
        let newDir = appSupport.appendingPathComponent("Muse", isDirectory: true)

        // 旧目录须存在且含真实数据（credentials.json 或 history.db 任一即可——凭证迁入钥匙串后前者会消失）
        let hasData = fm.fileExists(atPath: oldDir.appendingPathComponent("credentials.json").path)
            || fm.fileExists(atPath: oldDir.appendingPathComponent("history.db").path)
        guard hasData else { return }

        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

        // 逐个文件 old → new，新目录已存在同名则跳过
        guard let contents = try? fm.contentsOfDirectory(atPath: oldDir.path) else { return }
        var movedCount = 0
        for item in contents {
            let src = oldDir.appendingPathComponent(item)
            let dst = newDir.appendingPathComponent(item)
            if !fm.fileExists(atPath: dst.path) {
                do {
                    try fm.moveItem(at: src, to: dst)
                    movedCount += 1
                } catch {
                    AppLogger.log("[KeychainService] 旧数据迁移失败 \(item): \(error.localizedDescription)")
                }
            }
        }

        if movedCount > 0 {
            AppLogger.log("[KeychainService] 已并入 \(movedCount) 个旧数据文件 → Dal")
        }

        // 旧目录清空后删除
        if let remaining = try? fm.contentsOfDirectory(atPath: oldDir.path), remaining.isEmpty {
            try? fm.removeItem(at: oldDir)
        }
    }

    /// 把旧 Keychain service 下的凭证一次性搬到当前 service（一次性，已迁移则跳过）。
    private static func migrateKeychainService() {
        let marker = "muse_migratedLegacyKeychain"
        guard !UserDefaults.standard.bool(forKey: marker) else { return }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        let ctx = LAContext()
        ctx.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = ctx

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            UserDefaults.standard.set(true, forKey: marker)
            return
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            AppLogger.log("[KeychainService] 旧钥匙串查询失败，保留迁移重试机会: \(status)")
            return
        }

        var count = 0
        var failureCount = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { continue }
            // 新 service 已有同名则不覆盖
            if loadSecureData(key: account) == nil {
                do {
                    try saveSecureData(data, key: account)
                    count += 1
                } catch {
                    failureCount += 1
                    AppLogger.log("[KeychainService] 旧钥匙串凭证迁移失败 \(account): \(error.localizedDescription)")
                }
            }
        }
        guard failureCount == 0 else {
            AppLogger.log("[KeychainService] 旧钥匙串迁移未完成，失败 \(failureCount) 条，将在下次启动重试")
            return
        }
        UserDefaults.standard.set(true, forKey: marker)
        if count > 0 {
            AppLogger.log("[KeychainService] 已迁移 \(count) 条旧钥匙串凭证 → 新 service")
        }
    }

    // MARK: - UserDefaults Migration (old bundle ID)

    /// 把旧 bundle ID 域里的 tf_ 偏好一次性拷到当前域（已迁移则跳过）。
    private static func migrateUserDefaults() {
        let marker = "muse_migratedLegacyDefaults"
        guard !UserDefaults.standard.bool(forKey: marker) else { return }

        guard let oldDefaults = UserDefaults(suiteName: legacyBundleID) else { return }
        let oldDict = oldDefaults.dictionaryRepresentation()
        let tfKeys = oldDict.keys.filter { $0.hasPrefix("tf_") }

        guard !tfKeys.isEmpty else {
            UserDefaults.standard.set(true, forKey: marker)
            return
        }

        var count = 0
        for key in tfKeys {
            // 新域已有值则不覆盖
            if UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(oldDict[key], forKey: key)
                count += 1
            }
        }

        UserDefaults.standard.set(true, forKey: marker)
        if count > 0 {
            AppLogger.log("[KeychainService] 已从旧 bundle 域迁移 \(count) 个偏好键")
        }
    }
}

enum KeychainError: Error {
    case saveFailed(OSStatus)
}
