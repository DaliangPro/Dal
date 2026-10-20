import SwiftUI

struct LLMSettingsFooter: View, SettingsCardHelpers {
    var role: PolishModelRole = .standard
    /// 弹窗场景下取消与右上角关闭重复，置 false 隐藏
    var showsCancel: Bool = true
    let selectedProvider: LLMProvider
    let hasCredentials: Bool
    let hasStoredCredentials: Bool
    let isEditing: Bool
    let testStatus: SettingsTestStatus
    let isServerRunning: Bool
    let isLocalModelAvailable: Bool
    /// 非空时在测试连接左侧显示「获取模型列表」（线上服务商场景）
    var onFetchModels: (() -> Void)? = nil
    let onTestConnection: () -> Void
    let onStopLocalServer: () -> Void
    let onStartLocalServer: () -> Void
    let onEdit: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(footerHintText)
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 16)

            footerActions
        }
        .padding(.top, ModelSettingsStyle.footerTopSpacing)
    }
}

private extension LLMSettingsFooter {
    var footerHintText: String {
        if selectedProvider == .localQwen {
            return L("本地 Qwen 用于离线文本处理，首次启动会预热模型。", "Local Qwen handles offline text cleanup and warms the model on first start.")
        }
        return role == .light
            ? L("基础纠错与口误修正", "Basic corrections")
            : L("结构整理与表达打磨", "Structure and wording")
    }

    var footerActions: some View {
        HStack(spacing: 8) {
            if let onFetchModels, selectedProvider != .localQwen, isEditing || !hasStoredCredentials {
                settingsMiniButton(
                    L("获取模型列表", "Fetch Models"),
                    variant: .secondary,
                    action: onFetchModels
                )
            }
            testButton(L("测试连接", "Test"), status: testStatus, action: onTestConnection)
                .disabled(selectedProvider == .localQwen ? !isLocalModelAvailable : !hasCredentials)

            if selectedProvider == .localQwen {
                if isServerRunning {
                    settingsMiniButton(
                        L("停止", "Stop"),
                        variant: .danger,
                        action: onStopLocalServer
                    )
                } else {
                    settingsMiniButton(
                        L("启动", "Start"),
                        variant: .warning,
                        action: onStartLocalServer
                    )
                }
            } else if hasCredentials && !isEditing {
                secondaryButton(L("修改", "Edit"), action: onEdit)
            } else {
                if showsCancel, hasCredentials, hasStoredCredentials {
                    secondaryButton(L("取消", "Cancel"), action: onCancel)
                }
                saveButton(L("保存", "Save"), status: testStatus, action: onSave)
                    .disabled(!hasCredentials)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        // 上报按钮排宽度，卡片用它取齐输入框宽度
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: SettingsFooterActionsWidthKey.self, value: proxy.size.width)
            }
        )
    }
}
