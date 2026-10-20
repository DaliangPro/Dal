import AppKit
import SwiftUI

private enum SettingsPopupHostCoordinateSpace {
    static let name = "settings-popup-host"
}

private enum SettingsPopupMetrics {
    static let cardPadding: CGFloat = 6
    static let rowHeight: CGFloat = 30
    static let rowSpacing: CGFloat = 2
    static let optionRowHorizontalPadding: CGFloat = 8
    static let textLeadingInset: CGFloat = 14
    static let triggerTrailingInset: CGFloat = 10
    static let chevronWidth: CGFloat = 8
    static let triggerTextChevronSpacing: CGFloat = 8
    static let labelMeasurementTolerance: CGFloat = 16
    static let minimumWidth: CGFloat = 76

    static var optionTextInset: CGFloat {
        cardPadding + optionRowHorizontalPadding
    }

    static var popupTextChromeWidth: CGFloat {
        optionTextInset * 2
    }

    static var triggerTextChromeWidth: CGFloat {
        textLeadingInset + triggerTextChevronSpacing + chevronWidth + triggerTrailingInset
    }

    static func popupHeight(optionCount: Int) -> CGFloat {
        let totalRowSpacing = CGFloat(max(optionCount - 1, 0)) * rowSpacing
        return cardPadding * 2 + CGFloat(optionCount) * rowHeight + totalRowSpacing
    }
}

/// 弹窗浮层色板（2026-06-12 修复：原为写死纯黑，浅色模式弹出黑卡突兀）。
/// 深色值与历史逐值一致；浅色给暖白浮层，靠明度+既有大阴影浮起
private enum SettingsPopupPanelPalette {
    private static func dynamic(
        light: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat),
        dark: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.isDark
                ? NSColor(srgbRed: dark.r, green: dark.g, blue: dark.b, alpha: dark.a)
                : NSColor(srgbRed: light.r, green: light.g, blue: light.b, alpha: light.a)
        }))
    }

    static let cardFill = dynamic(
        light: (1.0, 1.0, 1.0, 1.0),
        dark: (0.074, 0.074, 0.074, 1.0)
    )
    // 浅色弹窗不描边（用户设计语言：无线），靠明度+浮层阴影；深色保持原边
    static let cardEdge = dynamic(
        light: (0.420, 0.380, 0.280, 0.0),
        dark: (1.0, 1.0, 1.0, 0.08)
    )
    // 浮层阴影：浅色柔和（纯黑大阴影在浅色圆角边缘会糊出灰晕，2026-06-22 降强度去灰、保持浮起），深色保持原值
    static let shadowStrong = dynamic(
        light: (0.0, 0.0, 0.0, 0.12),
        dark: (0.0, 0.0, 0.0, 0.28)
    )
    static let shadowSoft = dynamic(
        light: (0.0, 0.0, 0.0, 0.05),
        dark: (0.0, 0.0, 0.0, 0.12)
    )
    static let rowFill = dynamic(
        light: (0.460, 0.420, 0.320, 0.12),
        dark: (1.0, 1.0, 1.0, 0.075)
    )
    static let text = dynamic(
        light: (0.110, 0.120, 0.150, 1.0),
        dark: (0.92, 0.94, 0.96, 1.0)
    )
}

private struct SettingsPopupCoordinatorKey: EnvironmentKey {
    static let defaultValue: SettingsPopupCoordinator? = nil
}

extension EnvironmentValues {
    var settingsPopupCoordinator: SettingsPopupCoordinator? {
        get { self[SettingsPopupCoordinatorKey.self] }
        set { self[SettingsPopupCoordinatorKey.self] = newValue }
    }
}

@MainActor
final class SettingsPopupCoordinator: ObservableObject {
    struct ActivePopup {
        let id: UUID
        var triggerFrame: CGRect
        var triggerScreenFrame: CGRect
        let selection: String
        let options: [(value: String, label: String)]
        let width: CGFloat
        let height: CGFloat
        let onSelect: (String) -> Void
        let onDismiss: () -> Void
    }

    @Published var activePopup: ActivePopup?
    private var popupWindow: NSWindow?
    private var eventMonitor: Any?
    /// 弹窗四周留给阴影的透明边距（窗口比卡片大一圈、卡片居中，阴影才不被裁切）
    private static let shadowMargin: CGFloat = 30

    func present(_ popup: ActivePopup) {
        activePopup = popup
        if popup.triggerScreenFrame != .zero {
            presentWindow(for: popup)
        }
    }

    func dismiss(id: UUID? = nil) {
        guard id == nil || activePopup?.id == id else { return }
        let onDismiss = activePopup?.onDismiss
        activePopup = nil
        closeWindow()
        onDismiss?()
    }

