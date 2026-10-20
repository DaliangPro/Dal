import AppKit
import XCTest
@testable import Dal

final class WindowActivityObserverTests: XCTestCase {
    @MainActor
    func testWindowCloseReopenAndOcclusionControlActivity() async throws {
        _ = NSApplication.shared
        let window = VisibilityTestWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let view = WindowActivityView()
        var changes: [Bool] = []
        view.onChange = { changes.append($0) }
        window.contentView = view
        try await Task.sleep(for: .milliseconds(20))

        window.visibleForTest = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertEqual(changes, [true])
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertEqual(changes, [true, false])
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(changes, [true, false, true])
        window.visibleForTest = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertEqual(changes, [true, false, true, false])

        view.detach()
        window.visibleForTest = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertEqual(changes, [true, false, true, false])
    }

    @MainActor
    func testStoppedDemoDoesNotRestartOrKeepAudioTimerRunning() async throws {
        let state = DemoState()
        state.startQuickModeDemo()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.barPhase, .recording)
        state.stop()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(state.barPhase, .hidden)
        XCTAssertTrue(state.segments.isEmpty)
        XCTAssertEqual(state.audioLevel.current, 0)
        XCTAssertNil(state.recordingStartDate)
    }
}

/// 使用真实通知与承载视图，只替换可见性读数；测试无需把窗口显示到用户屏幕。
@MainActor
private final class VisibilityTestWindow: NSWindow {
    var visibleForTest = false
    override var isVisible: Bool { visibleForTest }
    override var occlusionState: NSWindow.OcclusionState { visibleForTest ? [.visible] : [] }
}
