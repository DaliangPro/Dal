import AppKit
import SwiftUI
import XCTest
@testable import Muse

final class FloatingBarLayoutTests: XCTestCase {
    func testSharedProgressDoesNotScrollBeforeTheShellIsFull() {
        for width in stride(from: CGFloat(40), through: 3000, by: 7) {
            let layout = HUDRecordingLayout(logicalWidth: width, widthReserve: 53, tailInset: 12)
            XCTAssertGreaterThanOrEqual(layout.capsuleWidth, 40)
            XCTAssertLessThanOrEqual(layout.capsuleWidth, 528)
            if layout.capsuleWidth < 528 {
                XCTAssertEqual(layout.textOffset, 0, accuracy: 0.001,
                               "外壳未展开到上限时，文字不能先向左滚动")
            } else {
                XCTAssertEqual(layout.presentedTextWidth + layout.textOffset,
                               layout.textViewportWidth - 12, accuracy: 0.001,
                               "满宽后，文字进度必须与同一帧的右侧留白对齐")
            }
        }
    }

    func testSharedProgressRemainsContinuousAtTheWidthLimit() {
        let before = HUDRecordingLayout(logicalWidth: 527.9, widthReserve: 53, tailInset: 12)
        let after = HUDRecordingLayout(logicalWidth: 528.1, widthReserve: 53, tailInset: 12)
        XCTAssertEqual(after.capsuleWidth - before.capsuleWidth, 0.1, accuracy: 0.001)
        XCTAssertEqual(after.textOffset - before.textOffset, -0.1, accuracy: 0.001)
    }

    @MainActor
    func testIncomingEdgeFadesBeforeAndAfterOverflow() throws {
        for overflow in [false, true] {
            let view = Color.red
                .frame(width: 100, height: 40)
                .mask(HUDTextEdgeMask(leadingFadeWidth: 4, trailingFadeWidth: 12,
                                      hasLeadingOverflow: overflow, viewportWidth: 100))
            let pixels = try renderPixels(view, width: 100, height: 40)
            let alpha = { (x: Int) in pixels[(20 * 100 + x) * 4 + 3] }
            XCTAssertGreaterThan(alpha(70), 250)
            XCTAssertGreaterThan(alpha(88), alpha(94))
            XCTAssertGreaterThan(alpha(94), alpha(99))
            XCTAssertLessThan(alpha(99), 30, "新字进入的一侧应渐隐，而非硬裁切")
            if overflow {
                XCTAssertLessThan(alpha(0), 80, "旧文字离开的一侧应渐隐")
            } else {
                XCTAssertGreaterThan(alpha(0), 250, "短文本的开头应保持清晰")
            }
        }
    }

    @MainActor
    func testStreamingTextStaysInsideNarrowAndWideViewports() throws {
        for width in [20, 80, 360] {
            for text in ["今天", String(repeating: "连续输入ABC", count: 20) + "最新尾部"] {
                let view = StreamingHUDText(text: text, color: .red, leadingFadeWidth: 4,
                                            trailingFadeWidth: 12)
                    .frame(width: CGFloat(width), height: 40)
                    .frame(width: 600, height: 80)
                let pixels = try renderPixels(view, width: 600, height: 80)
                let left = (600 - width) / 2
                var inside = 0
                var outside = 0
                for y in 0..<80 {
                    for x in 0..<600 where isRed(pixels, x: x, y: y, width: 600) {
                        if (left..<(left + width)).contains(x) && (20..<60).contains(y) { inside += 1 }
                        else { outside += 1 }
                    }
                }
                XCTAssertGreaterThan(inside, 5, "视窗内应保留可见文字")
                XCTAssertEqual(outside, 0, "文字及其阴影不可越过视窗")
            }
        }
    }

    @MainActor
    func testBurstTextUsesTheCurrentShellFrameForClippingAndFade() throws {
        // 新正文可以一次到达很长；显示范围必须仍停在本帧外壳内。
        let burst = String(repeating: "快速输入ABC，", count: 20)
        for progress in [CGFloat(40), 66, 90, 164, 320, 527.5, 528, 690, 1200] {
            let layout = HUDRecordingLayout(logicalWidth: progress, widthReserve: 53, tailInset: 12)
            let view = StreamingHUDText(text: burst, color: .red, leadingFadeWidth: 4,
                                        trailingFadeWidth: 12, recordingLayout: layout)
                .frame(width: layout.textViewportWidth, height: 40, alignment: .leading)
                .offset(x: 37)
                .frame(width: 600, height: 80, alignment: .leading)
            let pixels = try renderPixels(view, width: 600, height: 80)
            var inside = 0
            var outside = 0
            for y in 0..<80 {
                for x in 0..<600 where isRed(pixels, x: x, y: y, width: 600) {
                    if x >= 37 && CGFloat(x) < layout.capsuleWidth - 4 && (20..<60).contains(y) {
                        inside += 1
                    } else {
                        outside += 1
                    }
                }
            }
            XCTAssertEqual(outside, 0, "快速出字不可超过本帧外壳及4pt外侧安全留白：\(progress)")
            if layout.textViewportWidth > 20 {
                XCTAssertGreaterThan(inside, 5, "确保每一段展开及满宽滚动都实际绘制了文字")
            }
        }
    }

