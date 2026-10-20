import SwiftUI

struct ModeModelStatus: Equatable {
    enum ServiceKind: Equatable {
        case asr
        case llm
    }

    let title: String
    let serviceKind: ServiceKind
    let isAvailable: Bool
    var polishRole: PolishModelRole? = nil

    var availabilityTitle: String {
        isAvailable ? L("可用", "Available") : L("不可用", "Unavailable")
    }

    var serviceTitle: String {
        switch serviceKind {
        case .asr:
            return L("语音识别模型", "Speech model")
        case .llm:
            return (polishRole ?? .standard).title
        }
    }
}

extension ModesSettingsTab {
    var selectedASRProvider: ASRProvider {
        ASRProvider(rawValue: selectedASRProviderRaw) ?? KeychainService.selectedASRProvider
    }

    var selectedLLMProvider: LLMProvider {
        KeychainService.selectedPolishProvider(for: .standard)
    }

    func currentModelStatus(for mode: ProcessingMode) -> ModeModelStatus {
        let usesLLM = mode.requiresLLM
        if usesLLM {
            let role = PolishModelRole.resolve(mode.voicePolishQualityMode)
            let provider = KeychainService.selectedPolishProvider(for: role)
            let config = KeychainService.loadPolishConfig(for: role)
            return ModeModelStatus(
                title: config?.model ?? provider.displayName,
                serviceKind: .llm,
                isAvailable: provider == .localQwen ? LocalQwenLLMConfig.isModelAvailable : config != nil,
                polishRole: role
            )
        }

        return ModeModelStatus(
            title: currentASRShortName,
            serviceKind: .asr,
            isAvailable: currentASRIsAvailable
        )
    }

    var currentASRIsAvailable: Bool {
        guard ASRProviderRegistry.capabilities(for: selectedASRProvider).isAvailable,
              let config = KeychainService.loadASRConfig(for: selectedASRProvider)
        else { return false }
        return config.isValid
    }

    var currentLLMIsAvailable: Bool {
        if selectedLLMProvider == .localQwen {
            return LocalQwenLLMConfig.isModelAvailable
        }
        return KeychainService.loadPolishConfig(for: .standard) != nil
    }

    var currentLLMShortName: String {
        switch selectedLLMProvider {
        case .deepseek:
            return "DeepSeek"
        case .doubao:
            return "豆包"
        case .localQwen:
            return "Qwen"
        default:
            return selectedLLMProvider.displayName.components(separatedBy: " ").first ?? selectedLLMProvider.displayName
        }
    }

    var currentASRShortName: String {
        switch selectedASRProvider {
        case .volcano:
            return volcanoASRShortName
        case .aliyun:
            let model = (KeychainService.loadASRConfig(for: .aliyun) as? AliyunASRConfig)?.model
                ?? AliyunASRModel.defaultModel
            return model == .funASRRealtime ? "Fun-ASR" : "Paraformer v2"
        case .sherpa:
            return "SenseVoice"
        case .apple:
            return "Apple ASR"
        }
    }

    var volcanoASRShortName: String {
        guard let config = KeychainService.loadASRConfig(for: .volcano) as? VolcanoASRConfig else {
            return L("豆包语音", "Doubao ASR")
        }

        switch config.resourceId {
        case VolcanoASRConfig.resourceIdBigASR:
            return L("豆包大模型", "Doubao Large")
        case VolcanoASRConfig.resourceIdSeedASR:
            return L("豆包 2.0", "Doubao 2.0")
        default:
            return L("豆包语音", "Doubao ASR")
        }
    }

    func hotkeyDisplayTitle(for mode: ProcessingMode) -> String {
        if let keyCode = mode.hotkeyCode {
            return HotkeyDisplay.keyDisplayName(keyCode: keyCode, modifiers: mode.hotkeyModifiers)
        }
        return L("未设置", "Not set")
    }
}
