import AppKit
import SwiftUI

struct SettingsWindowConfigurator: NSViewRepresentable {
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let minimumContentHeight: CGFloat
    let trafficLightLeadingInset: CGFloat
    let trafficLightTopInset: CGFloat
    /// 当前外观选项：配置器主动应用窗口外观，修复 SwiftUI .preferredColorScheme(nil)
    /// 从「强制外观」切回「跟随系统」时不立即刷新、要等窗口激活才生效的毛病
    let appearance: SettingsAppearanceMode

    private var trafficLightAligner: SettingsWindowTrafficLightAligner {
        SettingsWindowTrafficLightAligner(
            leadingInset: trafficLightLeadingInset,
            topInset: trafficLightTopInset
        )
    }

    final class Coordinator {
        let sizeLocker = SettingsWindowSizeLocker()
        let trafficLightObserver = SettingsWindowTrafficLightAlignmentObserver()
        var lastAppearance: SettingsAppearanceMode?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        // 用 viewDidMoveToWindow 在窗口一就绪就同步设外观，早于首帧渲染——
        // 修复打开设置首帧用系统默认外观（深）、要点一下才刷成浅的问题（2026-06-22）
        context.coordinator.lastAppearance = appearance
        let view = WindowAwareView()
        view.onWindowChange = { window in
            configure(window: window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 切页等重渲染会反复触发 updateNSView；只有外观真变了才需重配置窗口，否则跳过——
        // 避免每次切页都重设窗口外观 + 排 8 个 asyncAfter 对齐红绿灯（卡顿源，2026-06-24）
        guard context.coordinator.lastAppearance != appearance else { return }
        context.coordinator.lastAppearance = appearance
        DispatchQueue.main.async {
            configure(window: nsView.window, coordinator: context.coordinator)
        }
    }

    private func configure(window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }

        // 主动应用外观（2026-06-20 修复）：选「跟随系统」时当场把窗口外观重置为 nil、立即跟随系统,
        // 不再等窗口下次激活——绕过 SwiftUI .preferredColorScheme(nil) 在 macOS 上不即时刷新的问题
        switch appearance.preferredColorScheme {
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .dark:  window.appearance = NSAppearance(named: .darkAqua)
        default:     window.appearance = nil
        }

        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.toolbar?.showsBaselineSeparator = false
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        trafficLightAligner.align(in: window)
        trafficLightAligner.alignAfterSystemLayout(in: window)
        coordinator.trafficLightObserver.attach(to: window, aligner: trafficLightAligner)

        coordinator.sizeLocker.lock(
            window: window,
            contentWidth: contentWidth,
            contentHeight: contentHeight,
            minimumContentHeight: minimumContentHeight
        )
        trafficLightAligner.align(in: window)
        trafficLightAligner.alignAfterSystemLayout(in: window)
    }
}

/// 在加入/移出窗口的瞬间（早于首帧渲染）回调，用于同步设置窗口外观
private final class WindowAwareView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
