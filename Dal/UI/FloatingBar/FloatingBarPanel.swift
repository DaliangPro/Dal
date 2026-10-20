import AppKit
import SwiftUI

// MARK: - NSPanel Subclass

/// Non-activating floating panel that never steals focus from the target app.
final class FloatingBarPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func positionAtBottomCenter() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.origin.y + TF.barBottomOffset - TF.barOuterInset
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Controller

/// Manages the floating bar panel lifecycle.
/// All visual styling is handled in SwiftUI (FloatingBarView).
@MainActor
final class FloatingBarController {

    private let panel: FloatingBarPanel
    private let state: AppState
    private let panelSize: NSSize
    private var visibilityGeneration = 0

    init(state: AppState) {
        self.state = state

        let inset = TF.barOuterInset
        let contentHeight = max(TF.barHeight, TF.barFallbackHeight)
        let frame = NSRect(x: 0, y: 0, width: TF.barWidth + inset * 2, height: contentHeight + inset * 2)
        panelSize = frame.size
        panel = FloatingBarPanel(contentRect: frame)

        let barView = FloatingBarView<AppState>(state: state)
        let hosting = NSHostingView(rootView: barView)
        hosting.layer?.backgroundColor = .clear
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]

        panel.contentView = hosting
        panel.setFrame(frame, display: false)
        panel.positionAtBottomCenter()

        state.onShowPanel = { [weak self] in self?.show() }
        state.onHidePanel = { [weak self] in self?.hide() }
    }

    func show() {
        visibilityGeneration &+= 1
        let myGeneration = visibilityGeneration
        DebugFileLogger.log("floating bar show gen=\(myGeneration) visible=\(panel.isVisible) alpha=\(panel.alphaValue)")

        panel.setContentSize(panelSize)
        panel.setFrame(NSRect(origin: panel.frame.origin, size: panelSize), display: false)
        panel.positionAtBottomCenter()
        if !panel.isVisible {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        } completionHandler: {
            MainActor.assumeIsolated {
                guard self.visibilityGeneration == myGeneration else {
                    DebugFileLogger.log("floating bar show completion skipped gen=\(myGeneration) active=\(self.visibilityGeneration)")
                    return
                }
                self.panel.alphaValue = 1
            }
        }
    }

    func hide() {
        visibilityGeneration &+= 1
        let myGeneration = visibilityGeneration
        DebugFileLogger.log("floating bar hide gen=\(myGeneration) visible=\(panel.isVisible) alpha=\(panel.alphaValue)")

        let panelRef = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelRef.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard self.visibilityGeneration == myGeneration else {
                    DebugFileLogger.log("floating bar hide completion skipped gen=\(myGeneration) active=\(self.visibilityGeneration)")
                    return
                }
                DebugFileLogger.log("floating bar orderOut gen=\(myGeneration)")
                panelRef.orderOut(nil)
            }
        })
    }
}