    @MainActor
    func testGlassClipsOversizedContentToTheCurrentShell() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("原生玻璃需要 macOS 26") }
        let view = CleanGlassCapsule(
            cornerRadius: 20, style: .regular, tintColor: nil,
            content: AnyView(Color.red.frame(width: 160, height: 60))
        )
        .frame(width: 40, height: 40)
        .frame(width: 200, height: 100)
        let pixels = try renderPixels(view, width: 200, height: 100)
        var inside = 0
        var outside = 0
        for y in 0..<100 {
            for x in 0..<200 where isRed(pixels, x: x, y: y, width: 200) {
                if (80..<120).contains(x) && (30..<70).contains(y) { inside += 1 }
                else { outside += 1 }
            }
        }
        XCTAssertGreaterThan(inside, 500, "确认内容实际被绘制，避免空图误判通过")
        XCTAssertEqual(outside, 0, "当前玻璃边界外不应出现内容像素")
    }

    @MainActor
    func testGlassRespectsOuterSizeWhenIndicatorHasLargerIntrinsicSize() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("原生玻璃需要 macOS 26")
        }
        _ = NSApplication.shared
        let host = NSHostingView(rootView:
            CleanGlassCapsule(
                cornerRadius: 20,
                style: .regular,
                tintColor: nil,
                content: AnyView(Color.clear.frame(width: 44, height: 44))
            )
            .frame(width: 40, height: 40)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        let glass = try XCTUnwrap(findGlass(in: host))
        XCTAssertEqual(glass.bounds.width, 40, accuracy: 0.5)
        XCTAssertEqual(glass.bounds.height, 40, accuracy: 0.5)
        XCTAssertEqual(glass.cornerRadius, min(glass.bounds.width, glass.bounds.height) / 2, accuracy: 0.5)
    }

    @MainActor
    func testCircleAndExpandedBarKeepTheSameHeightAndCenterLine() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("原生玻璃需要 macOS 26")
        }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousRegistration = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defaults.register(defaults: ["museGlassMinimal": true])
        defer { defaults.setVolatileDomain(previousRegistration, forName: UserDefaults.registrationDomain) }

        let state = DemoState()
        state.barPhase = .preparing
        let host = NSHostingView(rootView: FloatingBarView(state: state)
            .transaction { $0.disablesAnimations = true })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 180)

        try await settleLayout(host)
        let preparing = try XCTUnwrap(findGlass(in: host))
        XCTAssertEqual(preparing.bounds.width, 40, accuracy: 0.5)
        XCTAssertEqual(preparing.bounds.height, preparing.bounds.width, accuracy: 0.5)
        XCTAssertEqual(preparing.cornerRadius, 20, accuracy: 0.5)
        let sharedHeight = preparing.bounds.height
        let sharedCenterY = preparing.convert(preparing.bounds, to: host).midY

        state.barPhase = .recording
        try await settleLayout(host)
        let initial = try XCTUnwrap(findGlass(in: host))
        XCTAssertEqual(initial.bounds.width, 40, accuracy: 0.5)
        XCTAssertEqual(initial.bounds.height, initial.bounds.width, accuracy: 0.5)
        XCTAssertEqual(initial.bounds.height, sharedHeight, accuracy: 0.5)
        XCTAssertEqual(initial.convert(initial.bounds, to: host).midY, sharedCenterY, accuracy: 0.5)
        XCTAssertEqual(initial.cornerRadius, initial.bounds.height / 2, accuracy: 0.5)

        state.segments = [TranscriptionSegment(text: "今天下午三点讨论新版本", isConfirmed: false)]
        try await settleLayout(host)
        let expanded = try XCTUnwrap(findGlass(in: host))
        XCTAssertEqual(expanded.bounds.height, 40, accuracy: 0.5)
        XCTAssertEqual(expanded.bounds.height, sharedHeight, accuracy: 0.5)
        XCTAssertEqual(expanded.convert(expanded.bounds, to: host).midY, sharedCenterY, accuracy: 0.5)
        XCTAssertGreaterThan(expanded.bounds.width, expanded.bounds.height)
        XCTAssertEqual(expanded.cornerRadius, expanded.bounds.height / 2, accuracy: 0.5)

        state.segments = []
        try await settleLayout(host)
        let collapsed = try XCTUnwrap(findGlass(in: host))
        XCTAssertEqual(collapsed.bounds.width, 40, accuracy: 0.5)
        XCTAssertEqual(collapsed.bounds.height, collapsed.bounds.width, accuracy: 0.5)
        XCTAssertEqual(collapsed.bounds.height, sharedHeight, accuracy: 0.5)
        XCTAssertEqual(collapsed.convert(collapsed.bounds, to: host).midY, sharedCenterY, accuracy: 0.5)
        XCTAssertEqual(collapsed.cornerRadius, collapsed.bounds.height / 2, accuracy: 0.5)

        state.segments = [TranscriptionSegment(text: String(repeating: "快速长文本", count: 30), isConfirmed: false)]
        try await settleLayout(host)
        XCTAssertEqual(try XCTUnwrap(findGlass(in: host)).bounds.width, TF.barWidth, accuracy: 0.5)
        state.barPhase = .processing
        try await settleLayout(host)
        let processing = try XCTUnwrap(findGlass(in: host))
        XCTAssertLessThan(processing.bounds.width, TF.barWidth, "进入处理阶段不能沿用未截断的长文本宽度")
        XCTAssertEqual(processing.bounds.height, 40, accuracy: 0.5)
    }

    @MainActor
    func testProcessingHUDSizesToSavedPolishLabelAndFallsBackForEmptyLabel() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("原生玻璃需要 macOS 26") }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousRegistration = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defaults.register(defaults: ["museGlassMinimal": true])
        defer { defaults.setVolatileDomain(previousRegistration, forName: UserDefaults.registrationDomain) }

        let state = DemoState()
        state.currentMode = .formalWriting
        state.barPhase = .processing
        let host = NSHostingView(rootView: FloatingBarView(state: state)
            .transaction { $0.disablesAnimations = true })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 180)
        try await settleLayout(host)
        let defaultWidth = try XCTUnwrap(findGlass(in: host)).bounds.width

        state.currentMode.processingLabel = "正在整理我的口述内容，请稍候"
        try await settleLayout(host)
        XCTAssertGreaterThan(try XCTUnwrap(findGlass(in: host)).bounds.width, defaultWidth + 60,
                             "HUD 应按已保存的自定义文案布局，不能继续使用写死的默认文案")

        state.currentMode.processingLabel = " \n "
        try await settleLayout(host)
        XCTAssertEqual(try XCTUnwrap(findGlass(in: host)).bounds.width, defaultWidth, accuracy: 0.5,
                       "空白旧配置应回退为默认润色文案")
    }

    @MainActor
    func testProcessingHUDKeepsItsOwnWidthBeforeCopyFallbackExpands() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("原生玻璃需要 macOS 26") }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousRegistration = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defaults.register(defaults: ["museGlassMinimal": true])
        defer { defaults.setVolatileDomain(previousRegistration, forName: UserDefaults.registrationDomain) }

        let state = DemoState()
        state.barPhase = .processing
        state.segments = [TranscriptionSegment(text: String(repeating: "很短的输入", count: 40), isConfirmed: true)]
        let host = NSHostingView(rootView: FloatingBarView(state: state, styleOverride: .appleNative)
            .transaction { $0.disablesAnimations = true })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 180)

        try await settleLayout(host)
        let processingWidth = try XCTUnwrap(findGlass(in: host)).bounds.width
        XCTAssertLessThan(processingWidth, TF.barFallbackMinWidth,
                          "处理中不能按后续复制卡片预留宽度")

        state.barPhase = .copyFallback
        try await settleLayout(host)
        let fallbackWidth = try XCTUnwrap(findGlass(in: host)).bounds.width
        XCTAssertGreaterThanOrEqual(fallbackWidth, TF.barFallbackMinWidth)
        XCTAssertGreaterThan(fallbackWidth, processingWidth + 40,
                             "只有进入复制卡片后才应展开到宽卡片")
    }

    @MainActor
    func testPolishHUDKeepsItsWidthWhileWaitingForTheResult() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("原生玻璃需要 macOS 26") }
        _ = NSApplication.shared
        let state = AppState(initialModes: ProcessingMode.defaults)
        state.currentMode = .formalWriting
        state.startRecording()
        state.markRecordingReady()
        state.stopRecording()
        state.showVoicePolishStage(.polishing)
        let host = NSHostingView(rootView: FloatingBarView(state: state, styleOverride: .appleNative)
            .transaction { $0.disablesAnimations = true })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 180)
        try await settleLayout(host)
        let width = try XCTUnwrap(findGlass(in: host)).bounds.width

        try await Task.sleep(for: .milliseconds(1_400))
        try await settleLayout(host)

        XCTAssertEqual(state.barPhase, .processing)
        XCTAssertEqual(state.voicePolishStage, .polishing)
        XCTAssertEqual(try XCTUnwrap(findGlass(in: host)).bounds.width, width, accuracy: 0.5,
                       "持续等待模型时不能突然扩宽HUD并增加额外选项")
    }

    @MainActor
    private func settleLayout(_ host: NSView) async throws {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    @MainActor
    private func renderPixels<V: View>(_ view: V, width: Int, height: Int) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    private func isRed(_ pixels: [UInt8], x: Int, y: Int, width: Int) -> Bool {
        let offset = (y * width + x) * 4
        return pixels[offset] > 150 && pixels[offset + 1] < 80 && pixels[offset + 2] < 80 && pixels[offset + 3] > 150
    }

    @available(macOS 26.0, *)
    @MainActor
    private func findGlass(in view: NSView) -> NSGlassEffectView? {
        if let glass = view as? NSGlassEffectView { return glass }
        return view.subviews.lazy.compactMap { self.findGlass(in: $0) }.first
    }
}
