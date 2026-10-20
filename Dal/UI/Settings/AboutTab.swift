import SwiftUI

/// 关于页（2026-06-11 用户拍板卡片化）：沿用模型设置页的产品设计语言——
/// 灰底圆角卡片承载内容，行间靠间距分隔不再画横线
@MainActor
struct AboutTab: View, SettingsCardHelpers {
    @Environment(\.openURL) private var openURL
    @State private var updateChecker = GitHubReleaseChecker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsGroupCard(
                L("关于", "About"),
                titleAccessory: AnyView(
                    SettingsBrandLogo(width: 84, lightOpacity: 0.72, darkOpacity: 0.76)
                        .padding(.leading, 4)
                ),
                expandVertically: false,
                cornerRadius: ModelSettingsStyle.outerCardCornerRadius,
                headerBottomSpacing: 10,
                fillColor: ModelSettingsStyle.cardFillColor,
                showsBorder: false
            ) {
                Text(L("语音，流畅输入。面向 macOS 的原生语音输入工具。", "Voice to text, seamlessly. A native voice input tool for macOS."))
                    .font(TF.settingsFontBody)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            settingsGroupCard(
                L("版本信息", "Version Info"),
                trailing: AnyView(checkUpdateButton),
                expandVertically: false,
                cornerRadius: ModelSettingsStyle.outerCardCornerRadius,
                headerBottomSpacing: 6,
                fillColor: ModelSettingsStyle.cardFillColor,
                showsBorder: false
            ) {
                VStack(spacing: 0) {
                    aboutRow(label: L("版本", "Version"), value: appVersion)
                    aboutRow(label: L("构建者", "Built by"), value: "Daliang")
                    updateStatus
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var checkUpdateButton: some View {
        SettingsTextButton(
            updateChecker.state.isChecking
                ? L("检查中…", "Checking…")
                : L("检查更新", "Check for Updates"),
            variant: .secondary
        ) {
            Task {
                await updateChecker.checkForUpdates()
            }
        }
        .disabled(updateChecker.state.isChecking)
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updateChecker.state {
        case .idle:
            EmptyView()
        case .checking:
            updateStatusRow(
                message: L("正在连接 GitHub…", "Connecting to GitHub…"),
                color: TF.settingsTextTertiary,
                showsProgress: true
            )
        case .upToDate(_, let latestVersion):
            updateStatusRow(
                message: L(
                    "当前已是最新版本（v\(latestVersion)）",
                    "You’re up to date (v\(latestVersion))"
                ),
                color: TF.settingsAccentGreen
            )
        case .aheadOfRelease(let installedVersion, let latestVersion):
            updateStatusRow(
                message: L(
                    "当前 v\(installedVersion)，高于公开版本 v\(latestVersion)，无需降级",
                    "Installed v\(installedVersion) is ahead of public v\(latestVersion). No downgrade needed."
                ),
                color: TF.settingsAccentGreen
            )
        case .versionMismatch(let installedVersion, let latestVersion, let releaseURL):
            HStack(alignment: .center, spacing: 12) {
                Text(L(
                    "当前 v\(installedVersion)，GitHub 最新 v\(latestVersion)",
                    "Installed v\(installedVersion), GitHub latest v\(latestVersion)"
                ))
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsAccentAmber)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                SettingsTextButton(
                    L("前往下载", "Download"),
                    variant: .primary,
                    controlSize: .compact
                ) {
                    openURL(releaseURL)
                }
            }
            .padding(.top, 10)
        case .failed(let message):
            updateStatusRow(
                message: message,
                color: TF.settingsAccentRed
            )
        }
    }

    private func updateStatusRow(
        message: String,
        color: Color,
        showsProgress: Bool = false
    ) -> some View {
        HStack(spacing: 7) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            }
            Text(message)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private func aboutRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsTextSecondary)
            Spacer()
            Text(value)
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsText)
        }
        .frame(height: 32)
    }
}
// MARK: - 实时预览入口（macOS专用）
#Preview("设置页面-浅色模式") {
    SettingsView()
        .environment(AppState(initialModes: ProcessingMode.defaults))
        .frame(width: SettingsLayout.windowContentWidth, height: SettingsLayout.windowContentHeight)
        .preferredColorScheme(.light)
}

#Preview("设置页面-深色模式") {
    SettingsView()
        .environment(AppState(initialModes: ProcessingMode.defaults))
        .frame(width: SettingsLayout.windowContentWidth, height: SettingsLayout.windowContentHeight)
        .preferredColorScheme(.dark)
}
