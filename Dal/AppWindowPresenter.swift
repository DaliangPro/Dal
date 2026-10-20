import AppKit
import SwiftUI

/// 窗口只由SwiftUI场景创建；场景动作就绪前的打开请求会保留。
@MainActor
final class AppWindowPresenter {
    private let windowID: String
    private var openAction: (() -> Void)?
    private var pendingOpen = false

    init(windowID: String) {
        self.windowID = windowID
    }

    func register(openAction: @escaping () -> Void) {
        self.openAction = openAction
        if pendingOpen {
            pendingOpen = false
            open()
        }
    }

    func open() {
        guard let openAction else {
            pendingOpen = true
            return
        }
        NSApp.setActivationPolicy(.regular)
        openAction()
        NSApp.activate(ignoringOtherApps: true)
        DebugFileLogger.log("openWindow: SwiftUI scene=\(windowID)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [windowID] in
            let visibleCount = NSApp.windows.filter {
                $0.identifier?.rawValue == windowID && $0.isVisible
            }.count
            DebugFileLogger.log("openWindow: scene=\(windowID) visible count=\(visibleCount)")
        }
    }
}

/// 命令菜单在窗口关闭后仍存在，为设置与引导持续提供openWindow动作。
struct AppWindowMenuCommands: View {
    @Environment(\.openWindow) private var openWindow
    let registerSettings: (@escaping () -> Void) -> Void
    let openSettings: () -> Void
    let registerSetup: (@escaping () -> Void) -> Void
    let openSetup: () -> Void

    var body: some View {
        let _ = registerSettings { openWindow(id: "settings") }
        let _ = registerSetup { openWindow(id: "setup") }
        Button(L("设置…", "Settings…"), action: openSettings)
            .keyboardShortcut(",", modifiers: .command)
        Button(L("使用引导", "Setup Guide"), action: openSetup)
    }
}
