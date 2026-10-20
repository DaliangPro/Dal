#if HUD_PERFORMANCE_PROBE
import AppKit
import Darwin
import SwiftUI

/// 仅专用编译开关启用；在日常数据初始化前运行，不采集麦克风或调用模型。
@MainActor
enum HUDPerformanceProbe {
    static var frames: [Double] = []
    static var lastTimelineDate: Date?
    static var sampling = false
    static var window: NSWindow?
    static var textSamples: [[String: Double]] = []
    static var indicatorMounts = 0

    static func recordText(width: CGFloat, presentedWidth: CGFloat, viewport: CGFloat, offset: CGFloat) {
        guard sampling else { return }
        textSamples.append(["time": CACurrentMediaTime(), "width": width,
                            "presented_width": presentedWidth, "viewport": viewport, "offset": offset])
    }

    static func recordIndicatorMount() {
        if sampling { indicatorMounts += 1 }
    }

    static func recordFrame(_ date: Date) {
        guard sampling, date != lastTimelineDate else { return }
        lastTimelineDate = date
        frames.append(CACurrentMediaTime())
    }

    static func runApplication() {
        UserDefaults.standard.register(defaults: ["museGlassMinimal": true])
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "HUD 性能验证"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ProbeView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private struct ProbeView: View {
        @State private var state = DemoState()
        @State private var status = "同一真实 HUD 组件，模拟连续文本更新"
        @State private var running = false

        var body: some View {
            VStack {
                Text(status).font(.system(size: 13))
                FloatingBarView(state: state).frame(width: 600, height: 180)
                Button("开始采样") { Task { await run() } }.disabled(running)
            }
            .frame(width: 640, height: 280)
        }

        private func run() async {
            running = true
            status = "采样中"
            state.stop()
            try? await Task.sleep(for: .seconds(1))
            frames = []
            frames.reserveCapacity(3000)
            textSamples = []
            indicatorMounts = 0
            lastTimelineDate = nil
            let start = CACurrentMediaTime()
            let cpuStart = cpuSeconds()
            sampling = true
            state.showFrozenRecordingPreview(text: "")
            state.segments = []
            try? await Task.sleep(for: .seconds(1))
            let text = String(repeating: "今天下午三点讨论新版本的发布计划，先检查语音识别，再检查文字输出和窗口动画，最后记录测试结果。", count: 5)
            let burstScenario = Bundle.main.object(forInfoDictionaryKey: "HUDProbeScenario") as? String == "burst"
            if burstScenario {
                for _ in 0..<6 {
                    state.segments = []
                    try? await Task.sleep(for: .milliseconds(500))
                    for count in [2, 4, 7, 11, 16, 24, 38, 64, 80, 100] {
                        state.segments = [TranscriptionSegment(text: String(text.prefix(count)), isConfirmed: false)]
                        try? await Task.sleep(for: .milliseconds(35))
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            } else {
              for index in 0..<100 {
                let count = 2 + index * 2 - (index == 65 ? 5 : 0)
                state.segments = [TranscriptionSegment(text: String(text.prefix(count)), isConfirmed: false)]
                state.audioLevel.current = Float(0.3 + 0.15 * sin(Double(index) * 0.3))
                try? await Task.sleep(for: .milliseconds(120))
              }
            }
            try? await Task.sleep(for: .milliseconds(400))
            sampling = false
            let duration = CACurrentMediaTime() - start
            let cpu = cpuSeconds() - cpuStart
            let intervals = zip(frames.dropFirst(), frames).map { ($0 - $1) * 1000 }.sorted()
            let stableScroll = zip(textSamples.dropFirst(), textSamples).filter {
                $0.0["viewport"]! > 400 && abs($0.0["viewport"]! - $0.1["viewport"]!) < 0.01
                    && $0.0["offset"]! < -1
            }
            let intermediateSteps = stableScroll.filter {
                $0.0["width"] == $0.1["width"] && abs($0.0["offset"]! - $0.1["offset"]!) > 0.01
            }.count
            let result: [String: Any] = [
                "scenario": burstScenario ? "burst" : "steady",
                "indicator_mounts": indicatorMounts,
                "intermediate_scroll_steps": intermediateSteps,
                "max_scroll_step_points": stableScroll.map { abs($0.0["offset"]! - $0.1["offset"]!) }.max() ?? 0,
                "text_samples": textSamples,
                "duration_seconds": duration, "view_updates": frames.count,
                "view_updates_per_second": Double(frames.count) / duration,
                "interval_p50_ms": intervals.isEmpty ? 0 : intervals[intervals.count / 2],
                "interval_p95_ms": intervals.isEmpty ? 0 : intervals[Int(Double(intervals.count - 1) * 0.95)],
                "interval_max_ms": intervals.last ?? 0,
                "intervals_over_25ms": intervals.filter { $0 > 25 }.count,
                "cpu_percent_one_core": cpu / duration * 100,
                "scope": "实际HUD组件的波形视图更新回调，不等同于屏幕呈现FPS",
                "screen_maximum_fps": window?.screen?.maximumFramesPerSecond ?? 0,
            ]
            if let directory = Bundle.main.object(forInfoDictionaryKey: "HUDProbeOutput") as? String {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("sample-\(UUID().uuidString).json")
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: url)
                }
            }
            status = String(format: "采样完成：%.1f 次/秒，P95 %.1f ms，CPU %.1f%%",
                            Double(frames.count) / duration,
                            intervals.isEmpty ? 0 : intervals[Int(Double(intervals.count - 1) * 0.95)], cpu / duration * 100)
            running = false
        }
    }
}
#endif
