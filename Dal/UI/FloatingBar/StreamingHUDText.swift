import AppKit
import SwiftUI

/// 始终保留同一行文字：外壳展开时渐显，满宽后平滑移走左侧旧内容。
struct StreamingHUDText: View {
    let text: String
    let color: Color
    let leadingFadeWidth: CGFloat
    var trailingFadeWidth: CGFloat = 14
    var recordingLayout: HUDRecordingLayout? = nil

    var body: some View {
        // 与外壳使用相同的字号和测宽方式，波形更新不参与文字布局。
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: TF.hudNSFontTitle]).width)
        StreamingHUDTextPresentation(
            text: text, color: color, textWidth: textWidth,
            leadingFadeWidth: leadingFadeWidth, trailingFadeWidth: trailingFadeWidth,
            layout: recordingLayout
        )
        .allowsHitTesting(false)
    }
}

private struct StreamingHUDTextPresentation: View {
    let text: String
    let color: Color
    let textWidth: CGFloat
    let leadingFadeWidth: CGFloat
    let trailingFadeWidth: CGFloat

    let layout: HUDRecordingLayout?

    var body: some View {
        Group {
            if let layout {
                // 录音时无需等 GeometryReader 再布局，直接使用外壳这一帧的宽度。
                textRow(viewportWidth: layout.textViewportWidth, height: TF.barHeight,
                        presentedWidth: layout.presentedTextWidth, offset: layout.textOffset)
            } else {
                GeometryReader { geometry in
                    let width = max(0, geometry.size.width)
                    textRow(viewportWidth: width, height: geometry.size.height,
                            presentedWidth: textWidth,
                            offset: min(0, width - min(trailingFadeWidth, width / 2) - textWidth))
                }
            }
        }
        // 字形、位移和遮罩不再各自叠加动画。
        .transaction { $0.animation = nil }
    }

    private func textRow(viewportWidth: CGFloat, height: CGFloat,
                         presentedWidth: CGFloat, offset: CGFloat) -> some View {
        #if HUD_PERFORMANCE_PROBE
        let _ = HUDPerformanceProbe.recordText(width: textWidth, presentedWidth: presentedWidth,
                                               viewport: viewportWidth, offset: offset)
        #endif
        return Text(text)
            .font(TF.hudFontTitle)
            .floatingBarReadableText(color: color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: textWidth, height: height, alignment: .leading)
            .offset(x: offset)
            .frame(width: viewportWidth, height: height, alignment: .leading)
            .clipped()
            .mask {
                HUDTextEdgeMask(leadingFadeWidth: leadingFadeWidth, trailingFadeWidth: trailingFadeWidth,
                                hasLeadingOverflow: offset < -0.5, viewportWidth: viewportWidth)
            }
    }
}

struct HUDTextEdgeMask: View {
    let leadingFadeWidth: CGFloat
    let trailingFadeWidth: CGFloat
    let hasLeadingOverflow: Bool
    let viewportWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [hasLeadingOverflow ? .clear : .white, .white],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: min(leadingFadeWidth, viewportWidth / 2))
            Rectangle()
            LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: min(trailingFadeWidth, viewportWidth / 2))
        }
        .frame(width: viewportWidth)
    }
}
