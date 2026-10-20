import SwiftUI

struct HUDDebugPreviewWindow: View {

    @State private var demoState = DemoState()
    private var usesDarkBackground: Bool { AppLaunchDebug.hudDemoDarkBackground }
    private var usesStaticBackground: Bool { AppLaunchDebug.hudDemoStaticBackground }
    private var usesFrozenRecording: Bool { AppLaunchDebug.hudDemoFrozenRecording }
    private var usesSpacingCompare: Bool { AppLaunchDebug.hudDemoSpacingCompare }

    var body: some View {
        Group {
            if usesSpacingCompare {
                spacingCompareContent
            } else {
                defaultPreviewContent
            }
        }
    }

    private var debugSubtitle: String {
        if usesFrozenRecording && usesStaticBackground {
            return "真实 FloatingBarView + 纯黑静态背景（冻结录音展开态）"
        }
        if usesStaticBackground {
            return "真实 FloatingBarView + 纯黑静态背景"
        }
        return "真实 FloatingBarView + 受控动态背景"
    }

    private var debugFooter: String {
        if usesFrozenRecording && usesStaticBackground {
            return "只用于验证纯黑背景下录音展开态玻璃壳本体的稳定表现"
        }
        if usesStaticBackground {
            return "只用于验证纯黑背景下玻璃壳本体的静态表现"
        }
        return "只用于验证玻璃是否会对经过的高对比背景做被动响应"
    }

    private var defaultPreviewContent: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("HUD 调试预览")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(usesDarkBackground ? .white : .primary)
                Text(debugSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(usesDarkBackground ? Color.white.opacity(0.68) : .secondary)
            }

            ZStack {
                PassiveGlassDebugBackdrop(
                    usesDarkBackground: usesDarkBackground,
                    usesStaticBackground: usesStaticBackground
                )
                .clipShape(RoundedRectangle(cornerRadius: TF.settingsPrimaryCardCornerRadius, style: .continuous))

                FloatingBarView<DemoState>(state: demoState)
                    .frame(maxWidth: 420)
            }
            .frame(width: 760, height: 250)
            .clipShape(RoundedRectangle(cornerRadius: TF.settingsPrimaryCardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: TF.settingsPrimaryCardCornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            }

            Text(debugFooter)
                .font(.system(size: 12))
                .foregroundStyle(usesDarkBackground ? Color.white.opacity(0.62) : .secondary)
        }
        .padding(30)
        .frame(width: 860, height: 430)
        .background(usesDarkBackground ? Color.black : Color.white)
        .onAppear {
            if usesFrozenRecording {
                demoState.showFrozenRecordingPreview(text: "今天下午三点开会讨论新版本发布计划")
            } else {
                demoState.startQuickModeDemo()
            }
        }
        .onDisappear { demoState.stop() }
    }

    private var spacingCompareContent: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("录音态文字左右位置确认")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(usesDarkBackground ? .white : .primary)
                Text("真实 FloatingBarView 组件对照，不是手画示意。")
                    .font(.system(size: 13))
                    .foregroundStyle(usesDarkBackground ? Color.white.opacity(0.68) : .secondary)
            }

            ZStack {
                PassiveGlassDebugBackdrop(
                    usesDarkBackground: usesDarkBackground,
                    usesStaticBackground: true
                )
                .clipShape(RoundedRectangle(cornerRadius: TF.settingsPrimaryCardCornerRadius, style: .continuous))

                VStack(spacing: 34) {
                    FrozenRecordingPreviewRow(title: "刚出字", text: "今天")
                    FrozenRecordingPreviewRow(title: "拉宽中", text: "今天下午三点")
                    FrozenRecordingPreviewRow(title: "开始左吞", text: "今天下午三点开会讨论新版本发布计划，下周再同步，并补充时间安排与负责人信息")
                }
                .padding(.vertical, 24)
            }
            .frame(width: 900, height: 420)
            .clipShape(RoundedRectangle(cornerRadius: TF.settingsPrimaryCardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: TF.settingsPrimaryCardCornerRadius, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            }

            Text("只看文字在“吞字边界”和右侧壳边之间的视觉位置，不讨论材质。")
                .font(.system(size: 12))
                .foregroundStyle(usesDarkBackground ? Color.white.opacity(0.62) : .secondary)
        }
        .padding(30)
        .frame(width: 980, height: 560)
        .background(usesDarkBackground ? Color.black : Color.white)
    }
}

private struct FrozenRecordingPreviewRow: View {
    let title: String
    let text: String

