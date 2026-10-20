import AppKit

@MainActor
final class MenuBarVisibilityMonitor {
    private var dockIconPreferenceObserver: NSObjectProtocol?

    func start() {
        checkMenuBarVisibility()
        observeDockIconPreference()
    }

    deinit {
        if let dockIconPreferenceObserver {
            NotificationCenter.default.removeObserver(dockIconPreferenceObserver)
        }
    }

    private func observeDockIconPreference() {
        dockIconPreferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Self.applyDockIconPreference(preserveVisibleWindows: true)
            }
        }
    }

    static func applyDockIconPreferencePreservingVisibleWindows() {
        applyDockIconPreference(preserveVisibleWindows: true)
    }

    private static func applyDockIconPreference(preserveVisibleWindows: Bool = false) {
        let windowsToRestore = preserveVisibleWindows ? restorableVisibleWindows() : []
        let showDock = UserDefaults.standard.object(forKey: DefaultsKeys.showDockIcon) as? Bool ?? true
        let current = NSApp.activationPolicy()
        let desired: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        if current != desired {
            NSApp.setActivationPolicy(desired)
            restoreVisibleWindows(windowsToRestore)
        }
    }

    private static func restorableVisibleWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            window.isVisible
                && !window.className.contains("NSStatusBar")
                && !window.className.contains("NSMenu")
        }
    }

    private static func restoreVisibleWindows(_ windows: [NSWindow]) {
        guard !windows.isEmpty else { return }

        restoreVisibleWindowsNow(windows)
        DispatchQueue.main.async {
            restoreVisibleWindowsNow(windows)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            restoreVisibleWindowsNow(windows)
        }
    }

    private static func restoreVisibleWindowsNow(_ windows: [NSWindow]) {
        for window in windows where window.isVisible {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// On macOS 26 Tahoe, System Settings > Menu Bar > "Allow in Menu Bar" can hide
    /// third-party status items by rendering them offscreen. Detect this and alert the user.
    private func checkMenuBarVisibility() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.performMenuBarCheck()
            }
        }
    }

    private func performMenuBarCheck() {
        let statusBarWindows = NSApp.windows.filter {
            $0.className.contains("NSStatusBar")
        }

        let isVisible: Bool
        if statusBarWindows.isEmpty {
            isVisible = false
        } else {
            let allScreens = NSScreen.screens
            isVisible = statusBarWindows.contains { window in
                let frame = window.frame
                return allScreens.contains { screen in
                    let sf = screen.frame
                    return frame.origin.x >= sf.minX - 100
                        && frame.origin.x <= sf.maxX + 100
                        && frame.origin.y >= sf.minY - 100
                }
            }
        }

        guard !isVisible else { return }

        AppLogger.log("[Dal] Menu bar icon appears hidden by system settings")

        let alert = NSAlert()
        alert.messageText = L(
            "菜单栏图标被隐藏",
            "Menu Bar Icon Hidden"
        )
        alert.informativeText = L(
            "macOS 的菜单栏设置可能隐藏了 Dal 图标。\n\n请前往 系统设置 > 菜单栏，在「允许在菜单栏中显示」列表中开启 Dal。",
            "macOS may have hidden the Dal icon.\n\nGo to System Settings > Menu Bar and enable Dal in the 'Allow in Menu Bar' list."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("打开系统设置", "Open System Settings"))
        alert.addButton(withTitle: L("稍后处理", "Later"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.MenuBar-Settings")
        {
            NSWorkspace.shared.open(url)
        }
    }
}
