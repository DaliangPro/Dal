import SwiftUI

/// 墨色一体侧栏：纯文字导航以暖灰层级和墨色字重表达选中态；
/// 关于与设置沉底。
struct SettingsSidebarView: View {
    let width: CGFloat
    @Binding var selectedTab: SettingsTab
    @Binding var appearanceSelection: String
    @Binding var languageSelection: String
    @Binding var isSettingsPanelOpen: Bool
    @Binding var showDockIcon: Bool
    @Binding var launchAtLogin: Bool
    @Binding var preserveClipboard: Bool
    let showsUpdateBadge: Bool
    let onSelectAbout: () -> Void
    let onLaunchAtLoginChanged: (Bool) -> Void

    @State private var isSettingsControlHovered = false
    @State private var hoveredTab: SettingsTab?
    @State private var settingsPanelFrame = CGRect.zero
    @State private var showsHUDStylePicker = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: SettingsSidebarLayout.navItemSpacing) {
                    ForEach(SettingsTab.allCases) { tab in
                        navItem(tab)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        updateHoveredTab(SettingsSidebarLayout.navigationTab(at: location))
                    case .ended:
                        updateHoveredTab(nil)
                    }
                }
                .padding(.leading, SettingsSidebarLayout.leadingInset)
                .padding(.top, SettingsSidebarLayout.navTopInset)
                .zIndex(0)

                Spacer()
            }

            settingsHoverArea(width: SettingsSidebarLayout.settingsControlWidth)
                .padding(.leading, SettingsSidebarLayout.settingsLeadingInset)
                .padding(.bottom, SettingsSidebarLayout.settingsBottomInset)
                .zIndex(30)
                .settingsScreenFrame($settingsPanelFrame)
        }
        .frame(width: width, alignment: .leading)
        // 侧栏配色对齐使用引导（2026-07-06 大梁老师）：改用 settingsSidebarTint 实色，
        // 与引导侧栏完全一致，取代原毛玻璃方案。
        .background(TF.settingsSidebarTint)
        .sheet(isPresented: $showsHUDStylePicker) { HUDStylePicker() }
        .settingsDismissOnOutsideClick(
            isActive: isSettingsPanelOpen,
            allowedFrames: [settingsPanelFrame]
        ) {
            closeSettingsPanel()
        }
    }
}

private extension SettingsSidebarView {
    func navItem(_ tab: SettingsTab) -> some View {
        SettingsSidebarNavItem(
            tab: tab,
            isActive: selectedTab == tab,
            isHovered: hoveredTab == tab,
            showBadge: tab == .about && showsUpdateBadge,
            textLeadingInset: SettingsSidebarLayout.navTextLeadingInset,
            verticalPadding: SettingsSidebarLayout.navItemVerticalPadding,
            cornerRadius: SettingsSidebarLayout.navItemCornerRadius,
            controlWidth: SettingsSidebarLayout.controlWidth
        ) {
            closeSettingsPanel(animated: false)
            selectedTab = tab
            hoveredTab = nil
            if tab == .about {
                onSelectAbout()
            }
        }
    }

    func settingsHoverArea(width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsSidebarLayout.settingsCornerRadius, style: .continuous)
        let containerHeight = SettingsSidebarLayout.settingsControlHeight + (isSettingsPanelOpen ? SettingsSidebarLayout.settingsPanelHeight : 0)

        return VStack(alignment: .leading, spacing: 0) {
            if isSettingsPanelOpen {
                SettingsSidebarSettingsPanel(
                    appearanceSelection: $appearanceSelection,
                    languageSelection: $languageSelection,
                    showDockIcon: $showDockIcon,
                    launchAtLogin: $launchAtLogin,
                    preserveClipboard: $preserveClipboard,
                    onLaunchAtLoginChanged: onLaunchAtLoginChanged,
                    onShowHUDStylePicker: {
                        closeSettingsPanel(animated: false)
                        showsHUDStylePicker = true
                    }
                )
                    .padding(.horizontal, SettingsSidebarLayout.settingsPanelHorizontalInset)
                    .padding(.top, SettingsSidebarLayout.settingsPanelTopInset)
                    .padding(.bottom, SettingsSidebarLayout.settingsPanelBottomInset)
                    .frame(width: width, height: SettingsSidebarLayout.settingsPanelHeight, alignment: .top)
                    .transition(.opacity)
            }
            settingsControl
        }
        .frame(width: width, height: containerHeight, alignment: .bottom)
        .contentShape(shape)
        .background {
            // 无卡片（2026-07-06 大梁老师）：面板展开不画任何背景，点选按钮直接浮在侧栏上；
            // 仅未展开、悬停「设置」时给一道微亮行
            Group {
                if isSettingsControlHovered && !isSettingsPanelOpen {
                    Rectangle().fill(TF.settingsSidebarHoverFill)
                        .clipShape(shape)
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: isSettingsPanelOpen)
        .animation(.easeOut(duration: 0.10), value: isSettingsControlHovered)
    }

    var settingsControl: some View {
        let controlWidth = SettingsSidebarLayout.settingsControlWidth
        let shape = RoundedRectangle(cornerRadius: SettingsSidebarLayout.navItemCornerRadius, style: .continuous)
        // 面板展开时「设置」融入弹窗组：亮度降到与面板文字同级（2026-06-12 用户拍板，
        // 此前用最亮的选中白，比面板内容跳一档）；未展开仅悬停提亮
        let foreground: Color = isSettingsPanelOpen
            ? SettingsSidebarLayout.settingsPanelTextColor
            : (isSettingsControlHovered ? TF.settingsSidebarSelectionText : TF.settingsSidebarText)

        return SettingsPlainButton {
            toggleSettingsPanel()
        } label: {
            HStack(spacing: 0) {
                Image(systemName: isSettingsPanelOpen ? "chevron.down" : "chevron.up")
                    .font(TF.settingsFontIconControl)
                    .foregroundStyle(foreground)
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsSidebarLayout.settingsControlHorizontalPadding)
            .frame(width: controlWidth, height: SettingsSidebarLayout.settingsControlHeight)
            .contentShape(shape)
        }
        .frame(width: controlWidth, height: SettingsSidebarLayout.settingsControlHeight)
        .contentShape(shape)
        .onHover { isHovering in
            updateSettingsControlHover(isHovering)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                updateSettingsControlHover(true)
            case .ended:
                updateSettingsControlHover(false)
            }
        }
        .accessibilityLabel(L("设置", "Settings"))
        .overlay {
            SidebarHoverTrackingView { isHovering in
                updateSettingsControlHover(isHovering)
            }
        }
    }

    func updateHoveredTab(_ tab: SettingsTab?) {
        guard hoveredTab != tab else { return }
        // 单一位置来源直接更新高亮，避免多个进入/离开动画互相打断。
        hoveredTab = tab
    }

    func updateSettingsControlHover(_ isHovering: Bool) {
        guard isSettingsControlHovered != isHovering else { return }
        withAnimation(.easeOut(duration: 0.10)) {
            isSettingsControlHovered = isHovering
        }
    }

    func toggleSettingsPanel() {
        withAnimation(.easeOut(duration: 0.12)) {
            isSettingsPanelOpen.toggle()
        }
    }

    func closeSettingsPanel(animated: Bool = true) {
        guard isSettingsPanelOpen else { return }
        let changes = {
            isSettingsPanelOpen = false
        }
        if animated {
            withAnimation(.easeOut(duration: 0.10), changes)
        } else {
            changes()
        }
    }
}

struct SettingsSidebarMaterialView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = .behindWindow
        nsView.state = .active
        nsView.isEmphasized = false
    }
}
