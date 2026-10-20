import SwiftUI

// MARK: - Recording Indicators

struct PreparingDot: View {

    var color: Color = TF.recording

    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.16), lineWidth: 1.6)
                .frame(width: 16, height: 16)

            Circle()
                .trim(from: 0.16, to: 0.76)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: 26, height: 26)
        .onAppear {
            rotation = 0
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

struct AnimatedRecordingIndicatorCluster<Content: View>: View {

    let audioLevel: AudioLevelMeter
    let recordingStartDate: Date?
    let content: (_ activity: CGFloat, _ time: TimeInterval, _ flow: CGFloat) -> Content

    var body: some View {
        TimelineView(.animation) { timeline in
            #if HUD_PERFORMANCE_PROBE
            let _ = HUDPerformanceProbe.recordFrame(timeline.date)
            #endif
            let time = max(
                0,
                timeline.date.timeIntervalSinceReferenceDate
                - (recordingStartDate?.timeIntervalSinceReferenceDate ?? timeline.date.timeIntervalSinceReferenceDate)
            )
            let flow = CGFloat((time * 0.72 + 0.5).truncatingRemainder(dividingBy: 1.0))
            let rawLevel = CGFloat(max(0.0, min(1.0, audioLevel.current)))
            let activity = 0.26 + pow(rawLevel, 0.72) * 0.74

            content(activity, time, flow)
        }
        #if HUD_PERFORMANCE_PROBE
        .onAppear { HUDPerformanceProbe.recordIndicatorMount() }
        #endif
    }
}

/// 波形和光晕在画布中一次绘制，避免每帧重建多层 SwiftUI 布局与阴影视图。
struct RecordingDot: View {
    let time: Double
    let activity: CGFloat
    let flow: CGFloat
    var style: HUDStyle = .appleNative

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            if style == .appleNative {
                var glow = context
                glow.translateBy(x: (size.width - 30) / 2, y: (size.height - 20) / 2)
                drawSoftGlow(in: glow)
            }
            var stripes = context
            stripes.translateBy(x: (size.width - 24) / 2, y: (size.height - 14.2) / 2)
            drawStripes(in: stripes)
        }
        .frame(width: TF.barHeight, height: TF.barHeight)
        .allowsHitTesting(false)
    }

    private func drawSoftGlow(in context: GraphicsContext) {
        var base = context
        base.blendMode = .screen
        base.addFilter(.blur(radius: 8))
        base.fill(
            Path(roundedRect: CGRect(x: 0.6, y: 4.6, width: 28.8, height: 10.8), cornerRadius: 5.4),
            with: .linearGradient(Gradient(colors: [
                Color(red: 0.16, green: 0.76, blue: 1).opacity(0.08 + Double(activity) * 0.06),
                Color(red: 0.12, green: 0.94, blue: 0.92).opacity(0.10 + Double(activity) * 0.07),
                Color(red: 0.30, green: 1, blue: 0.74).opacity(0.06 + Double(activity) * 0.05),
            ]), startPoint: CGPoint(x: 0, y: 10), endPoint: CGPoint(x: 30, y: 10))
        )
        var soft = context
        soft.blendMode = .screen
        drawRecordingGlow(in: soft, center: CGPoint(x: 30 * (0.16 + flow * 0.18), y: 9.6),
                          size: CGSize(width: 14.4, height: 18.4), radius: 10.2, blur: 5,
                          colors: [Color(red: 0.18, green: 0.80, blue: 1).opacity(0.08 + Double(activity) * 0.06), .clear])
        drawRecordingGlow(in: soft, center: CGPoint(x: 30 * (0.54 + flow * 0.12), y: 11.2),
                          size: CGSize(width: 12.6, height: 16.4), radius: 9, blur: 5,
                          colors: [Color(red: 0.22, green: 1, blue: 0.78).opacity(0.07 + Double(activity) * 0.05), .clear])
    }

    private func drawStripes(in context: GraphicsContext) {
        let width: CGFloat = 24
        let height: CGFloat = 14.2
        let barWidth = width / 11
        let gap = barWidth * 0.55
        let startX = (width - 5 * barWidth - 4 * gap) / 2
        var mask = Path()
        for (index, ratio) in [0.52, 0.82, 0.68, 0.90, 0.60].enumerated() {
            let pulse = 0.88 + sin(time * 2.2 + Double(index) * 0.55) * 0.08
            let barHeight = height * ratio * pulse * (0.78 + activity * 0.30)
            let rect = CGRect(x: startX + CGFloat(index) * (barWidth + gap), y: (height - barHeight) / 2,
                              width: barWidth, height: barHeight)
            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
            mask.addPath(path)
            let drift = Double(flow) * 0.18 + Double(index) * 0.03
            let distance = abs(CGFloat(index) - flow * 4)
            var bar = context
            if style == .appleNative {
                bar.addFilter(.shadow(color: Color(red: 0.18, green: 0.96, blue: 0.84)
                    .opacity(max(0.16, 0.31 - Double(distance) * 0.045)), radius: 3.8))
            }
            bar.fill(path, with: .linearGradient(Gradient(colors: [
                Color(red: 0.12, green: 0.72, blue: 1).opacity(0.90 - drift * 0.20),
                Color(red: 0.08, green: 0.90, blue: 0.94),
                (index >= 3 ? Color(red: 0.42, green: 1, blue: 0.66) : Color(red: 0.22, green: 1, blue: 0.72))
                    .opacity(0.92 + drift * 0.06),
            ]), startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }
        guard style == .appleNative else { return }
        var highlight = context
        highlight.clip(to: mask)
        highlight.blendMode = .screen
        highlight.addFilter(.blur(radius: 3.2))
        highlight.translateBy(x: width * (0.20 + flow * 0.60), y: height / 2)
        highlight.rotate(by: .degrees(-12))
        let rect = CGRect(x: -width * 0.12, y: -height * 0.7, width: width * 0.24, height: height * 1.4)
        highlight.fill(Path(rect), with: .linearGradient(Gradient(colors: [
            .clear, .white.opacity(0.32), Color(red: 0.34, green: 1, blue: 0.80).opacity(0.22), .clear,
        ]), startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
    }
}

struct RecordingGlassInnerGlow: View {
    let activity: CGFloat
    let time: Double

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            var field = context
            field.blendMode = .screen
            field.opacity = 0.92
            let source = CGPoint(x: 22, y: size.height / 2)
            let phase = time * 0.74
            let intensity = 0.55 + activity * 0.45
            let corePulse = 0.82 + 0.18 * sin(phase)
            let fieldPulse = 0.84 + 0.16 * sin(phase * 0.76 + 0.9)
            drawRecordingGlow(in: field,
                center: CGPoint(x: source.x + 1.4 * cos(phase * 0.38 + 0.3), y: source.y + 0.9 * sin(phase * 0.34 + 0.6)),
                size: CGSize(width: 28, height: 28), radius: 18, blur: 6,
                colors: [Color(red: 0.10, green: 0.80, blue: 1).opacity(0.16 * intensity * corePulse),
                         Color(red: 0.10, green: 0.96, blue: 0.92).opacity(0.09 * intensity * corePulse), .clear])
            drawRecordingGlow(in: field,
                center: CGPoint(x: source.x + 2.2 * cos(phase * 0.22 + 0.8), y: source.y + 1.6 * sin(phase * 0.26 + 0.1)),
                size: CGSize(width: 40, height: 40), radius: 24, blur: 11,
                colors: [Color(red: 0.10, green: 0.78, blue: 1).opacity(0.08 * intensity * fieldPulse),
                         Color(red: 0.10, green: 0.96, blue: 0.92).opacity(0.05 * intensity * fieldPulse), .clear])
            drawRecordingGlow(in: field,
                center: CGPoint(x: source.x + 3.2 + 2.8 * cos(phase * 0.18 + 1), y: source.y + 0.4 + 1.8 * sin(phase * 0.24 + 0.7)),
                size: CGSize(width: 52, height: 36), radius: 28, blur: 14, rotation: -14 + sin(phase * 0.21) * 6,
                colors: [Color(red: 0.10, green: 0.82, blue: 1).opacity(0.07 * intensity * fieldPulse),
                         Color(red: 0.10, green: 0.96, blue: 0.92).opacity(0.04 * intensity * fieldPulse), .clear])
            for blob in recordingGlowBlobs {
                let angle = phase * blob.speed + blob.offset
                drawRecordingGlow(in: field,
                    center: CGPoint(x: source.x + blob.radiusX * cos(angle), y: source.y + blob.radiusY * sin(angle)),
                    size: CGSize(width: blob.size, height: blob.size), radius: blob.size / 2, blur: blob.blur,
                    colors: [Color(red: 0.12, green: 0.76, blue: 1).opacity(blob.blue * intensity),
                             Color(red: 0.10, green: 0.94, blue: 0.92).opacity(blob.aqua * intensity), .clear])
            }
        }
        .allowsHitTesting(false)
    }
}

private let recordingGlowBlobs: [(size: CGFloat, radiusX: CGFloat, radiusY: CGFloat, speed: Double, offset: Double, blue: Double, aqua: Double, blur: CGFloat)] = [
    (19, 7, 6, 0.44, 2.5, 0.08, 0.03, 7),
    (17, 6, 8, 0.38, 4.0, 0.04, 0.05, 7),
    (22, 10, 7, 0.30, 5.2, 0.03, 0.07, 9),
    (18, 9, 8, 0.34, 0.8, 0.03, 0.05, 8),
    (15, 12, 5, 0.26, 0.2, 0.02, 0.04, 6),
]

private func drawRecordingGlow(in context: GraphicsContext, center: CGPoint, size: CGSize,
                               radius: CGFloat, blur: CGFloat, rotation: Double = 0, colors: [Color]) {
    var glow = context
    glow.translateBy(x: center.x, y: center.y)
    glow.rotate(by: .degrees(rotation))
    glow.addFilter(.blur(radius: blur))
    glow.fill(Path(ellipseIn: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)),
              with: .radialGradient(Gradient(colors: colors), center: .zero, startRadius: 0, endRadius: radius))
}
