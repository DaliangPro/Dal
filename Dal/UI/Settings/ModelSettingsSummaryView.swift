import SwiftUI

struct ModelSettingsSummaryData {
    let provider: String
    let model: String
    let statusTitle: String
    let statusTone: SettingsStatusTone
}

enum ModelSettingsSummary {
    static func asr() -> ModelSettingsSummaryData {
        let provider = KeychainService.selectedASRProvider
        let credentials = KeychainService.loadASRCredentials(for: provider) ?? [:]
        let configured = provider.isLocal
            || (ASRProviderRegistry.configType(for: provider)?.credentialFields.isEmpty ?? false)
            || KeychainService.loadASRConfig(for: provider) != nil
        return ModelSettingsSummaryData(
            provider: provider.displayName,
            model: asrModelName(provider: provider, credentials: credentials),
            statusTitle: configured ? L("已保存", "Saved") : L("待配置", "Needs setup"),
            statusTone: configured ? .success : .warning
        )
    }

    static func llm(role: PolishModelRole = .standard) -> ModelSettingsSummaryData {
        let provider = KeychainService.selectedPolishProvider(for: role)
        let config = KeychainService.loadPolishConfig(for: role)
        let configured = provider == .localQwen ? LocalQwenLLMConfig.isModelAvailable : config != nil
        return ModelSettingsSummaryData(
            provider: provider.displayName,
            model: llmModelName(provider: provider, config: config, override: nil),
            statusTitle: configured ? L("已保存", "Saved") : L("待配置", "Needs setup"),
            statusTone: configured ? .success : .warning
        )
    }



    private static func asrModelName(provider: ASRProvider, credentials: [String: String]) -> String {
        switch provider {
        case .volcano:
            let resourceID = credentials["resourceId"] ?? ""
            if resourceID == VolcanoASRConfig.resourceIdAuto || resourceID.isEmpty {
                return L("自动 (2.0 优先)", "Auto (2.0 first)")
            }
            if resourceID.contains("bigasr") {
                return "Doubao BigASR"
            }
            if resourceID.contains("seed") || resourceID.contains("2") {
                return "Doubao 2.0"
            }
            return resourceID
        case .aliyun:
            return (AliyunASRConfig(credentials: credentials)?.model
                ?? AliyunASRModel.defaultModel).displayName
        case .sherpa:
            return "SenseVoice"
        case .apple:
            return "Apple Speech"
        }
    }

    private static func llmModelName(provider: LLMProvider, config: LLMConfig?, override: String?) -> String {
        if let override, !override.isEmpty {
            return override
        }
        if provider == .localQwen {
            return LocalQwenLLMConfig.availableModel?.displayName ?? "Qwen3"
        }
        if let model = config?.model, !model.isEmpty {
            return model
        }
        return L("未设置", "Not set")
    }
}

struct ModelCapabilityCard: View, SettingsCardHelpers {
    let title: String
    let provider: String
    let model: String
    let statusTitle: String
    let statusTone: SettingsStatusTone
    let testStatus: SettingsTestStatus
    let onTest: () -> Void
    let onEdit: () -> Void

    var body: some View {
        settingsGroupCard(
            title,
            // 状态点在标题左侧、与卡内文字左对齐（2026-06-11 用户拍板）
            titleLeading: AnyView(SettingsStatusDot(tone: statusTone).help(statusTitle)),
            expandVertically: false,
            cornerRadius: ModelSettingsStyle.outerCardCornerRadius,
            headerBottomSpacing: 18,
            fillColor: ModelSettingsStyle.cardFillColor,
            showsBorder: false
        ) {
            HStack(alignment: .bottom, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ModelInfoLine(label: L("服务商", "Provider"), value: provider)
                    ModelInfoLine(label: L("模型", "Model"), value: model)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    testButton(L("测试连接", "Test Connection"), status: testStatus, action: onTest)
                    SettingsTextButton(
                        L("修改", "Edit"),
                        variant: .secondary,
                        action: onEdit
                    )
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(
            minWidth: ModelSettingsStyle.summaryCardMinWidth,
            maxWidth: .infinity,
            minHeight: ModelSettingsStyle.summaryCardMinHeight,
            alignment: .topLeading
        )
    }
}

struct ModelInfoLine: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
            Text(value)
                // 卡内的值降到 11pt：与卡片标题(12pt)拉开主次，并与页面元数据档统一（2026-06-21 大梁老师拍板）
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
