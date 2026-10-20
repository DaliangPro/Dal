import AppKit
import SwiftUI

@MainActor
final class HUDDebugPresenter {
    private var hudDebugWindow: NSWindow?
    private var floatingHUDDebugBackdropWindow: NSWindow?

    func showHUDDebugWindow() {
        if let hudDebugWindow {
            hudDebugWindow.orderFrontRegardless()
            return
        }

        let window = HUDDebugPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 430),
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.backgroundColor = .clear
        window.contentView = NSHostingView(rootView: HUDDebugPreviewWindow())
        window.orderFrontRegardless()
        hudDebugWindow = window
    }

    func showFloatingHUDDebugDemo(appState: AppState) {
        showFloatingHUDDebugBackdrop()
        let text = "今天下午三点开会讨论新版本发布计划"
        appState.segments = [TranscriptionSegment(text: text, isConfirmed: !AppLaunchDebug.floatingHUDProcessingPhase)]
        appState.audioLevel.current = AppLaunchDebug.floatingHUDProcessingPhase ? 0 : 0.32
        appState.recordingStartDate = AppLaunchDebug.floatingHUDProcessingPhase ? nil : Date()
        appState.processingFinishTime = nil
        appState.feedbackMessage = L("已完成", "Done")
        if AppLaunchDebug.floatingHUDProcessingPhase {
            appState.barPhase = .processing
        } else if AppLaunchDebug.floatingHUDDonePhase {
            appState.barPhase = .done
        } else {
            appState.barPhase = .recording
        }
        appState.onShowPanel?()
    }

    private func showFloatingHUDDebugBackdrop() {
        if let floatingHUDDebugBackdropWindow {
            floatingHUDDebugBackdropWindow.orderFrontRegardless()
            return
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        floatingHUDDebugBackdropWindow = window
    }
}
