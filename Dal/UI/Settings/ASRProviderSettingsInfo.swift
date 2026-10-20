import Foundation

struct ASRProviderGuideLink {
    let label: String
    let url: URL
}

enum ASRProviderSettingsInfo {
    static func guideLinks(for provider: ASRProvider) -> [ASRProviderGuideLink] {
        switch provider {
        case .volcano:
            return [
                ASRProviderGuideLink(
                    label: L("配置地址", "Config URL"),
                    url: URL(string: "https://console.volcengine.com/speech/app")!
                ),
            ]
        case .aliyun:
            return [
                ASRProviderGuideLink(
                    label: L("获取 API Key", "Get API Key"),
                    url: URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key")!
                ),
                ASRProviderGuideLink(
                    label: L("接入说明", "Setup Guide"),
                    url: URL(string: "https://help.aliyun.com/zh/model-studio/real-time-speech-recognition-user-guide")!
                ),
            ]
        default:
            return []
        }
    }
}
