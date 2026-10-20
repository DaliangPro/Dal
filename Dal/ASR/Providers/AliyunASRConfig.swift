import Foundation

enum AliyunASRModel: String, CaseIterable, Sendable, Equatable {
    case funASRRealtime = "fun-asr-realtime"
    case paraformerRealtimeV2 = "paraformer-realtime-v2"

    static let defaultModel = Self.funASRRealtime

    var displayName: String {
        switch self {
        case .funASRRealtime:
            return "Fun-ASR Realtime"
        case .paraformerRealtimeV2:
            return "Paraformer Realtime v2"
        }
    }

    var vocabularyCredentialKey: String {
        switch self {
        case .funASRRealtime:
            return "funVocabularyId"
        case .paraformerRealtimeV2:
            // 沿用首版阿里云接入的键名，已有 Paraformer 热词表无需迁移或重建。
            return "vocabularyId"
        }
    }
}

struct AliyunASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.aliyun
    static let compatibilityEndpoint = URL(
        string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
    )!
    static let compatibilityVocabularyEndpoint = URL(
        string: "https://dashscope.aliyuncs.com/api/v1/services/audio/asr/customization"
    )!

    static var credentialFields: [CredentialField] {[
        CredentialField(
            key: "model",
            label: L("识别模型", "Recognition Model"),
            placeholder: "",
            isSecure: false,
            isOptional: false,
            defaultValue: AliyunASRModel.defaultModel.rawValue,
            options: AliyunASRModel.allCases.map {
                FieldOption(value: $0.rawValue, label: $0.displayName)
            }
        ),
        CredentialField(
            key: "apiKey",
            label: "API Key",
            placeholder: "sk-...",
            isSecure: true,
            isOptional: false,
            defaultValue: ""
        ),
        CredentialField(
            key: "workspaceId",
            label: "Workspace ID",
            placeholder: L("可选，填写后使用专属域名", "Optional, enables workspace endpoint"),
            isSecure: false,
            isOptional: true,
            defaultValue: ""
        ),
        CredentialField(
            key: "funVocabularyId",
            label: L("Fun-ASR 热词表 ID", "Fun-ASR Vocabulary ID"),
            placeholder: L("可选，Dal 自动创建", "Optional, created automatically"),
            isSecure: false,
            isOptional: true,
            defaultValue: ""
        ),
        CredentialField(
            key: "vocabularyId",
            label: L("Paraformer 热词表 ID", "Paraformer Vocabulary ID"),
            placeholder: L("可选，Dal 自动创建", "Optional, created automatically"),
            isSecure: false,
            isOptional: true,
            defaultValue: ""
        ),
    ]}

    let apiKey: String
    let workspaceId: String?
    let model: AliyunASRModel
    let funVocabularyId: String?
    let paraformerVocabularyId: String?

    var vocabularyId: String? {
        switch model {
        case .funASRRealtime:
            return funVocabularyId
        case .paraformerRealtimeV2:
            return paraformerVocabularyId
        }
    }

    init?(credentials: [String: String]) {
        guard let apiKey = Self.usableCredentialValue(credentials["apiKey"]) else {
            return nil
        }

        let workspaceId = Self.optionalCredentialValue(credentials["workspaceId"])
        if let workspaceId, !Self.isValidWorkspaceID(workspaceId) {
            return nil
        }
        let modelValue = Self.optionalCredentialValue(credentials["model"])
            ?? AliyunASRModel.defaultModel.rawValue
        guard let model = AliyunASRModel(rawValue: modelValue) else {
            return nil
        }

        self.apiKey = apiKey
        self.workspaceId = workspaceId
        self.model = model
        self.funVocabularyId = Self.optionalCredentialValue(credentials["funVocabularyId"])
        self.paraformerVocabularyId = Self.optionalCredentialValue(credentials["vocabularyId"])
    }

    var endpoint: URL {
        guard let workspaceId else { return Self.compatibilityEndpoint }
        return URL(
            string: "wss://\(workspaceId).cn-beijing.maas.aliyuncs.com/api-ws/v1/inference"
        )!
    }

    var vocabularyEndpoint: URL {
        guard let workspaceId else { return Self.compatibilityVocabularyEndpoint }
        return URL(
            string: "https://\(workspaceId).cn-beijing.maas.aliyuncs.com/api/v1/services/audio/asr/customization"
        )!
    }

    func toCredentials() -> [String: String] {
        var values = [
            "apiKey": apiKey,
            "model": model.rawValue,
        ]
        if let workspaceId {
            values["workspaceId"] = workspaceId
        }
        if let funVocabularyId {
            values["funVocabularyId"] = funVocabularyId
        }
        if let paraformerVocabularyId {
            values["vocabularyId"] = paraformerVocabularyId
        }
        return values
    }

    var isValid: Bool { !apiKey.isEmpty }

    private static func usableCredentialValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !trimmed.contains("\u{2022}") else { return nil }
        return trimmed
    }

    private static func optionalCredentialValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed.contains("\u{2022}") ? nil : trimmed
    }

    private static func isValidWorkspaceID(_ value: String) -> Bool {
        guard value.count <= 63,
              let first = value.first,
              let last = value.last,
              first.isLetter || first.isNumber,
              last.isLetter || last.isNumber
        else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}
