import AppKit

struct SettingsWindowTrafficLightAligner {
    let leadingInset: CGFloat
    let topInset: CGFloat

    func align(in window: NSWindow) {
        guard
            let closeButton = window.standardWindowButton(.closeButton),
            let minimizeButton = window.standardWindowButton(.miniaturizeButton),
            let zoomButton = window.standardWindowButton(.zoomButton)
        else { return }

        // 全尺寸内容视图可能被 SwiftUI 排在标题栏之上，保持原生按钮所在容器位于内容上方。
        if let frameView = window.contentView?.superview {
            var titlebar: NSView = closeButton
            while let parent = titlebar.superview, parent !== frameView { titlebar = parent }
            if titlebar.superview === frameView, frameView.subviews.last !== titlebar {
                frameView.addSubview(titlebar, positioned: .above, relativeTo: nil)
            }
        }

        // 为原有顶距补足容器高度，不能通过抬高按钮来规避标题栏裁切。
        let requiredHeight = topInset + max(closeButton.frame.height, minimizeButton.frame.height, zoomButton.frame.height)
        if let frameView = window.contentView?.superview {
            var containers: [NSView] = []
            var ancestor = closeButton.superview
            while let view = ancestor, view !== frameView {
                containers.append(view)
                ancestor = view.superview
            }
            if ancestor === frameView {
                for container in containers.reversed() where container.frame.height < requiredHeight {
                    guard let parent = container.superview else { continue }
                    var frame = container.frame
                    frame.origin.y = parent.bounds.maxY - requiredHeight
                    frame.size.height = requiredHeight
                    container.frame = frame
                }
            }
        }

        let closeScreenRect = window.convertToScreen(closeButton.convert(closeButton.bounds, to: nil))
        let xDelta = window.frame.minX + leadingInset - closeScreenRect.minX
        let yDelta = window.frame.maxY - topInset - closeScreenRect.maxY
        for button in [closeButton, minimizeButton, zoomButton] {
            button.setFrameOrigin(NSPoint(x: button.frame.minX + xDelta, y: button.frame.minY + yDelta))
        }
    }

    func alignAfterSystemLayout(in window: NSWindow) {
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            align(in: window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak window] in
            guard let window else { return }
            align(in: window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak window] in
            guard let window else { return }
            align(in: window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak window] in
            guard let window else { return }
            align(in: window)
        }
    }
}

final class SettingsWindowTrafficLightAlignmentObserver {
    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var aligner: SettingsWindowTrafficLightAligner?

    deinit {
        detach()
    }

    func attach(to window: NSWindow, aligner: SettingsWindowTrafficLightAligner) {
        self.aligner = aligner

        if observedWindow !== window {
            detach()
            observedWindow = window
            addObservers(to: window)
        }

        realign(in: window)
    }

    private func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        observedWindow = nil
    }

    private func addObservers(to window: NSWindow) {
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didMoveNotification,
            NSWindow.didBecomeKeyNotification
        ]

        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.realign(in: window)
            }
        }
    }

    private func realign(in window: NSWindow) {
        guard let aligner else { return }
        aligner.align(in: window)
        aligner.alignAfterSystemLayout(in: window)
    }
}