    private func presentWindow(for popup: ActivePopup) {
        closeWindow()

        let popupSize = CGSize(
            width: popup.width,
            height: SettingsPopupMetrics.popupHeight(optionCount: popup.options.count)
        )
        // 弹窗外观跟随设置（2026-06-12 修复：原强制 darkAqua，浅色模式弹黑卡）
        let appearanceMode = SettingsAppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: "tf_settingsAppearance") ?? ""
        ) ?? .system
        let isDarkPopup: Bool
        switch appearanceMode.preferredColorScheme {
        case .dark: isDarkPopup = true
        case .light: isDarkPopup = false
        default: isDarkPopup = NSApp.effectiveAppearance.isDark
        }
        let popupAppearance = NSAppearance(named: isDarkPopup ? .darkAqua : .aqua)

        // 给阴影留边距：窗口比卡片大一圈、卡片居中，卡片的浮层阴影才能完整绘制、
        // 不被窗口边界裁掉（否则阴影看不见、圆角四角还有裁剪残留的灰）。2026-06-22
        let shadowMargin = Self.shadowMargin
        let windowSize = CGSize(
            width: popupSize.width + shadowMargin * 2,
            height: popupSize.height + shadowMargin * 2
        )

        let content = SettingsPopupPanelContent(
            selection: popup.selection,
            width: popup.width,
            options: popup.options
        ) { [weak self] value in
            popup.onSelect(value)
            self?.dismiss(id: popup.id)
        }
        .environment(\.colorScheme, isDarkPopup ? .dark : .light)
        .padding(shadowMargin)

        let hostingView = NSHostingView(rootView: content)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.appearance = popupAppearance
        hostingView.frame = CGRect(origin: .zero, size: windowSize)

        let window = NSPanel(
            contentRect: CGRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.contentView = hostingView
        window.hasShadow = false
        window.hidesOnDeactivate = true
        window.isOpaque = false
        window.appearance = popupAppearance
        window.level = .popUpMenu
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.setFrameOrigin(screenOrigin(for: popup, popupSize: popupSize, shadowMargin: shadowMargin))
        window.orderFrontRegardless()

        popupWindow = window
        installEventMonitor()
    }

    private func screenOrigin(for popup: ActivePopup, popupSize: CGSize, shadowMargin: CGFloat) -> CGPoint {
        let margin: CGFloat = 8
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(popup.triggerScreenFrame) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? popup.triggerScreenFrame.insetBy(dx: -400, dy: -400)

        // popupSize 是卡片本身大小：先按卡片算期望位置（对齐触发控件），再减阴影边距得到
        // 更大窗口的原点，使卡片视觉位置不变
        let desiredX = popup.triggerScreenFrame.maxX - popupSize.width
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - popupSize.width - margin
        let cardX = min(max(desiredX, minX), max(minX, maxX))

        let belowY = popup.triggerScreenFrame.minY - popupSize.height - margin
        let aboveY = popup.triggerScreenFrame.maxY + margin
        let minY = visibleFrame.minY + margin
        let maxY = visibleFrame.maxY - popupSize.height - margin
        let cardY = belowY >= minY ? belowY : min(max(aboveY, minY), max(minY, maxY))

        return CGPoint(x: cardX - shadowMargin, y: cardY - shadowMargin)
    }

    private func installEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            if event.type == .keyDown, event.keyCode == 53 {
                Task { @MainActor in
                    self?.dismiss()
                }
                return nil
            }

            if let window = self?.popupWindow, event.window === window {
                // 只有点在卡片区域（排除四周透明阴影边距）才算点弹窗本体；
                // 点边距等同点外面 → 关闭，避免边距变成「点了没反应」的死区
                let cardRect = (window.contentView?.bounds ?? .zero)
                    .insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
                if cardRect.contains(event.locationInWindow) {
                    return event
                }
                Task { @MainActor in self?.dismiss() }
                return event
            }

            Task { @MainActor in
                self?.dismiss()
            }
            return event
        }
    }

    private func closeWindow() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        popupWindow?.orderOut(nil)
        popupWindow = nil
    }
}

private struct SettingsPopupFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

struct SettingsPopupHostModifier: ViewModifier {
    @StateObject private var coordinator = SettingsPopupCoordinator()

    func body(content: Content) -> some View {
        content
            .environment(\.settingsPopupCoordinator, coordinator)
            .coordinateSpace(name: SettingsPopupHostCoordinateSpace.name)
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    SettingsPopupOverlay(
                        coordinator: coordinator,
                        hostSize: proxy.size
                    )
                    .zIndex(10_000)
                }
            }
    }
}

extension View {
    func settingsPopupHost() -> some View {
        modifier(SettingsPopupHostModifier())
    }
}

