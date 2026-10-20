import AppKit
import SwiftUI

struct ModeTextArea: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    /// 上/下方是否还有被裁掉的内容——驱动外层渐隐只在需要时出现
    /// （2026-07-08 大梁老师：未滚动时顶部渐隐不得盖住第一行字）
    var onScrollEdges: ((_ hasContentAbove: Bool, _ hasContentBelow: Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        // 打字区不带底色、与卡片融为一体（2026-07-08 大梁老师：输入框去掉变色背景）
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = isEditable
        textView.drawsBackground = false
        // 无底色后文字与标题/横线左对齐（水平 inset 归零，光标留 1pt 防贴边裁切）
        textView.textContainerInset = NSSize(width: 1, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.string = text

        scrollView.documentView = textView
        applyStyle(to: textView)
        context.coordinator.lastAppliedStyleKey = currentStyleKey(for: textView)

        // 滚动位置/内容高度变化时上报「上下是否有被裁内容」，外层据此开关渐隐
        scrollView.contentView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        context.coordinator.observedScrollView = scrollView
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollGeometryChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollGeometryChanged),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak scrollView] in
            guard let scrollView else { return }
            coordinator.reportScrollEdges(for: scrollView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        syncTextIfNeeded(in: scrollView, textView: textView, coordinator: context.coordinator)

        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        if textView.allowsUndo != isEditable {
            textView.allowsUndo = isEditable
        }

        let styleKey = currentStyleKey(for: textView)
        if context.coordinator.lastAppliedStyleKey != styleKey {
            preserveScrollPosition(in: scrollView) {
                applyStyle(to: textView)
            }
            context.coordinator.lastAppliedStyleKey = styleKey
        }
    }

    private func applyStyle(to textView: NSTextView) {
        let font = TF.settingsNSFontReading
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 6

        textView.font = font
        textView.textColor = NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.isDark {
                return NSColor(
                    srgbRed: 0.72,
                    green: 0.75,
                    blue: 0.80,
                    alpha: 1
                )
            }
            return NSColor(
                srgbRed: 0.27,
                green: 0.30,
                blue: 0.35,
                alpha: 1
            )
        })
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textView.textColor ?? NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
    }

    private func syncTextIfNeeded(
        in scrollView: NSScrollView,
        textView: NSTextView,
        coordinator: Coordinator
    ) {
        guard textView.string != text else { return }

        let visibleOrigin = scrollView.contentView.bounds.origin
        let selectedRanges = textView.selectedRanges
        coordinator.isApplyingProgrammaticTextUpdate = true
        textView.string = text
        coordinator.isApplyingProgrammaticTextUpdate = false

        restoreSelectedRanges(selectedRanges, in: textView)
        restoreScrollOrigin(visibleOrigin, in: scrollView)
        // 程序性替换文本后，AppKit 会在下一拍把光标行 autoscroll 到可视区顶端，
        // 恰好把顶部 8pt 文本 inset 卷出去（探针实测停在 y=8）——首行出界、顶部渐隐误现。
        // 下一循环再把滚动位置钉回原位一次（2026-07-09 修：初始状态不得有顶部渐隐）
        let pin = self
        DispatchQueue.main.async { [weak scrollView] in
            guard let scrollView else { return }
            pin.restoreScrollOrigin(visibleOrigin, in: scrollView)
        }
    }

    private func preserveScrollPosition(
        in scrollView: NSScrollView,
        operation: () -> Void
    ) {
        let visibleOrigin = scrollView.contentView.bounds.origin
        operation()
        restoreScrollOrigin(visibleOrigin, in: scrollView)
    }

    private func restoreScrollOrigin(_ origin: NSPoint, in scrollView: NSScrollView) {
        scrollView.layoutSubtreeIfNeeded()
        if let textView = scrollView.documentView as? NSTextView,
           let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }

        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let visibleHeight = scrollView.contentView.bounds.height
        let maxY = max(0, documentHeight - visibleHeight)
        let restoredOrigin = NSPoint(
            x: origin.x,
            y: min(max(origin.y, 0), maxY)
        )
        scrollView.contentView.scroll(to: restoredOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func restoreSelectedRanges(_ ranges: [NSValue], in textView: NSTextView) {
        let textLength = (textView.string as NSString).length
        let validRanges = ranges.map { value -> NSValue in
            let range = value.rangeValue
            let location = min(range.location, textLength)
            let length = min(range.length, max(0, textLength - location))
            return NSValue(range: NSRange(location: location, length: length))
        }
        guard !validRanges.isEmpty else { return }
        textView.selectedRanges = validRanges
    }

    private func currentStyleKey(for textView: NSTextView) -> StyleKey {
        StyleKey(
            appearanceName: textView.effectiveAppearance.name.rawValue
        )
    }

    struct StyleKey: Equatable {
        let appearanceName: String
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ModeTextArea
        var isApplyingProgrammaticTextUpdate = false
        var lastAppliedStyleKey: StyleKey?
        weak var observedScrollView: NSScrollView?
        private var lastReportedEdges: (above: Bool, below: Bool)?

        init(_ parent: ModeTextArea) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticTextUpdate else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        @objc func scrollGeometryChanged() {
            guard let observedScrollView else { return }
            reportScrollEdges(for: observedScrollView)
        }

        /// 只在边缘状态变化时上报；异步派发避免在 AppKit 布局回调里改 SwiftUI 状态
        func reportScrollEdges(for scrollView: NSScrollView) {
            guard let onScrollEdges = parent.onScrollEdges else { return }
            let visible = scrollView.contentView.bounds
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let above = visible.origin.y > 0.5
            let below = (visible.origin.y + visible.height) < (documentHeight - 0.5)
            if let last = lastReportedEdges, last.above == above, last.below == below { return }
            lastReportedEdges = (above, below)
            DispatchQueue.main.async {
                onScrollEdges(above, below)
            }
        }
    }
}
