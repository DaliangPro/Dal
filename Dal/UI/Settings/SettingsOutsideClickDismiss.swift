import AppKit
import SwiftUI

private struct SettingsScreenFrameReader: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> FrameReportingView {
        let view = FrameReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: FrameReportingView, context: Context) {
        nsView.onChange = onChange
        nsView.scheduleReport()
    }

    final class FrameReportingView: NSView {
        var onChange: ((CGRect) -> Void)?
        private var lastFrame = CGRect.null

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleReport()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scheduleReport()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            scheduleReport()
        }

        override func layout() {
            super.layout()
            scheduleReport()
        }

        func scheduleReport() {
            DispatchQueue.main.async { [weak self] in
                self?.reportFrame()
            }
        }

        private func reportFrame() {
            guard let window else { return }
            let rectInWindow = convert(bounds, to: nil)
            let screenFrame = window.convertToScreen(rectInWindow)
            guard screenFrame != lastFrame else { return }
            lastFrame = screenFrame
            onChange?(screenFrame)
        }
    }
}

private struct SettingsOutsideClickDismissView: NSViewRepresentable {
    let isActive: Bool
    let allowedFrames: [CGRect]
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            isActive: isActive,
            allowedFrames: allowedFrames,
            onDismiss: onDismiss
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private var monitor: Any?
        private var isActive = false
        private var allowedFrames: [CGRect] = []
        private var onDismiss: (() -> Void)?

        func update(
            isActive: Bool,
            allowedFrames: [CGRect],
            onDismiss: @escaping () -> Void
        ) {
            self.isActive = isActive
            self.allowedFrames = allowedFrames
                .filter { !$0.isNull && !$0.isEmpty }
                .map { $0.insetBy(dx: -2, dy: -2) }
            self.onDismiss = onDismiss

            if isActive {
                start()
            } else {
                stop()
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent {
            guard isActive else { return event }
            let screenPoint = screenLocation(for: event)
            if allowedFrames.contains(where: { $0.contains(screenPoint) }) {
                return event
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive else { return }
                self.onDismiss?()
            }
            return event
        }

        private func screenLocation(for event: NSEvent) -> CGPoint {
            if let window = event.window {
                return window.convertPoint(toScreen: event.locationInWindow)
            }
            return NSEvent.mouseLocation
        }

        deinit {
            stop()
        }
    }
}

extension View {
    func settingsScreenFrame(_ frame: Binding<CGRect>) -> some View {
        background {
            SettingsScreenFrameReader { newFrame in
                frame.wrappedValue = newFrame
            }
            .allowsHitTesting(false)
        }
    }

    func settingsDismissOnOutsideClick(
        isActive: Bool,
        allowedFrames: [CGRect],
        onDismiss: @escaping () -> Void
    ) -> some View {
        background {
            SettingsOutsideClickDismissView(
                isActive: isActive,
                allowedFrames: allowedFrames,
                onDismiss: onDismiss
            )
            .allowsHitTesting(false)
        }
    }
}
