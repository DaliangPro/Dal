import AppKit

/// app 级外观管理：启动时就把 NSApp.appearance 设好，让设置等窗口创建即继承正确外观，
/// 消除「打开首帧用系统默认深色、点一下才变浅」。system 模式显式取系统外观（不依赖 app
/// 启动早期可能尚未同步的 NSApp.effectiveAppearance），并监听系统切换实时跟随。
@MainActor
enum AppearanceController {
    private static var systemThemeObserver: NSObjectProtocol?

    /// app 启动调用一次：应用外观 + 注册系统外观变化监听
    static func start() {
        apply()
        guard systemThemeObserver == nil else { return }
        systemThemeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { apply() }
        }
    }

    /// 按「设置」里的外观偏好设 app 级外观；偏好变化时也应调用
    static func apply() {
        let mode = SettingsAppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: "tf_settingsAppearance") ?? ""
        ) ?? .system
        switch mode.preferredColorScheme {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:     NSApp.appearance = NSAppearance(named: isSystemDark ? .darkAqua : .aqua)
        }
    }

    /// 读全局域系统外观，比 app 启动早期的 NSApp.effectiveAppearance 更可靠
    private static var isSystemDark: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String == "Dark"
    }
}
