import AppKit
import XCTest
@testable import Dal

final class SettingsWindowTrafficLightAlignerTests: XCTestCase {
    @MainActor
    func testButtonsRemainInsideNativeTitlebarAfterRepeatedAlignment() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 736, height: 588),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // 复现安装版 SwiftUI 场景的 28pt 标题栏，而非测试窗口默认高度。
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let titlebar = try XCTUnwrap(close.superview)
        titlebar.setFrameSize(NSSize(width: titlebar.frame.width, height: 28))
        let frameView = try XCTUnwrap(window.contentView?.superview)
        var titlebarContainer: NSView = close
        while let parent = titlebarContainer.superview, parent !== frameView {
            titlebarContainer = parent
        }
        let content = try XCTUnwrap(window.contentView)
        frameView.addSubview(content, positioned: .above, relativeTo: nil)
        let aligner = SettingsWindowTrafficLightAligner(leadingInset: 16, topInset: 16)
        for _ in 0..<3 {
            aligner.align(in: window)
            let screenRect = window.convertToScreen(close.convert(close.bounds, to: nil))
            XCTAssertEqual(window.frame.maxY - screenRect.maxY, 16, accuracy: 0.5)
            XCTAssertEqual(screenRect.minX - window.frame.minX, 16, accuracy: 0.5)
            XCTAssertTrue(frameView.subviews.last === titlebarContainer, "全尺寸内容不得遮住标题栏")
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try XCTUnwrap(window.standardWindowButton(kind))
                let container = try XCTUnwrap(button.superview)
                XCTAssertTrue(container.bounds.contains(button.frame), "按钮被标题栏裁切：\(button.frame)，容器：\(container.bounds)")
            }
        }
    }
}
