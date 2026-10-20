import SwiftUI

struct ASRSettingsFooter: View, SettingsCardHelpers {
    /// 弹窗场景下取消与右上角关闭重复，置 false 隐藏
    var showsCancel: Bool = true
    let selectedProvider: ASRProvider
    let isZeroCredentialProvider: Bool
    let hasCredentials: Bool
    let isProviderAvailable: Bool
    let hasStoredCredentials: Bool
    let isEditing: Bool
    let testStatus: SettingsTestStatus
    let inlineGuideLink: ASRProviderGuideLink?
    let onTestLocalModel: () -> Void
    let onTestASRConnection: () -> Void
    let onEdit: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            footerHint
            Spacer(minLength: 16)
            footerActions
        }
        .padding(.top, ModelSettingsStyle.footerTopSpacing)
    }
}

private extension ASRSettingsFooter {
    var footerHint: some View {
        // 配置地址链接带自身内边距，按基线对齐会下坠，改为整体垂直居中
        HStack(alignment: .center, spacing: 8) {
            Text(footerHintText)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextTertiary)
                .lineLimit(selectedProvider.isLocal || selectedProvider == .apple ? 2 : 1)
                .layoutPriority(1)

            if let link = inlineGuideLink {
                ASRInlineGuideLink(link: link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var footerHintText: String {
        if selectedProvider.isLocal {
            return L("当前已切换为本地识别，运行状态与启停操作在下方“本地模型”中管理。", "Local ASR is selected. Runtime status and controls are managed in the local models card below.")
        }
        if selectedProvider == .apple {
            return L(
                "Apple 仅使用端侧识别，音频不上传；若当前语言不支持，请切换语言或改用云端引擎。",
                "Apple uses on-device recognition only; audio is not uploaded. Switch language or use a cloud engine if unsupported."
            )
        }
        if selectedProvider == .aliyun {
            return L(
                "Dal 自动同步本地热词到百炼，默认最高权重 5；已有 ID 时更新，否则自动创建。",
                "Dal syncs local hotwords to Model Studio at maximum weight 5, updating an existing ID or creating one automatically."
            )
        }
        if isZeroCredentialProvider {
            return L("该引擎无需额外凭证，可直接测试与使用。", "This provider needs no additional credentials and can be used directly.")
        }
        return L("热词与自定义词汇自动同步", "Hotwords and custom vocabulary sync automatically.")
    }

    var footerActions: some View {
        HStack(spacing: 8) {
            if selectedProvider.isLocal {
                testButton(L("测试连接", "Test"), status: testStatus, action: onTestLocalModel)
            } else {
                testButton(L("测试连接", "Test"), status: testStatus, action: onTestASRConnection)
                    .disabled((!hasCredentials && !isZeroCredentialProvider) || !isProviderAvailable)

                if !isZeroCredentialProvider {
                    if hasCredentials && !isEditing {
                        secondaryButton(L("修改", "Edit"), action: onEdit)
                    } else {
                        if showsCancel, hasCredentials, hasStoredCredentials {
                            secondaryButton(L("取消", "Cancel"), action: onCancel)
                        }
                        saveButton(L("保存", "Save"), status: testStatus, action: onSave)
                            .disabled(!hasCredentials)
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }
}
