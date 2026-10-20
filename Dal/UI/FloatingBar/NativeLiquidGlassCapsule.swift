import AppKit
import SwiftUI

@available(macOS 26.0, *)
enum NativeGlassVariant {
    case clearCore
    case mergeEdge
    case liquidSweep
    /// 极简对照：单层 .regular 裸玻璃，零手画叠加、零 nudge hack（2026-06-24 大梁老师 A/B）
    case minimalRegular
}

@available(macOS 26.0, *)
private struct NativeGlassMaterialOverlay: View {

    let variant: NativeGlassVariant
    let phase: FloatingBarPhase

    private var intensity: CGFloat {
        if variant == .clearCore {
            return 0.52
        }
        switch phase {
        case .recording:
            return 1.0
        case .preparing, .processing:
            return 0.72
        case .done, .copyFallback:
            return 0.46
        case .error:
            return 0.38
        case .hidden:
            return 0
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                let sweepProgress = CGFloat((sin(time * 0.88) + 1.0) / 2.0)

                Group {
                    if variant == .clearCore && phase == .recording {
                        let source = CGPoint(x: min(28.0, width * 0.20), y: height * 0.5)
                        let coreDriftX = 1.6 * cos(time * 0.44 + 0.5)
                        let coreDriftY = 1.2 * sin(time * 0.36 + 0.8)
                        let fieldDriftX = 2.4 * cos(time * 0.22 + 1.0)
                        let fieldDriftY = 1.8 * sin(time * 0.26 + 0.2)
                        let sweepAngle = -14 + sin(time * 0.20) * 6

                        ZStack {
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [
                                            Color.white.opacity(0.07),
                                            Color(red: 0.70, green: 0.86, blue: 1.0).opacity(0.05),
                                            .clear,
                                        ],
                                        center: .center,
                                        startRadius: 0,
                                        endRadius: 16
                                    )
                                )
                                .frame(width: 28, height: 28)
                                .blur(radius: 8)
                                .position(x: source.x + coreDriftX, y: source.y + coreDriftY)
                                .blendMode(.screen)

                            Ellipse()
                                .fill(
                                    RadialGradient(
                                        colors: [
                                            Color(red: 0.58, green: 0.82, blue: 1.0).opacity(0.05),
                                            Color(red: 0.52, green: 0.94, blue: 0.92).opacity(0.035),
                                            .clear,
                                        ],
                                        center: .center,
                                        startRadius: 0,
                                        endRadius: 22
                                    )
                                )
                                .frame(width: 52, height: 34)
                                .blur(radius: 14)
                                .rotationEffect(.degrees(sweepAngle))
                                .position(x: source.x + 9 + fieldDriftX, y: source.y + fieldDriftY)
                                .blendMode(.screen)

                            Ellipse()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.08),
                                            Color(red: 0.68, green: 0.86, blue: 1.0).opacity(0.05),
                                            .clear,
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: 42, height: 22)
                                .blur(radius: 10)
                                .rotationEffect(.degrees(-18 + cos(time * 0.18 + 1.1) * 5))
                                .position(
                                    x: source.x + 6 + 2.6 * cos(time * 0.17 + 2.0),
                                    y: source.y - 5 + 1.6 * sin(time * 0.23 + 1.5)
                                )
                                .blendMode(.screen)
                        }
                    } else {
                        ZStack {
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity((variant == .clearCore ? 0.045 : 0.08) * intensity))
                                .frame(width: width * (variant == .clearCore ? 0.32 : 0.38), height: height * 0.24)
                                .blur(radius: variant == .clearCore ? 16 : 20)
                                .rotationEffect(.degrees(-11))
                                .offset(x: -width * 0.16, y: -height * 0.11)
                                .blendMode(.screen)

                            Ellipse()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.74, green: 0.84, blue: 1.0).opacity((variant == .clearCore ? 0.08 : 0.15) * intensity),
                                            Color.white.opacity((variant == .clearCore ? 0.02 : 0.04) * intensity),
                                            .clear,
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: width * (variant == .clearCore ? 0.28 : 0.34), height: height * 0.60)
                                .blur(radius: variant == .clearCore ? 18 : 24)
                                .rotationEffect(.degrees(14))
                                .offset(x: width * 0.18, y: -height * 0.03)
                                .blendMode(.screen)

                            Ellipse()
                                .fill(
                                    RadialGradient(
                                        colors: [
                                            Color.white.opacity((variant == .clearCore ? 0.08 : (phase == .recording ? 0.20 : 0.10)) * intensity),
                                            Color.white.opacity((variant == .clearCore ? 0.02 : 0.04) * intensity),
                                            .clear,
                                        ],
                                        center: .center,
                                        startRadius: 6,
                                        endRadius: height * 0.42
                                    )
                                )
                                .frame(width: width * (variant == .clearCore ? 0.18 : 0.22), height: height * 0.64)
                                .blur(radius: variant == .clearCore ? 16 : 20)
                                .rotationEffect(.degrees(-18))
                                .offset(x: width * 0.02, y: height * 0.05)
                                .blendMode(.screen)

                            if phase == .recording && variant != .clearCore {
                                LinearGradient(
                                    colors: [
                                        .clear,
                                        Color.white.opacity(0.26),
                                        Color.white.opacity(0.08),
                                        .clear,
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(width: width * 0.18)
                                .blur(radius: 12)
                                .rotationEffect(.degrees(-10))
                                .offset(x: -width * 0.10 + sweepProgress * width * 0.26, y: -height * 0.04)
                                .blendMode(.screen)
                            }
                        }
                    }
                }
                .frame(width: width, height: height)
            }
        }
        .allowsHitTesting(false)
        .clipShape(Capsule())
    }
}

