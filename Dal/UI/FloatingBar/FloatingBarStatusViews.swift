import AppKit
import SwiftUI

struct ErrorDot: View {

    var body: some View {
        ZStack {
            Circle()
                .fill(TF.settingsAccentRed.opacity(0.18))
                .frame(width: 15, height: 15)

            Text("!")
                .font(TF.hudFontMetadata)
                .foregroundStyle(TF.settingsAccentRed)
                .offset(y: -0.5)
        }
        .frame(width: 24, height: 24)
    }
}

struct DoneCheckmarkGlyph: View {
    @Environment(\.hudStyle) private var style

    var body: some View {
        Image(systemName: "checkmark")
            .font(TF.hudFontLargeTitle)
            .foregroundStyle(TF.success)
            .shadow(color: style == .ink ? .clear : TF.success.opacity(0.28), radius: 6, x: 0, y: 0)
            .shadow(color: style == .ink ? .clear : Color.white.opacity(0.08), radius: 2, x: 0, y: 0)
            .accessibilityLabel(L("已完成", "Done"))
    }
}

private struct FloatingBarReadableTextModifier: ViewModifier {
    let color: Color
    @Environment(\.hudStyle) private var style

    func body(content: Content) -> some View {
        if style == .ink {
            content.foregroundStyle(color)
        } else {
            content
                .foregroundStyle(color)
                .shadow(color: Color.black.opacity(0.26), radius: 0, x: 0.42, y: 0)
                .shadow(color: Color.black.opacity(0.26), radius: 0, x: -0.42, y: 0)
                .shadow(color: Color.black.opacity(0.22), radius: 0, x: 0, y: 0.42)
                .shadow(color: Color.black.opacity(0.22), radius: 0, x: 0, y: -0.42)
                .shadow(color: Color.black.opacity(0.72), radius: 0.5, x: 0, y: 0.45)
        }
    }
}

extension View {
    func floatingBarReadableText(color: Color) -> some View {
        modifier(FloatingBarReadableTextModifier(color: color))
    }
}

struct NotificationBlurView: NSViewRepresentable {

    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.state = .active
        nsView.blendingMode = .behindWindow
        nsView.isEmphasized = false
    }
}

// MARK: - Processing Progress

/// Particle progress bar: fills left->right to 90% in 1.5s, then waits.
/// When processingFinishTime is set, sprints toward 100% in 0.3s.
/// When doneStartDate is set, fills remaining gap to 100% in 0.3s.
/// All timing comes from parent, so view recreation is harmless.
struct ProcessingProgress: View {

    let finishTime: Date?
    var processingStartDate: Date?
    var doneStartDate: Date?

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let startRef = processingStartDate?.timeIntervalSinceReferenceDate ?? time
                let elapsed = time - startRef

                // Cruise: 0% -> 90% in 1.5s (ease-out)
                var progress: CGFloat
                if let finishTime {
                    let finishElapsed = time - finishTime.timeIntervalSinceReferenceDate
                    let sprintProgress = min(1.0, CGFloat(finishElapsed / 0.3))
                    let baseProgress = min(0.9, CGFloat(elapsed / 1.5) * 0.9)
                    progress = baseProgress + (1.0 - baseProgress) * sprintProgress
                } else {
                    let t = min(1.0, CGFloat(elapsed / 1.5))
                    progress = t * 0.9 * (2.0 - t)
                }

                // Done: floor at 90% (processing end), fill to 100% in 0.15s
                if let doneStartDate {
                    let doneElapsed = time - doneStartDate.timeIntervalSinceReferenceDate
                    let doneT = min(1.0, CGFloat(doneElapsed / 0.15))
                    let base = max(progress, 0.9)
                    progress = base + (1.0 - base) * doneT
                }

                let fillEdge = progress * size.width + (progress >= 0.99 ? 20 : 0)
                let center = size.height / 2

                var col = 0
                var xi: CGFloat = 0
                while xi <= size.width {
                    let nx = xi / size.width

                    // Color: white (left) -> blue (right)
                    let t = min(1.0, max(0, nx))
                    let cr = 0.82 - t * 0.42
                    let cg = 0.85 - t * 0.25
                    let coreColor = Color(red: cr, green: cg, blue: 1.0)

                    // Density: filled region is dense, edge has a soft falloff
                    let distToEdge = fillEdge - xi
                    let edgeFade: CGFloat
                    if distToEdge > 20 {
                        edgeFade = 1.0
                    } else if distToEdge > 0 {
                        edgeFade = distToEdge / 20
                    } else if distToEdge > -15 {
                        edgeFade = max(0, (distToEdge + 15) / 15) * 0.3
                    } else {
                        col += 1; xi += 2; continue
                    }

                    let count = Int(edgeFade * 200)
                    for j in 0..<count {
                        let h1 = hash(col, j)
                        let h2 = hash(col, j &+ 53)
                        let h3 = hash(col, j &+ 137)

                        let scatter = (h1 - 0.5) * 2
                        let py = center + scatter * abs(scatter) * size.height * 0.48
                        let distFromCenter = abs(py - center)
                        let distFade = pow(max(0, 1.0 - distFromCenter / (size.height * 0.48)), 1.3)
                        let freq = 3.0 + Double(h2) * 10.0
                        let twinkle = CGFloat(0.5 + 0.5 * sin(time * freq + Double(h3) * .pi * 2))
                        let op = Double(distFade * twinkle * edgeFade * 0.85)
                        guard op > 0.03 else { continue }

                        let dotR = CGRect(x: xi - 0.25, y: py - 0.25, width: 0.5, height: 0.5)
                        context.fill(Circle().path(in: dotR), with: .color(coreColor.opacity(op)))
                    }

                    col += 1
                    xi += 2
                }
            }
        }
        .drawingGroup()
    }

    private func hash(_ a: Int, _ b: Int) -> CGFloat {
        var h = a &* 374761393 &+ b &* 668265263
        h = (h ^ (h >> 13)) &* 1274126177
        h = h ^ (h >> 16)
        return CGFloat(abs(h) % 10000) / 10000.0
    }
}
