import AppKit
import SwiftUI
import XCTest
@testable import Dal

@MainActor
final class TerminologySettingsLayoutTests: XCTestCase {
    func testBuiltInListMaterializesOnlyVisibleControls() throws {
        _ = NSApplication.shared
        let entries = (0..<500).map {
            TerminologyEntry(canonicalText: String(format: "内置术语 %04d", $0), origin: .builtIn)
        }
        var document = TerminologyDocument.empty
        document.entries = entries
        var samples: [[String: Double]] = []
        for _ in 0..<3 {
            let started = CFAbsoluteTimeGetCurrent()
            let host = NSHostingView(rootView: TerminologySettingsTab(previewDocument: document))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 568, height: 532),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 568, height: 532)
            host.layoutSubtreeIfNeeded()
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1_000
            let controls = controlCount(in: host)
            samples.append(["layout_ms": elapsed, "native_controls": Double(controls)])
            XCTAssertGreaterThan(controls, 0, "确认原生内容已布局，避免空页面误判")
            XCTAssertLessThan(controls, 100, "首屏不能一次创建全部 500 个词条开关")
        }
        let data = try JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys])
        print("VOCABULARY_LAYOUT_SAMPLES " + String(decoding: data, as: UTF8.self))
    }

    private func controlCount(in view: NSView) -> Int {
        (view is NSControl ? 1 : 0) + view.subviews.reduce(0) { $0 + controlCount(in: $1) }
    }
}