@available(macOS 26.0, *)
private struct NativeGlassChromeOverlay: View {

    let variant: NativeGlassVariant
    let phase: FloatingBarPhase

    private var topHighlightPrimaryOpacity: Double {
        if variant == .clearCore {
            return 0
        }
        return phase == .recording ? 0.20 : 0.14
    }

    private var topHighlightSecondaryOpacity: Double {
        if variant == .clearCore {
            return 0
        }
        return 0.04
    }

    private var topHighlightScaleY: CGFloat {
        if variant == .clearCore {
            return 0.26
        }
        return 0.48
    }

    private var topHighlightOffsetY: CGFloat {
        if variant == .clearCore {
            return -6.5
        }
        return -10
    }

    private var topHighlightBlurRadius: CGFloat {
        if variant == .clearCore {
            return 0.8
        }
        return 1.4
    }

    var body: some View {
        ZStack {
            if variant != .clearCore {
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(phase == .recording ? 0.16 : 0.12),
                                Color.white.opacity(0.05),
                                .clear,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.85
                    )

                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.black.opacity(0.05),
                                Color.black.opacity(0.12),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.9
                    )
            }

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(topHighlightPrimaryOpacity),
                            Color.white.opacity(topHighlightSecondaryOpacity),
                            .clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .scaleEffect(x: 0.986, y: topHighlightScaleY)
                .offset(y: topHighlightOffsetY)
                .blur(radius: topHighlightBlurRadius)
        }
        .allowsHitTesting(false)
    }
}

@available(macOS 26.0, *)
struct NativeLiquidGlassCapsule: NSViewRepresentable {

    let cornerRadius: CGFloat
    let variant: NativeGlassVariant
    let style: NSGlassEffectView.Style
    let tintColor: NSColor
    let phase: FloatingBarPhase
    let content: AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    func makeNSView(context: Context) -> NativeLiquidGlassContainerView {
        let view = NativeLiquidGlassContainerView()
        view.apply(
            cornerRadius: cornerRadius,
            variant: variant,
            style: style,
            tintColor: tintColor,
            phase: phase,
            content: context.coordinator.hostingView
        )
        return view
    }

    func updateNSView(_ nsView: NativeLiquidGlassContainerView, context: Context) {
        context.coordinator.hostingView.rootView = content
        nsView.apply(
            cornerRadius: cornerRadius,
            variant: variant,
            style: style,
            tintColor: tintColor,
            phase: phase,
            content: context.coordinator.hostingView
        )
    }

    final class Coordinator {
        let hostingView: NSHostingView<AnyView>

        init(content: AnyView) {
            hostingView = NSHostingView(rootView: content)
        }
    }
}

@available(macOS 26.0, *)
final class NativeLiquidGlassContainerView: NSView {

    private let glassContainer = NSGlassEffectContainerView()
    private let stageView = NSView()
    private let glassContentView = NSView()

    private let mainGlass = NSGlassEffectView()
    private let lensGlass = NSGlassEffectView()
    private let lensTailGlass = NSGlassEffectView()
    private let materialHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let chromeHost = NSHostingView(rootView: AnyView(EmptyView()))

