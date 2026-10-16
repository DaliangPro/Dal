import AppKit
import SwiftUI
import XCTest
@testable import Muse

final class HUDStyleTests: XCTestCase {
    func testMissingOrUnknownPreferenceKeepsNativeAppearance() {
        XCTAssertEqual(HUDStyle.resolved(nil), .appleNative)
        XCTAssertEqual(HUDStyle.resolved("future-style"), .appleNative)
        XCTAssertEqual(HUDStyle.resolved("ink"), .ink)
    }

    @MainActor
    func testClosingSingleRunPreviewCancelsDelayedStateChanges() async throws {
        let state = DemoState()
        state.playQuickModeDemoOnce()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.barPhase, .recording)
        state.stop()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(state.barPhase, .hidden)
        XCTAssertTrue(state.segments.isEmpty)
        XCTAssertEqual(state.audioLevel.current, 0)
    }

    @MainActor
    func testInkSurfaceIsOpaqueAndFlatAtEverySize() throws {
        for (width, height) in [(40, 40), (260, 40), (528, 40), (360, 154)] {
            let renderer = ImageRenderer(content: InkHUDSurface(cornerRadius: 20)
                .frame(width: CGFloat(width), height: CGFloat(height)))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress,
                    width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            let reference = (height / 2 * width + width / 2) * 4
            for y in 4..<(height - 4) {
                for x in 20..<(width - 20) {
                    let offset = (y * width + x) * 4
                    XCTAssertEqual(pixels[offset + 3], 255, "实心区域不能透出桌面")
                    XCTAssertEqual(Array(pixels[offset..<(offset + 3)]),
                                   Array(pixels[reference..<(reference + 3)]), "底色不能包含玻璃高光或渐变")
                }
            }
            XCTAssertEqual(pixels[reference + 3], 255)
            XCTAssertEqual(pixels[3], 0, "圆角外部仍应透明")
        }
    }

    @MainActor
    func testInkNeverCreatesGlassOrBlurViewsAcrossPhases() async throws {
        _ = NSApplication.shared
        let state = DemoState()
        let host = NSHostingView(rootView: FloatingBarView(state: state, styleOverride: .ink)
            .transaction { $0.disablesAnimations = true })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        defer { state.stop() }
        for phase in [FloatingBarPhase.preparing, .recording, .processing, .done, .error, .copyFallback] {
            state.barPhase = phase
            state.segments = [TranscriptionSegment(text: "把此刻的想法清晰留下来", isConfirmed: false)]
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertFalse(containsMaterial(in: host), "墨色各阶段都不应创建玻璃或背景模糊视图")
        }
    }

    @MainActor
    private func containsMaterial(in view: NSView) -> Bool {
        if view is NSVisualEffectView { return true }
        if #available(macOS 26.0, *), view is NSGlassEffectView { return true }
        return view.subviews.contains { containsMaterial(in: $0) }
    }

    @MainActor
    func testLearningPairsFitRenderedHUD() throws {
        let single = [TerminologyCorrectionCandidate(alias: "cloud", canonical: "Claude")]
        let multiple = single + [TerminologyCorrectionCandidate(alias: "Type less", canonical: "Typeless")]
        let long = [TerminologyCorrectionCandidate(
            alias: String(repeating: "识别错词", count: 16), canonical: String(repeating: "正确写法", count: 16)
        )]
        let examples: [(String, AutomaticLearningFeedback)] = [
            ("single", .learned(single, hasConflict: false)),
            ("multiple", .learned(multiple, hasConflict: false)),
            ("long", .learned(long, hasConflict: false)),
            ("conflict", .learned(single, hasConflict: true))
        ]
        for (name, feedback) in examples {
            let state = DemoState()
            state.feedbackMessage = feedback.hudMessage
            state.barPhase = .done
            let textWidth = (feedback.hudMessage as NSString).size(withAttributes: [.font: TF.hudNSFontTitle]).width
            XCTAssertLessThanOrEqual(textWidth + 84, TF.barWidth, "\(name)：两端文字不能超出 HUD 面板")
            let renderer = ImageRenderer(content: FloatingBarView(state: state, styleOverride: .ink)
                .frame(width: 576, height: 120)
                .background(Color.white)
                .transaction { $0.disablesAnimations = true })
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            if let path = ProcessInfo.processInfo.environment["MUSE_LEARNING_FEEDBACK_PREVIEW_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent(name + ".png"))
            }
            state.stop()
        }
    }
}
