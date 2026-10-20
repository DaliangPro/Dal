import Foundation

enum ASRAudioInputKind: Sendable, Equatable {
    case pcmData
    case pcmBuffer
}

struct ASRProviderCapabilities: Sendable, Equatable {
    let isAvailable: Bool
    /// False for batch/REST providers that only produce results in endAudio().
    let isStreaming: Bool
    let audioInput: ASRAudioInputKind

    static func streaming(audioInput: ASRAudioInputKind = .pcmData) -> ASRProviderCapabilities {
        ASRProviderCapabilities(isAvailable: true, isStreaming: true, audioInput: audioInput)
    }

    static func batch(audioInput: ASRAudioInputKind = .pcmData) -> ASRProviderCapabilities {
        ASRProviderCapabilities(isAvailable: true, isStreaming: false, audioInput: audioInput)
    }

    static let unavailable = ASRProviderCapabilities(
        isAvailable: false,
        isStreaming: true,
        audioInput: .pcmData
    )
}

enum ASRProviderRegistry {

    struct ProviderEntry: Sendable {
        let configType: any ASRProviderConfig.Type
        let createClient: (@Sendable () -> any SpeechRecognizer)?
        let capabilities: ASRProviderCapabilities

        var isAvailable: Bool {
            capabilities.isAvailable && createClient != nil
        }

        init(
            configType: any ASRProviderConfig.Type,
            createClient: (@Sendable () -> any SpeechRecognizer)?,
            capabilities: ASRProviderCapabilities = .unavailable
        ) {
            self.configType = configType
            self.createClient = createClient
            self.capabilities = capabilities
        }
    }

    static let all: [ASRProvider: ProviderEntry] = {
        var dict: [ASRProvider: ProviderEntry] = [
            .apple: ProviderEntry(
                configType: AppleASRConfig.self,
                createClient: { AppleASRClient() },
                capabilities: .streaming(audioInput: .pcmBuffer)
            ),
            .volcano: ProviderEntry(
                configType: VolcanoASRConfig.self,
                createClient: { VolcASRClient() },
                capabilities: .streaming()
            ),
            .aliyun: ProviderEntry(
                configType: AliyunASRConfig.self,
                createClient: { AliyunASRClient() },
                capabilities: .streaming()
            ),
        ]
        #if HAS_SHERPA_ONNX
        if ServerExecutableResolver.live.isAvailable(name: "sensevoice-server") {
            dict[.sherpa] = ProviderEntry(
                configType: SherpaASRConfig.self,
                createClient: { SenseVoiceWSClient() },
                capabilities: .batch()  // full_inference at end takes 3-5s, needs longer timeout
            )
        } else {
            dict[.sherpa] = ProviderEntry(configType: SherpaASRConfig.self, createClient: nil)
        }
        #else
        dict[.sherpa] = ProviderEntry(configType: SherpaASRConfig.self, createClient: nil)
        #endif
        return dict
    }()

    static func entry(for provider: ASRProvider) -> ProviderEntry? {
        all[provider]
    }

    static func configType(for provider: ASRProvider) -> (any ASRProviderConfig.Type)? {
        all[provider]?.configType
    }

    static func createClient(for provider: ASRProvider) -> (any SpeechRecognizer)? {
        all[provider]?.createClient?()
    }

    static func capabilities(for provider: ASRProvider) -> ASRProviderCapabilities {
        all[provider]?.capabilities ?? .unavailable
    }

    static func supports(_ mode: ProcessingMode, for provider: ASRProvider) -> Bool {
        supports(mode, for: provider, capabilities: capabilities(for: provider))
    }

    static func supports(
        _ mode: ProcessingMode,
        for provider: ASRProvider,
        capabilities: ASRProviderCapabilities
    ) -> Bool {
        capabilities.isAvailable
    }

    static func supportedModes(from modes: [ProcessingMode], for provider: ASRProvider) -> [ProcessingMode] {
        supportedModes(
            from: modes,
            for: provider,
            capabilities: capabilities(for: provider)
        )
    }

    static func supportedModes(
        from modes: [ProcessingMode],
        for provider: ASRProvider,
        capabilities: ASRProviderCapabilities
    ) -> [ProcessingMode] {
        modes.filter { supports($0, for: provider, capabilities: capabilities) }
    }

    static func resolvedMode(for mode: ProcessingMode, provider: ASRProvider) -> ProcessingMode {
        resolvedMode(
            for: mode,
            provider: provider,
            capabilities: capabilities(for: provider)
        )
    }

    static func resolvedMode(
        for mode: ProcessingMode,
        provider: ASRProvider,
        capabilities: ASRProviderCapabilities
    ) -> ProcessingMode {
        supports(mode, for: provider, capabilities: capabilities) ? VoiceInputModes.resolve(mode) : .direct
    }

    /// 显式固定回退优先级，避免依赖 `allCases` 的声明顺序。
    static func resolvedProvider(
        for requested: ASRProvider,
        capabilities: (ASRProvider) -> ASRProviderCapabilities = {
            ASRProviderRegistry.capabilities(for: $0)
        }
    ) -> ASRProvider {
        if capabilities(requested).isAvailable {
            return requested
        }
        return [ASRProvider.volcano, .aliyun, .apple, .sherpa]
            .first { capabilities($0).isAvailable }
            ?? requested
    }

}
