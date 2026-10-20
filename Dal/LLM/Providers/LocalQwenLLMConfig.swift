import Foundation

/// Config for the bundled local Qwen model running inside SenseVoice server.
/// No credentials needed — base URL comes from the server's dynamic port.
struct LocalQwenLLMConfig: LLMProviderConfig, Sendable {

    static var provider: LLMProvider { .localQwen }

    static var credentialFields: [CredentialField] { [] }

    init?(credentials: [String: String]) {
        // Always valid — no credentials required
    }

    func toCredentials() -> [String: String] { [:] }

    func toLLMConfig() -> LLMConfig {
        // Actual base URL is resolved dynamically in KeychainService.loadLLMConfig()
        let name = Self.availableModel?.name ?? "qwen3.5-9b"
        return LLMConfig(apiKey: "", model: name, baseURL: "")
    }

    // MARK: - Model Discovery

    /// Available local LLM models, ordered by preference (best first).
    static let knownModels: [LocalLLMModel] = [
        LocalLLMModel(
            name: "qwen3.5-9b",
            displayName: "Qwen3.5-9B",
            bundleFile: "qwen3.5-9b-q4_k_m.gguf",
            devFile: "Qwen3.5-9B-Q4_K_M.gguf"
        ),
    ]

    /// The best available model.
    /// 2026-06-11 产品决策：内置清单只保留 Qwen3.5-9B，4B 已除名
    /// （结构化任务上 4B 输出格式不稳定，不再提供）。
    static var availableModel: LocalLLMModel? {
        knownModels.first { $0.path != nil }
    }

    /// Check if any GGUF model file exists.
    static var isModelAvailable: Bool {
        availableModel != nil
    }

    /// Path to the best available model.
    static var modelPath: String? {
        availableModel?.path
    }
}

// MARK: - Local LLM Model Descriptor

struct LocalLLMModel: Sendable {
    let name: String
    let displayName: String
    let bundleFile: String
    let devFile: String

    /// Resolved path: checks bundle first, then dev location.
    var path: String? {
        // 1. App bundle: Contents/Resources/Models/<bundleFile>
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Models")
            .appendingPathComponent(bundleFile),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        // 2. 用户下载：~/Library/Application Support/Muse/Models/<bundleFile>
        let userPath = AppPaths.support("Models").appendingPathComponent(bundleFile)
        if FileManager.default.fileExists(atPath: userPath.path) {
            return userPath.path
        }
        // 3. Dev mode: ~/projects/dal/sensevoice-server/models/<devFile>
        let home = NSHomeDirectory()
        let devPath = (home as NSString)
            .appendingPathComponent("projects/dal/sensevoice-server/models/\(devFile)")
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        return nil
    }
}
