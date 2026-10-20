import AppKit
import SwiftUI

/// 原生窗口关闭或被遮挡不一定触发 SwiftUI onDisappear，演示必须显式跟随窗口可见性。
struct WindowActivityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowActivityView {
        let view = WindowActivityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WindowActivityView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: WindowActivityView, coordinator: ()) {
        view.detach()
    }
}

final class WindowActivityView: NSView {
    var onChange: (Bool) -> Void = { _ in }
    private var observers: [NSObjectProtocol] = []
    private var active = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.refreshActivity()
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.setActive(false)
        })
        // 不在 SwiftUI 正在挂载视图时同步修改演示状态。
        DispatchQueue.main.async { [weak self] in self?.refreshActivity() }
    }

    private func refreshActivity() {
        setActive(window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false)
    }

    private func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        onChange(value)
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        setActive(false)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
