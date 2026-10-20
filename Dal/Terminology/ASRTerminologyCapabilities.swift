import Foundation

enum ASRTerminologyHotwordDelivery: String, Sendable, Equatable {
    /// 每次请求直接携带热词，例如火山 `context.hotwords`。
    case request
    /// 先同步远端词表，再由识别请求引用词表 ID，例如阿里百炼。
    case remoteVocabulary
    /// 写入本机服务词表并重载本地识别进程。
    case localServiceVocabulary
    case unsupported
}

enum ASRTerminologyAliasDelivery: String, Sendable, Equatable {
    /// Provider 请求原生支持 alias → canonical，例如火山 `correct_words`。
    case requestCorrections
    /// Provider 不表达 alias，统一依赖 Dal 本地确定性纠正。
    case localOnly
}

struct ASRTerminologyCapabilities: Sendable, Equatable {
    let hotwordDelivery: ASRTerminologyHotwordDelivery
    let aliasDelivery: ASRTerminologyAliasDelivery
    /// 无论 Provider 是否声称支持，Dal 收尾都保留本地一致性兜底。
    let requiresLocalCorrectionFallback: Bool

    var supportsRequestHotwords: Bool { hotwordDelivery == .request }
    var supportsAliasCorrections: Bool { aliasDelivery == .requestCorrections }
    var supportsRemoteVocabularySync: Bool { hotwordDelivery == .remoteVocabulary }
    var supportsLocalServiceVocabulary: Bool { hotwordDelivery == .localServiceVocabulary }

    static func forProvider(_ provider: ASRProvider) -> ASRTerminologyCapabilities {
        switch provider {
        case .volcano:
            return ASRTerminologyCapabilities(
                hotwordDelivery: .request,
                aliasDelivery: .requestCorrections,
                requiresLocalCorrectionFallback: true
            )
        case .aliyun:
            return ASRTerminologyCapabilities(
                hotwordDelivery: .remoteVocabulary,
                aliasDelivery: .localOnly,
                requiresLocalCorrectionFallback: true
            )
        case .apple:
            return ASRTerminologyCapabilities(
                hotwordDelivery: .unsupported,
                aliasDelivery: .localOnly,
                requiresLocalCorrectionFallback: true
            )
        case .sherpa:
            return ASRTerminologyCapabilities(
                hotwordDelivery: .localServiceVocabulary,
                aliasDelivery: .localOnly,
                requiresLocalCorrectionFallback: true
            )
        }
    }
}