    private var contentHost: NSHostingView<AnyView>?
    private var currentCornerRadius: CGFloat = 0
    private var currentVariant: NativeGlassVariant = .clearCore
    private var currentStyle: NSGlassEffectView.Style = .clear
    private var baseTintColor: NSColor = .clear
    private var lensTintColor: NSColor = .clear
    private var lensTailTintColor: NSColor = .clear
    private var refreshTimer: Timer?
    private var refreshToggle = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTimer?.invalidate()
    }

    override func layout() {
        super.layout()
        glassContainer.frame = bounds
        stageView.frame = glassContainer.bounds
        layoutGlassFrames()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRefreshDriver()
    }

    func apply(
        cornerRadius: CGFloat,
        variant: NativeGlassVariant,
        style: NSGlassEffectView.Style,
        tintColor: NSColor,
        phase: FloatingBarPhase,
        content: NSHostingView<AnyView>
    ) {
        currentCornerRadius = cornerRadius
        currentStyle = style
        currentVariant = variant
        baseTintColor = tintColor
        lensTintColor = nativeLensTintColor(from: tintColor)
        lensTailTintColor = nativeLensTailTintColor(from: tintColor)

        if contentHost !== content {
            contentHost?.removeFromSuperview()
            contentHost = content
            glassContentView.addSubview(content, positioned: .above, relativeTo: materialHost)
        }

        // 极简对照：只留一层 .regular 裸玻璃——所有手画叠加 / lens / nudge 全关，让原生材质自己说话
        if variant == .minimalRegular {
            mainGlass.style = .regular
            mainGlass.tintColor = tintColor
            lensGlass.isHidden = true
            lensTailGlass.isHidden = true
            materialHost.isHidden = true
            materialHost.rootView = AnyView(EmptyView())
            chromeHost.rootView = AnyView(EmptyView())
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.clear.cgColor
            layoutGlassFrames()
            updateRefreshDriver()
            return
        }

        mainGlass.style = style
        mainGlass.tintColor = tintColor
        lensGlass.style = .clear
        lensGlass.tintColor = lensTintColor
        lensTailGlass.style = .regular
        lensTailGlass.tintColor = lensTailTintColor
        let showsLensCluster = variant == .clearCore && phase == .recording
        lensGlass.isHidden = !showsLensCluster
        lensTailGlass.isHidden = true

        materialHost.rootView = AnyView(
            Group {
                if variant != .clearCore {
                    NativeGlassMaterialOverlay(
                        variant: variant,
                        phase: phase
                    )
                }
            }
        )
        chromeHost.rootView = AnyView(
            NativeGlassChromeOverlay(
                variant: variant,
                phase: phase
            )
        )
        materialHost.isHidden = variant == .clearCore

        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        glassContentView.addSubview(materialHost, positioned: .below, relativeTo: content)
        glassContentView.addSubview(chromeHost, positioned: .above, relativeTo: content)

        layoutGlassFrames()
        updateRefreshDriver()
    }

    private func configure() {
        glassContainer.spacing = 0
        glassContainer.autoresizingMask = [.width, .height]

        stageView.wantsLayer = true
        stageView.layer?.backgroundColor = NSColor.clear.cgColor
        glassContentView.wantsLayer = true
        glassContentView.layer?.backgroundColor = NSColor.clear.cgColor

        addSubview(glassContainer)
        glassContainer.contentView = stageView

        mainGlass.wantsLayer = true
        mainGlass.contentView = glassContentView

        materialHost.wantsLayer = true
        materialHost.layer?.backgroundColor = NSColor.clear.cgColor
        chromeHost.wantsLayer = true
        chromeHost.layer?.backgroundColor = NSColor.clear.cgColor

        lensGlass.wantsLayer = true
        lensGlass.isHidden = true
        lensGlass.alphaValue = 0.96
        lensTailGlass.wantsLayer = true
        lensTailGlass.isHidden = true
        lensTailGlass.alphaValue = 0

        stageView.addSubview(lensGlass)
        stageView.addSubview(lensTailGlass)
        stageView.addSubview(mainGlass)
        glassContentView.addSubview(materialHost)
        glassContentView.addSubview(chromeHost)
    }

    private func updateRefreshDriver() {
        // 极简版不抖 tint：原生 .regular 自己处理背景变化，不需要强制重采样 hack
        if window == nil || currentVariant == .minimalRegular {
            refreshTimer?.invalidate()
            refreshTimer = nil
            return
        }

        guard refreshTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            self?.refreshBackdropSamplingIfNeeded()
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshBackdropSamplingIfNeeded() {
        guard let window, window.isVisible else { return }
        guard window.occlusionState.contains(.visible) else { return }

        glassContainer.needsLayout = true
        stageView.needsLayout = true

        glassContainer.needsDisplay = true
        stageView.needsDisplay = true
        mainGlass.needsDisplay = true
        lensGlass.needsDisplay = !lensGlass.isHidden
        lensTailGlass.needsDisplay = !lensTailGlass.isHidden
        glassContentView.needsDisplay = true
        materialHost.needsDisplay = !materialHost.isHidden
        chromeHost.needsDisplay = true

        nudgeGlassSampling()
    }

    private func nudgeGlassSampling() {
        refreshToggle.toggle()

        let alpha = baseTintColor.alphaComponent
        let epsilon: CGFloat = refreshToggle ? 0.0008 : -0.0008
        let nudgedTint = baseTintColor.withAlphaComponent(max(0, min(1, alpha + epsilon)))
        let lensAlpha = lensTintColor.alphaComponent
        let nudgedLensTint = lensTintColor.withAlphaComponent(max(0, min(1, lensAlpha + epsilon * 0.65)))
        let tailAlpha = lensTailTintColor.alphaComponent
        let nudgedLensTailTint = lensTailTintColor.withAlphaComponent(max(0, min(1, tailAlpha - epsilon * 0.55)))

        mainGlass.style = currentStyle
        mainGlass.tintColor = nudgedTint
        if !lensGlass.isHidden {
            lensGlass.style = .clear
            lensGlass.tintColor = nudgedLensTint
            lensTailGlass.style = .regular
            lensTailGlass.tintColor = nudgedLensTailTint
        }
    }

    private func layoutGlassFrames() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let mainFrame = bounds
        mainGlass.frame = mainFrame
        mainGlass.cornerRadius = currentCornerRadius

        let lensWidth = min(54.0, max(42.0, bounds.height * 0.96))
        let lensHeight = max(40.0, bounds.height * 0.84)
        let lensFrame = CGRect(
            x: 6,
            y: (bounds.height - lensHeight) / 2,
            width: lensWidth,
            height: lensHeight
        )
        lensGlass.frame = lensFrame
        lensGlass.cornerRadius = lensHeight / 2

        let tailWidth = max(34.0, lensWidth * 0.84)
        let tailHeight = max(34.0, lensHeight * 0.92)
        let tailFrame = CGRect(
            x: lensFrame.minX + lensWidth * 0.56,
            y: (bounds.height - tailHeight) / 2,
            width: tailWidth,
            height: tailHeight
        )
        lensTailGlass.frame = tailFrame
        lensTailGlass.cornerRadius = tailHeight / 2

        glassContentView.frame = mainGlass.bounds
        materialHost.frame = glassContentView.bounds
        contentHost?.frame = glassContentView.bounds
        chromeHost.frame = glassContentView.bounds
    }

    private func nativeLensTintColor(from tintColor: NSColor) -> NSColor {
        NSColor(
            calibratedRed: 0.20,
            green: 0.52,
            blue: 0.88,
            alpha: max(0.034, tintColor.alphaComponent * 0.72)
        )
    }

    private func nativeLensTailTintColor(from tintColor: NSColor) -> NSColor {
        NSColor(
            calibratedRed: 0.22,
            green: 0.68,
            blue: 0.88,
            alpha: max(0.024, tintColor.alphaComponent * 0.58)
        )
    }
}

/// 玻璃只承载材质，动态内容留在外层 SwiftUI 树中，避免每次文字更新重置内嵌宿主。
@available(macOS 26.0, *)
struct CleanGlassCapsule: View {
    let cornerRadius: CGFloat
    let style: NSGlassEffectView.Style
    let tintColor: NSColor?
    let content: AnyView

    var body: some View {
        CleanGlassSurface(cornerRadius: cornerRadius, style: style, tintColor: tintColor)
            .overlay { content }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

@available(macOS 26.0, *)
private struct CleanGlassSurface: NSViewRepresentable {
    let cornerRadius: CGFloat
    let style: NSGlassEffectView.Style
    let tintColor: NSColor?

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.style = style
        glass.cornerRadius = cornerRadius
        glass.tintColor = tintColor
        glass.contentView = NSView()
        return glass
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSGlassEffectView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ glass: NSGlassEffectView, context: Context) {
        if glass.style != style { glass.style = style }
        if glass.cornerRadius != cornerRadius { glass.cornerRadius = cornerRadius }
        if glass.tintColor != tintColor { glass.tintColor = tintColor }
    }
}
