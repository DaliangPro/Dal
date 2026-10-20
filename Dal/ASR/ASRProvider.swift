import Foundation

// MARK: - Provider Enum

enum ASRProvider: String, CaseIterable, Codable, Sendable {
    // 2026-07-21 产品决策：在 G1 精简后的火山引擎基础上新增阿里云百炼，
    // 其余已移除云厂商仍由 selectedASRProvider 的解析兜底到 volcano。
    // Local
    case sherpa
    case apple
    // Cloud
    case volcano
    case aliyun

    var displayName: String {
        switch self {
        case .sherpa:   return L("本地识别", "Local ASR")
        case .apple:    return "Apple Speech"
        case .volcano:  return L("火山引擎 (Doubao)", "Volcano (Doubao)")
        case .aliyun:   return L("阿里云百炼", "Alibaba Cloud Model Studio")
        }
    }

    /// Whether this provider runs entirely on-device (no network required).
    var isLocal: Bool { self == .sherpa }
    // 老用户兜底：KeychainService.selectedASRProvider 的 getter 对无法解析的
    // 历史 rawValue（已移除厂商）统一回退 .volcano，无需额外迁移代码
}

// MARK: - Credential Field Descriptor

struct FieldOption: Sendable {
    let value: String
    let label: String
}

struct CredentialField: Sendable, Identifiable {
    let key: String
    let label: String
    let placeholder: String
    let isSecure: Bool
    let isOptional: Bool
    let defaultValue: String
    /// When non-empty, the UI renders a Picker instead of a TextField.
    let options: [FieldOption]

    var id: String { key }

    init(key: String, label: String, placeholder: String, isSecure: Bool, isOptional: Bool, defaultValue: String, options: [FieldOption] = []) {
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.isSecure = isSecure
        self.isOptional = isOptional
        self.defaultValue = defaultValue
        self.options = options
    }
}

// MARK: - Provider Config Protocol

protocol ASRProviderConfig: Sendable {
    static var provider: ASRProvider { get }
    static var credentialFields: [CredentialField] { get }

    init?(credentials: [String: String])
    func toCredentials() -> [String: String]
    var isValid: Bool { get }
}