struct SettingsPopupDropdown: View {
    @Binding var selection: String
    let options: [(value: String, label: String)]
    let width: CGFloat?
    let height: CGFloat

    @Environment(\.settingsPopupCoordinator) private var popupCoordinator
    @State private var id = UUID()
    @State private var isOpen = false
    @State private var isTriggerHovered = false
    @State private var triggerFrame = CGRect.zero
    @State private var triggerScreenFrame = CGRect.zero

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? selection
    }

    private var resolvedWidth: CGFloat {
        if let width {
            return width
        }

        let labels = options.map(\.label) + [currentLabel]
        let widestLabel = labels
            .map(Self.measuredLabelWidth)
            .max() ?? 0
        let measuredTextWidth = widestLabel + SettingsPopupMetrics.labelMeasurementTolerance
        let popupContentWidth = measuredTextWidth + SettingsPopupMetrics.popupTextChromeWidth
        let triggerContentWidth = measuredTextWidth + SettingsPopupMetrics.triggerTextChromeWidth

        return max(
            SettingsPopupMetrics.minimumWidth,
            ceil(max(popupContentWidth, triggerContentWidth))
        )
    }

    var body: some View {
        dropdownBody
        .frame(width: resolvedWidth, height: height, alignment: .topTrailing)
        .zIndex(isOpen ? 100 : 0)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SettingsPopupFramePreferenceKey.self,
                    value: proxy.frame(in: .named(SettingsPopupHostCoordinateSpace.name))
                )
            }
            SettingsPopupAnchorReader { frame in
                triggerScreenFrame = frame
                if isOpen, popupCoordinator != nil {
                    presentPopup(with: triggerFrame)
                }
            }
        }
        .onPreferenceChange(SettingsPopupFramePreferenceKey.self) { frame in
            triggerFrame = frame
            if isOpen, popupCoordinator != nil {
                presentPopup(with: frame)
            }
        }
        .onChange(of: selection) { _, _ in
            closePopup()
        }
        .onDisappear {
            closePopup()
        }
    }

    @ViewBuilder
    private var dropdownBody: some View {
        if popupCoordinator == nil {
            inlineFallbackBody
        } else {
            trigger
        }
    }

    private var trigger: some View {
        Button {
            togglePopup()
        } label: {
            HStack(spacing: 8) {
                Text(currentLabel)
                    .font(TF.settingsFontControl)
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.down")
                    .font(TF.settingsFontIconMicro)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(width: SettingsPopupMetrics.chevronWidth, height: 8)
            }
            .padding(.leading, SettingsPopupMetrics.textLeadingInset)
            .padding(.trailing, SettingsPopupMetrics.triggerTrailingInset)
            .frame(width: resolvedWidth, height: height, alignment: .trailing)
            .background {
                RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous)
                    .fill(isOpen || isTriggerHovered ? TF.settingsSelectionFill : TF.settingsDropdownTriggerFill)
            }
            .contentShape(RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isTriggerHovered = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isTriggerHovered = true
            case .ended:
                isTriggerHovered = false
            }
        }
    }

    private var inlineFallbackBody: some View {
        ZStack(alignment: .topTrailing) {
            trigger

            if isOpen {
                popupCard(selection: selection, width: resolvedWidth, options: options) { value in
                    selection = value
                    closePopup()
                }
                .offset(y: height + 8)
                .zIndex(1)
            }
        }
    }

    private func togglePopup() {
        if isOpen {
            closePopup()
        } else {
            isOpen = true
            if popupCoordinator != nil {
                presentPopup(with: triggerFrame)
            }
        }
    }

    private func closePopup() {
        isOpen = false
        popupCoordinator?.dismiss(id: id)
    }

    private func presentPopup(with frame: CGRect) {
        popupCoordinator?.present(
            SettingsPopupCoordinator.ActivePopup(
                id: id,
                triggerFrame: frame,
                triggerScreenFrame: triggerScreenFrame,
                selection: selection,
                options: options,
                width: resolvedWidth,
                height: height,
                onSelect: { value in
                    selection = value
                    closePopup()
                },
                onDismiss: {
                    isOpen = false
                }
            )
        )
    }

    private static func measuredLabelWidth(_ label: String) -> CGFloat {
        let font = TF.settingsNSFontBodyStrong
        return (label as NSString).size(withAttributes: [.font: font]).width
    }
}

private struct SettingsPopupAnchorReader: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> SettingsPopupAnchorView {
        let view = SettingsPopupAnchorView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: SettingsPopupAnchorView, context: Context) {
        nsView.onChange = onChange
        nsView.scheduleReport()
    }
}

private final class SettingsPopupAnchorView: NSView {
    var onChange: ((CGRect) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleReport()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleReport()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        scheduleReport()
    }

