import SwiftUI

/// 侧栏「设置」展开面板（2026-07-06 大梁老师重构）：无卡片背景，往上浮出、再点设置收起。
/// 分两区、中间一道细分隔线：
/// 上区「偏好」= 外观(系统/浅色/深色 三图标点选) + 语言(中/EN 文字点选)，只内容本身亮成琥珀、无底；
/// 下区「开关」= 三个纯文字按钮，开启时整个按钮亮起(琥珀淡底)。
struct SettingsSidebarSettingsPanel: View {
    @Binding var appearanceSelection: String
    @Binding var languageSelection: String
    @Binding var showDockIcon: Bool
    @Binding var launchAtLogin: Bool
    @Binding var preserveClipboard: Bool
    let onLaunchAtLoginChanged: (Bool) -> Void
    let onShowHUDStylePicker: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var rowHeight: CGFloat { SettingsSidebarLayout.settingsPanelOptionHeight }

    /// 砍掉「跟随系统」档后仍尊重默认：外观存 system / 未设时,按当前实际外观高亮 浅 / 深
    private var isDark: Bool {
        SettingsAppearanceMode.resolvedIsDark(selection: appearanceSelection, systemColorScheme: colorScheme)
    }

    var body: some View {
        VStack(spacing: SettingsSidebarLayout.settingsPanelOptionSpacing) {
            // 上区 · 偏好（只内容亮）
            HStack(spacing: 24) {
                plainIcon("sun.max", active: !isDark) { setAppearance(.light) }
                plainIcon("moon", active: isDark) { setAppearance(.dark) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight)

            HStack(spacing: 24) {
                plainLabel("中", active: AppLanguage.current == .zh) {
                    languageSelection = AppLanguage.zh.rawValue
                }
                plainLabel("EN", active: AppLanguage.current == .en) {
                    languageSelection = AppLanguage.en.rawValue
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight)

            fillButton(L("HUD 样式", "HUD Style"), on: false) {
                onShowHUDStylePicker()
            }

            Rectangle()
                .fill(TF.settingsSidebarText.opacity(0.14))
                .frame(height: 1)
                .padding(.horizontal, 4)

            // 下区 · 开关（整个按钮亮）
            fillButton(L("程序坞", "Dock"), on: showDockIcon) {
                showDockIcon.toggle()
            }
            fillButton(L("开机自启", "Launch"), on: launchAtLogin) {
                onLaunchAtLoginChanged(!launchAtLogin)
            }
            fillButton(L("自动复制", "Auto copy"), on: !preserveClipboard) {
                preserveClipboard.toggle()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func setAppearance(_ mode: SettingsAppearanceMode) {
        appearanceSelection = mode.rawValue
        AppearanceController.apply()
    }

    // MARK: - 上区：只内容亮，无底

    private func plainIcon(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(TF.settingsFontIconControl)
                .foregroundStyle(active ? TF.amber : TF.settingsSidebarText.opacity(0.55))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func plainLabel(_ text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(TF.settingsFontControl)
                .foregroundStyle(active ? TF.amber : TF.settingsSidebarText.opacity(0.55))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 下区：纯文字，整个按钮亮

    private func fillButton(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous)
        return Button(action: action) {
            Text(label)
                .font(TF.settingsFontControl)
                .foregroundStyle(on ? TF.amber : TF.settingsSidebarText.opacity(0.6))
                .frame(maxWidth: .infinity)
                .frame(height: rowHeight)
                .background(shape.fill(on ? TF.amber.opacity(0.15) : Color.clear))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}
