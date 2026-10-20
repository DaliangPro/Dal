import SwiftUI

/// 先插值未截断的宽度，再计算外壳与文字，避免到达上限前两者各自追赶。
struct HUDRecordingLayout {
    let logicalWidth: CGFloat
    let widthReserve: CGFloat
    let tailInset: CGFloat

    var capsuleWidth: CGFloat { min(TF.barWidth, max(TF.barHeight, logicalWidth)) }
    var presentedTextWidth: CGFloat { max(0, logicalWidth - widthReserve) }
    var textViewportWidth: CGFloat { max(0, capsuleWidth - widthReserve + tailInset) }
    var textOffset: CGFloat {
        min(0, textViewportWidth - min(tailInset, textViewportWidth / 2) - presentedTextWidth)
    }
}

struct HUDRecordingMotion<Content: View>: View, Animatable {
    var logicalWidth: CGFloat
    let widthReserve: CGFloat
    let tailInset: CGFloat
    @ViewBuilder let content: (HUDRecordingLayout) -> Content

    var animatableData: CGFloat {
        get { logicalWidth }
        set { logicalWidth = newValue }
    }

    var body: some View {
        let layout = HUDRecordingLayout(logicalWidth: logicalWidth, widthReserve: widthReserve, tailInset: tailInset)
        content(layout)
            // 外壳、遮罩、文字使用同一帧的值，不再对各个子视图重复插值。
            .transaction { $0.animation = nil }
    }
}