    func scheduleReport() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let frameInWindow = self.convert(self.bounds, to: nil)
            self.onChange?(window.convertToScreen(frameInWindow))
        }
    }
}

private struct SettingsPopupOverlay: View {
    @ObservedObject var coordinator: SettingsPopupCoordinator
    let hostSize: CGSize

    var body: some View {
        if let popup = coordinator.activePopup {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        coordinator.dismiss(id: popup.id)
                    }

                if popup.triggerScreenFrame == .zero {
                    popupCard(selection: popup.selection, width: popup.width, options: popup.options) { value in
                        popup.onSelect(value)
                        coordinator.dismiss(id: popup.id)
                    }
                    .position(
                        x: popupOrigin(for: popup).x + popup.width / 2,
                        y: popupOrigin(for: popup).y + popupHeight(for: popup) / 2
                    )
                    .zIndex(1)
                }
            }
        }
    }

    private func popupOrigin(for popup: SettingsPopupCoordinator.ActivePopup) -> CGPoint {
        let margin: CGFloat = 8
        let desiredX = popup.triggerFrame.maxX - popup.width
        let maxX = max(hostSize.width - popup.width - margin, margin)
        let x = min(max(desiredX, margin), maxX)

        let belowY = popup.triggerFrame.maxY + 8
        let menuHeight = popupHeight(for: popup)
        let aboveY = popup.triggerFrame.minY - menuHeight - 8
        let hasRoomBelow = belowY + menuHeight <= hostSize.height - margin
        let hasRoomAbove = aboveY >= margin
        let y = hasRoomBelow || !hasRoomAbove ? belowY : aboveY

        return CGPoint(x: x, y: y)
    }

    private func popupHeight(for popup: SettingsPopupCoordinator.ActivePopup) -> CGFloat {
        SettingsPopupMetrics.popupHeight(optionCount: popup.options.count)
    }
}

private struct SettingsPopupPanelContent: View {
    let selection: String
    let width: CGFloat
    let options: [(value: String, label: String)]
    let onSelect: (String) -> Void

    var body: some View {
        popupCard(selection: selection, width: width, options: options, forceDark: true, onSelect: onSelect)
            .fixedSize(horizontal: true, vertical: true)
    }
}

struct SettingsPopupCard<Content: View>: View {
    let width: CGFloat
    let padding: CGFloat
    let forceDark: Bool
    @ViewBuilder let content: () -> Content

    init(
        width: CGFloat,
        padding: CGFloat = 8,
        forceDark: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.width = width
        self.padding = padding
        self.forceDark = forceDark
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(width: width, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: TF.settingsPrimaryCardCornerRadius, style: .continuous)
                    .fill(forceDark ? SettingsPopupPanelPalette.cardFill : TF.settingsPopoverFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: TF.settingsPrimaryCardCornerRadius, style: .continuous)
                            .stroke(forceDark ? SettingsPopupPanelPalette.cardEdge : TF.settingsPopoverEdge, lineWidth: 1)
                    }
                    .shadow(color: SettingsPopupPanelPalette.shadowStrong, radius: 24, x: 0, y: 14)
                    .shadow(color: SettingsPopupPanelPalette.shadowSoft, radius: 6, x: 0, y: 3)
            }
    }
}

private func popupCard(
    selection: String,
    width: CGFloat,
    options: [(value: String, label: String)],
    forceDark: Bool = true,
    onSelect: @escaping (String) -> Void
) -> some View {
    SettingsPopupCard(width: width, padding: SettingsPopupMetrics.cardPadding, forceDark: forceDark) {
        VStack(spacing: SettingsPopupMetrics.rowSpacing) {
            ForEach(options, id: \.value) { option in
                SettingsPopupOptionRow(
                    title: option.label,
                    isSelected: option.value == selection,
                    forceDark: forceDark
                ) {
                    onSelect(option.value)
                }
            }
        }
    }
}

private struct SettingsPopupOptionRow: View {
    let title: String
    let isSelected: Bool
    let forceDark: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(TF.settingsFontControl)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsPopupMetrics.optionRowHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: SettingsPopupMetrics.rowHeight, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous)
                    .fill(rowFill)
            }
            .contentShape(RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
            case .ended:
                isHovered = false
            }
        }
    }

    private var rowFill: Color {
        guard isSelected || isHovered else {
            return .clear
        }
        return forceDark ? SettingsPopupPanelPalette.rowFill : TF.settingsSelectionFill
    }

    private var textColor: Color {
        if forceDark {
            return SettingsPopupPanelPalette.text
        }
        return isSelected || isHovered ? TF.settingsSelectionText : TF.settingsText
    }
}