    @State private var demoState = DemoState()

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.78))
            FloatingBarView<DemoState>(state: demoState)
                .frame(maxWidth: 620)
        }
        .onAppear {
            demoState.showFrozenRecordingPreview(text: text)
        }
        .onDisappear {
            demoState.stop()
        }
    }
}

private struct PassiveGlassDebugBackdrop: View {
    let usesDarkBackground: Bool
    let usesStaticBackground: Bool

    var body: some View {
        Group {
            if usesStaticBackground {
                Canvas(opaque: true, rendersAsynchronously: true) { context, size in
                    drawDebugBackdropBase(in: context, size: size)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    Canvas(opaque: true, rendersAsynchronously: true) { context, size in
                        let sceneRect = CGRect(origin: .zero, size: size)
                        drawDebugBackdropBase(in: context, size: size)
                        drawDebugBackdropBand(in: context, size: size, time: time, sceneRect: sceneRect)
                    }
                }
            }
        }
    }

    private func drawDebugBackdropBase(in context: GraphicsContext, size: CGSize) {
        let baseRect = CGRect(origin: .zero, size: size)
        if usesDarkBackground {
            if usesStaticBackground {
                context.fill(Path(baseRect), with: .color(.black))
                return
            }
            context.fill(
                Path(baseRect),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.06, green: 0.07, blue: 0.09),
                        Color.black,
                    ]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        } else {
            context.fill(
                Path(baseRect),
                with: .linearGradient(
                    Gradient(colors: [
                        Color.white,
                        Color(red: 0.96, green: 0.97, blue: 0.99),
                    ]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }

        let gridColor = usesDarkBackground ? Color.white.opacity(0.055) : Color.black.opacity(0.035)
        for offset in stride(from: CGFloat(24), through: size.height - 24, by: 22) {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: offset))
            path.addLine(to: CGPoint(x: size.width, y: offset))
            context.stroke(path, with: .color(gridColor), lineWidth: 1)
        }
    }

    private func drawDebugBackdropBand(
        in context: GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        sceneRect: CGRect
    ) {
        let bandY = size.height * 0.5 - 22
        let bandHeight: CGFloat = 44
        let travel = size.width + 320
        let phase = CGFloat((time * 90).truncatingRemainder(dividingBy: Double(travel)))
        let bandX = -160 + phase

        let segments: [(CGFloat, CGFloat, CGFloat, CGFloat, Color, CGFloat)] = usesDarkBackground
            ? [
                (0, 30, 8, 8, .white.opacity(0.92), 8),
                (38, 8, 12, 12, .black.opacity(0.94), 4),
                (52, 14, 10, 10, Color(red: 0.20, green: 0.86, blue: 0.80), 6),
                (76, 28, 6, 6, .white.opacity(0.86), 10),
                (112, 6, 14, 14, .black.opacity(0.94), 3),
                (126, 12, 12, 12, Color(red: 0.18, green: 0.56, blue: 0.98), 5),
                (146, 32, 7, 7, .black.opacity(0.94), 10),
                (184, 18, 10, 10, .white.opacity(0.84), 7),
                (210, 12, 9, 9, Color(red: 0.24, green: 0.90, blue: 0.82), 5),
                (228, 8, 15, 15, .black.opacity(0.96), 4),
                (244, 24, 8, 8, .white.opacity(0.90), 8),
            ]
            : [
                (0, 30, 8, 8, .black.opacity(0.78), 8),
                (38, 8, 12, 12, .white.opacity(0.98), 4),
                (52, 14, 10, 10, Color(red: 0.20, green: 0.86, blue: 0.80), 6),
                (76, 28, 6, 6, .black.opacity(0.86), 10),
                (112, 6, 14, 14, .white.opacity(0.98), 3),
                (126, 12, 12, 12, Color(red: 0.18, green: 0.56, blue: 0.98), 5),
                (146, 32, 7, 7, .white.opacity(0.98), 10),
                (184, 18, 10, 10, .black.opacity(0.84), 7),
                (210, 12, 9, 9, Color(red: 0.24, green: 0.90, blue: 0.82), 5),
                (228, 8, 15, 15, .white.opacity(0.96), 4),
                (244, 24, 8, 8, .black.opacity(0.88), 8),
            ]

        for (offsetX, width, topInset, bottomInset, color, radius) in segments {
            let rect = CGRect(
                x: bandX + offsetX,
                y: bandY + topInset,
                width: width,
                height: bandHeight - topInset - bottomInset
            )
            guard rect.intersects(sceneRect.insetBy(dx: -40, dy: -40)) else { continue }
            context.fill(
                Path(roundedRect: rect, cornerRadius: radius),
                with: .color(color)
            )
        }
    }
}
