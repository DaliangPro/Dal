import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    private let configuresWindow: Bool
    private let settingsPageInsets = SettingsLayout.pageInsets

    @Environment(AppState.self) private var appState
    @State private var selectedTab: SettingsTab = .general
    @State private var isSidebarSettingsPanelOpen = false
    @State private var storageRecoveryNotice: StorageRecoveryNotice?
    @AppStorage(DefaultsKeys.language) private var language = AppLanguage.systemSelection
    @AppStorage("tf_settingsAppearance") private var settingsAppearance = SettingsAppearanceMode.system.rawValue
    @AppStorage("tf_launchAtLogin") private var launchAtLogin = true
    @AppStorage(DefaultsKeys.preserveClipboard) private var preserveClipboard = true
    @AppStorage(DefaultsKeys.showDockIcon) private var showDockIcon = true

    init(configuresWindow: Bool = true) {
        self.configuresWindow = configuresWindow
        _selectedTab = State(initialValue: AppLaunchDebug.settingsModesPreviewEnabled ? .modes : .general)
    }

    private var sidebarWidth: CGFloat {
        SettingsLayout.sidebarWidth
    }

    var body: some View {
        GeometryReader { proxy in
            let contentOriginX = sidebarWidth + SettingsLayout.dividerWidth
            let contentWidth = max(proxy.size.width - contentOriginX, 0)

            ZStack(alignment: .topLeading) {
                SettingsSidebarView(
                    width: sidebarWidth,
                    selectedTab: $selectedTab,
                    appearanceSelection: $settingsAppearance,
                    languageSelection: $language,
                    isSettingsPanelOpen: $isSidebarSettingsPanelOpen,
                    showDockIcon: $showDockIcon,
                    launchAtLogin: $launchAtLogin,
                    preserveClipboard: $preserveClipboard,
                    showsUpdateBadge: appState.hasUnseenUpdate,
                    onSelectAbout: {
                        UpdateChecker.shared.markAsSeen(appState: appState)
                    },
                    onLaunchAtLoginChanged: updateLaunchAtLogin
                )
                    .frame(width: sidebarWidth, height: proxy.size.height, alignment: .topLeading)
                    .zIndex(30)

                Rectangle()
                    .fill(TF.settingsStroke.opacity(0.35))
                    .frame(width: SettingsLayout.dividerWidth, height: proxy.size.height)
                    .offset(x: sidebarWidth)
                    .zIndex(0)

                SettingsContentArea(
                    selectedTab: selectedTab,
                    pageInsets: settingsPageInsets
                )
                    .frame(width: contentWidth, height: proxy.size.height, alignment: .topLeading)
                    .offset(x: contentOriginX)
                    .zIndex(0)

            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .id(language)
        .frame(
            maxWidth: .infinity,
            minHeight: SettingsLayout.windowContentHeight,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background {
            // 侧栏改实色后（对齐引导）：左侧铺 settingsSidebarTint、右侧内容区铺画布色
            HStack(spacing: 0) {
                Rectangle().fill(TF.settingsSidebarTint).frame(width: sidebarWidth)
                Rectangle().fill(TF.settingsShell)
            }
            if configuresWindow {
                SettingsWindowConfigurator(
                    contentWidth: SettingsLayout.windowContentWidth,
                    contentHeight: SettingsLayout.windowContentHeight,
                    minimumContentHeight: SettingsLayout.windowMinimumContentHeight,
                    trafficLightLeadingInset: SettingsSidebarLayout.trafficLightLeadingInset,
                    trafficLightTopInset: SettingsSidebarLayout.trafficLightTopInset,
                    appearance: SettingsAppearanceMode(rawValue: settingsAppearance) ?? .system
                )
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .task {
            syncLoginItemState()
            storageRecoveryNotice = StorageRecoveryScanner.firstPendingNotice()
        }
        .alert(item: $storageRecoveryNotice) { notice in
            Alert(
                title: Text(L("需要恢复配置文件", "Configuration recovery required")),
                message: Text(notice.message),
                primaryButton: .default(Text(L("在 Finder 中显示备份", "Show Backup in Finder"))) {
                    NSWorkspace.shared.activateFileViewerSelecting([notice.backupURL])
                },
                secondaryButton: .cancel(Text(L("稍后处理", "Review Later")))
            )
        }
        .onChange(of: settingsAppearance) { _, _ in
            AppearanceController.apply()
        }
        .onChange(of: showDockIcon) { _, _ in
            MenuBarVisibilityMonitor.applyDockIconPreferencePreservingVisibleWindows()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToMode)) { note in
            selectedTab = .modes
            if let modeId = note.object as? UUID {
                NotificationCenter.default.post(name: .selectMode, object: modeId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTab)) { note in
            if let tab = note.object as? SettingsTab {
                selectedTab = tab
            }
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard launchAtLogin != enabled else { return }
        launchAtLogin = enabled
        setLoginItem(enabled: enabled)
    }

    private func setLoginItem(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = !enabled
        }
    }

    private func syncLoginItemState() {
        let status = SMAppService.mainApp.status
        if status == .notRegistered, !UserDefaults.standard.bool(forKey: DefaultsKeys.didInitialLoginItemSetup) {
            UserDefaults.standard.set(true, forKey: DefaultsKeys.didInitialLoginItemSetup)
            setLoginItem(enabled: true)
        } else {
            launchAtLogin = status == .enabled
        }
    }

}
