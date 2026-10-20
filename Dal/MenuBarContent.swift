import AppKit
import SwiftUI

@MainActor
struct MenuBarContent: View {

    @Environment(\.openWindow) private var openWindow
    @AppStorage(DefaultsKeys.language) private var language = AppLanguage.systemSelection

    var body: some View {
        Button(L("设置", "Settings")) {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button(L("使用引导", "Setup Guide")) {
            openWindow(id: "setup")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button(L("关于", "About")) {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .navigateToTab, object: SettingsTab.about)
        }

        Button(L("检查更新", "Check for Updates")) {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .navigateToTab, object: SettingsTab.about)
            Task {
                await GitHubReleaseChecker.shared.checkForUpdates()
            }
        }

        Divider()

        Button(L("退出 Dal", "Quit Dal")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)

        // 语言变化时强制重渲染
        let _ = language

    }

}
