import SwiftUI

// MARK: - Audio Ripple

/// 固定保留当前时间轴样式的录音电平可视化。
struct AudioRipple: View {

    let meter: AudioLevelMeter
    @State private var smootherFast = LevelSmoother(timeConstant: 0)
    @State private var levelTimeline = LevelTimeline()

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                drawTimeline(context: &context, size: size, time: time)
            }
        }
        .drawingGroup()
    }

    // MARK: - Timeline Particles (scrolling history)

    private func drawTimeline(context: inout GraphicsContext, size: CGSize, time: Double) {
        let rawLevel = CGFloat(max(0.0, min(1.0, meter.current)))
        smootherFast.target = max(0.005, rawLevel)
        let smoothed = smootherFast.update(time: time)
        let levels = levelTimeline.update(time: time, currentLevel: smoothed)

        let center = size.height / 2
        let bufCount = levels.count
        let colCount = Int(size.width / 2) + 1

        for col in 0..<colCount {
            let xi = CGFloat(col) * 2
            let nx = xi / size.width

            let histIdx = min(Int(nx * CGFloat(bufCount - 1)), bufCount - 1)
            let histLevel = levels[histIdx]
            let amp = min(1.0, pow(max(0, (histLevel - 0.08) / 0.62), 0.85))

            let bandHalf = size.height * (0.03 + amp * 0.45)
            let posBright: CGFloat = 0.4 + pow(nx, 0.8) * 0.3
            let levelBright: CGFloat = 0.45 + amp * 0.35

            let cr: Double = 0.82 - Double(nx) * 0.42
            let cg: Double = 0.85 - Double(nx) * 0.25
            let coreColor = Color(red: cr, green: cg, blue: 1.0)

            for j in 0..<180 {
                let h1 = hash(col, j)
                let h2 = hash(col, j &+ 53)
                let h3 = hash(col, j &+ 137)

                let scatter = (h1 - 0.5) * 2
                let py = center + scatter * abs(scatter) * bandHalf

                let freq = 3.0 + Double(h2) * 10.0
                let twinkle: CGFloat = 0.45 + 0.55 * CGFloat(sin(time * freq + Double(h3) * .pi * 2))

                let baseOp = posBright * twinkle * levelBright
                guard baseOp > 0.02 else { continue }

                let dotR = CGRect(x: xi - 0.25, y: py - 0.25, width: 0.5, height: 0.5)
                context.fill(Circle().path(in: dotR), with: .color(coreColor.opacity(Double(min(1.0, baseOp)))))
            }
        }
    }

    private func hash(_ a: Int, _ b: Int) -> CGFloat {
        var h = a &* 374761393 &+ b &* 668265263
        h = (h ^ (h >> 13)) &* 1274126177
        h = h ^ (h >> 16)
        return CGFloat(abs(h) % 10000) / 10000.0
    }
}

/// Frame-rate-independent exponential smoothing for audio level.
private final class LevelSmoother {
    var current: CGFloat = 0
    var target: CGFloat = 0
    private var lastTime: Double = 0
    private let timeConstant: Double

    init(timeConstant: Double = 0.8) {
        self.timeConstant = timeConstant
    }

    func update(time: Double) -> CGFloat {
        if lastTime == 0 { lastTime = time; return current }
        let dt = min(time - lastTime, 0.05)
        lastTime = time
        if timeConstant <= 0 {
            current = target
        } else {
            let alpha = CGFloat(1.0 - exp(-dt / timeConstant))
            current += (target - current) * alpha
        }
        return current
    }
}

/// Scrolling level history: newest on right, drifts left over time.
/// Index 0 = oldest (leftmost), last = newest (rightmost).
private final class LevelTimeline {
    private static let bufferSize = 200
    private var levels: [CGFloat]
    private var lastTime: Double = 0
    private var accumulator: Double = 0
    private let scrollSpeed: Double = 50  // entries shifted per second

    init() {
        levels = Array(repeating: 0, count: Self.bufferSize)
    }

    func update(time: Double, currentLevel: CGFloat) -> [CGFloat] {
        if lastTime == 0 {
            lastTime = time
            return levels
        }
        let dt = min(time - lastTime, 0.05)
        lastTime = time

        accumulator += dt * scrollSpeed
        let shift = Int(accumulator)
        if shift > 0 {
            accumulator -= Double(shift)
            let actual = min(shift, Self.bufferSize)
            levels.removeFirst(actual)
            for _ in 0..<actual {
                levels.append(currentLevel)
            }
        }
        levels[levels.count - 1] = currentLevel
        return levels
    }
}
