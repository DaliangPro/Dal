import SwiftUI

// Settings UI controls are intentionally centralized here. Feature views should
// compose these controls instead of rebuilding button height, radius, track fill,
// or selected-state backgrounds locally.
enum SettingsControlSpec {
    static let actionHeight = TF.settingsControlHeight
    static let compactActionHeight = TF.settingsCompactControlHeight
    static let actionHorizontalPadding = TF.settingsButtonHorizontalPadding
    static let compactActionHorizontalPadding = TF.settingsCompactButtonHorizontalPadding
    static let controlCornerRadius = TF.settingsControlCornerRadius
    static let switchOptionSpacing: CGFloat = 2
    static let switchTrackPadding: CGFloat = 2
    static let iconButtonSize = TF.settingsCompactControlHeight
}

enum SettingsButtonVariant: Equatable {
    case primary
    case secondary
    case selected
    case success
    case danger
    case warning
    case ghost
    case link
}

enum SettingsStatusTone: Equatable {
    case neutral
    case success
    case warning
    case danger
}

enum SettingsControlSize: Equatable {
    case regular
    case compact

    var height: CGFloat {
        switch self {
        case .regular:
            return SettingsControlSpec.actionHeight
        case .compact:
            return SettingsControlSpec.compactActionHeight
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .regular:
            return SettingsControlSpec.actionHorizontalPadding
        case .compact:
            return SettingsControlSpec.compactActionHorizontalPadding
        }
    }
}

struct SettingsButton<Label: View>: View {
    let variant: SettingsButtonVariant
    let width: CGFloat?
    let minWidth: CGFloat?
    let height: CGFloat
    let horizontalPadding: CGFloat
    /// 非空时覆盖 variant 底色（状态进按钮的成功/失败整体变色用）
    let fillOverride: Color?
    /// 坐在画布上（非白卡）时为 true：secondary/ghost 改用画布版填充
    let onCanvas: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(
        variant: SettingsButtonVariant = .secondary,
        controlSize: SettingsControlSize = .regular,
        width: CGFloat? = nil,
        minWidth: CGFloat? = nil,
        height: CGFloat? = nil,
        horizontalPadding: CGFloat? = nil,
        fillOverride: Color? = nil,
        onCanvas: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.variant = variant
        self.width = width
        self.minWidth = minWidth
        self.height = height ?? controlSize.height
        self.horizontalPadding = horizontalPadding ?? controlSize.horizontalPadding
        self.fillOverride = fillOverride
        self.onCanvas = onCanvas
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .font(TF.settingsFontControl)
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, horizontalPadding)
                .frame(minWidth: minWidth)
                .frame(width: width, height: height)
                .background {
                    if drawsBackground {
                        RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous)
                            .fill(background)
                    }
                }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: width == nil, vertical: false)
    }

    private var foreground: Color {
        switch variant {
        case .primary:
            return TF.settingsPrimaryActionText
        case .secondary:
            return TF.settingsTextSecondary
        case .selected:
            return TF.settingsText
        case .success:
            return TF.settingsAccentGreen
        case .danger:
            return TF.settingsAccentRed
        case .warning:
            return TF.settingsAccentAmber
        case .ghost:
            return TF.settingsTextTertiary
        case .link:
            return TF.settingsAccentBlue
        }
    }

    private var background: Color {
        if let fillOverride { return fillOverride }
        switch variant {
        case .primary:
            return TF.settingsPrimaryActionFill
        case .secondary:
            return onCanvas ? TF.settingsCanvasActionFill : TF.settingsSecondaryActionFill
        case .selected:
            return TF.settingsSelectionFill
        case .success:
            return TF.settingsSuccessFill
        case .danger:
            return TF.settingsDangerFill
        case .warning:
            return TF.settingsWarningFill
        case .ghost:
            return onCanvas ? TF.settingsCanvasGhostFill : TF.settingsGhostActionFill
        case .link:
            return .clear
        }
    }

    private var drawsBackground: Bool {
        variant != .link
    }
}

/// 删除类图标按钮统一范式（2026-06-12 用户拍板）：默认细线灰、悬停变红
struct SettingsDeleteIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var size: CGFloat = SettingsControlSpec.iconButtonSize
    var onCanvas: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        SettingsIconButton(
            systemName: systemName,
            accessibilityLabel: accessibilityLabel,
            variant: isHovering ? .danger : .ghost,
            size: size,
            onCanvas: onCanvas,
            action: action
        )
        .onHover { isHovering = $0 }
    }
}

/// Text-only action button. Use this for save, restore, edit, cancel, test, and form actions.
struct SettingsTextButton: View {
    let title: String
    let variant: SettingsButtonVariant
    let width: CGFloat?
    let minWidth: CGFloat?
    let height: CGFloat
    let horizontalPadding: CGFloat
    let onCanvas: Bool
    let action: () -> Void

    init(
        _ title: String,
        variant: SettingsButtonVariant = .secondary,
        controlSize: SettingsControlSize = .regular,
        width: CGFloat? = nil,
        minWidth: CGFloat? = nil,
        height: CGFloat? = nil,
        horizontalPadding: CGFloat? = nil,
        onCanvas: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.variant = variant
        self.width = width
        self.minWidth = minWidth
        self.height = height ?? controlSize.height
        self.horizontalPadding = horizontalPadding ?? controlSize.horizontalPadding
        self.onCanvas = onCanvas
        self.action = action
    }

    var body: some View {
        SettingsButton(
            variant: variant,
            width: width,
            minWidth: minWidth,
            height: height,
            horizontalPadding: horizontalPadding,
            onCanvas: onCanvas,
            action: action
        ) {
            Text(title)
        }
    }
}

/// Inline text link. It intentionally does not use the filled button chrome.
struct SettingsLinkButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(TF.settingsFontIconMicro)
                }
            }
            .font(TF.settingsFontCaption)
            .foregroundStyle(TF.settingsAccentBlue)
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Plain hit target for custom content that must not look like an app control.
struct SettingsPlainButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(.plain)
    }
}

/// Square icon action with the same corner and state rules as SettingsButton.
struct SettingsIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let variant: SettingsButtonVariant
    let size: CGFloat
    let onCanvas: Bool
    let action: () -> Void

    init(
        systemName: String,
        accessibilityLabel: String,
        variant: SettingsButtonVariant = .ghost,
        size: CGFloat = SettingsControlSpec.iconButtonSize,
        onCanvas: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.accessibilityLabel = accessibilityLabel
        self.variant = variant
        self.size = size
        self.onCanvas = onCanvas
        self.action = action
    }

    var body: some View {
        SettingsButton(
            variant: variant,
            width: size,
            height: size,
            horizontalPadding: 0,
            onCanvas: onCanvas,
            action: action
        ) {
            Image(systemName: systemName)
                .font(TF.settingsFontIconBody)
        }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Inline remove affordance inside a chip/tag. It is clickable but should not
/// render as a standalone button.
/// J15：加 font/hitSize 参数后同时覆盖常用词规则行的裸叉号删除键（原独立重复实现）。
struct SettingsInlineRemoveButton: View {
    let accessibilityLabel: String
    let font: Font
    let hitSize: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    init(
        accessibilityLabel: String = L("移除", "Remove"),
        font: Font = TF.settingsFontIconMicro,
        hitSize: CGFloat = 10,
        action: @escaping () -> Void
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.font = font
        self.hitSize = hitSize
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(font)
                .foregroundStyle(isHovered ? TF.settingsAccentRed : TF.settingsTextTertiary)
                .frame(width: hitSize, height: hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .onHover { isHovered = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
            case .ended:
                isHovered = false
            }
        }
        .animation(.easeOut(duration: 0.10), value: isHovered)
    }
}

/// Non-interactive label/chip. Do not use this for mutually exclusive choices.
struct SettingsChip: View {
    let title: String
    let width: CGFloat?
    let font: Font
    let foreground: Color
    let fill: Color
    let horizontalPadding: CGFloat
    let height: CGFloat

    init(
        _ title: String,
        controlSize: SettingsControlSize = .regular,
        width: CGFloat? = nil,
        font: Font = TF.settingsFontControl,
        foreground: Color = TF.settingsTextTertiary,
        fill: Color = TF.settingsCardAlt.opacity(0.82),
        horizontalPadding: CGFloat? = nil,
        height: CGFloat? = nil
    ) {
        self.title = title
        self.width = width
        self.font = font
        self.foreground = foreground
        self.fill = fill
        self.horizontalPadding = horizontalPadding ?? controlSize.horizontalPadding
        self.height = height ?? controlSize.height
    }

    var body: some View {
        Text(title)
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .frame(width: width, height: height, alignment: .center)
            .background {
                RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous)
                    .fill(fill)
            }
            .fixedSize(horizontal: width == nil, vertical: false)
    }
}

/// 状态色点：连通状态用纯色点表达（绿=连接正常／黄=待配置／红=连接异常／灰=未测试），
/// 文案挂在悬停提示上（2026-06-11 用户拍板，替代主页卡片右上角的文字徽章）
struct SettingsStatusDot: View {
    let tone: SettingsStatusTone

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: TF.settingsStatusDotSize, height: TF.settingsStatusDotSize)
    }

    private var color: Color {
        switch tone {
        case .neutral:
            return TF.settingsTextTertiary
        case .success:
            return TF.settingsAccentGreen
        case .warning:
            return TF.settingsAccentAmber
        case .danger:
            return TF.settingsAccentRed
        }
    }
}

/// Clickable list/sidebar row using the shared control radius and selected fill.
struct SettingsSelectableRow<Label: View>: View {
    let isSelected: Bool
    let minHeight: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(
        isSelected: Bool,
        minHeight: CGFloat = SettingsControlSpec.actionHeight,
        horizontalPadding: CGFloat = 8,
        verticalPadding: CGFloat = 6,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.isSelected = isSelected
        self.minHeight = minHeight
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous)
                        .fill(isSelected ? TF.settingsSelectionFill : Color.clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 段切换选中块的滑动动画命名空间（2026-06-13）：group 持有,经环境传给各 option 做 matchedGeometryEffect
private struct SettingsSegmentNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}
private struct SettingsSegmentFitsContentKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var settingsSegmentNamespace: Namespace.ID? {
        get { self[SettingsSegmentNamespaceKey.self] }
        set { self[SettingsSegmentNamespaceKey.self] = newValue }
    }
    var settingsSegmentFitsContent: Bool {
        get { self[SettingsSegmentFitsContentKey.self] }
        set { self[SettingsSegmentFitsContentKey.self] = newValue }
    }
}

/// Mutually exclusive switch group, such as language, appearance, library view, and trigger style.
struct SettingsSwitchGroup<Content: View>: View {
    let width: CGFloat?
    let height: CGFloat
    let spacing: CGFloat
    let padding: CGFloat
    let fill: Color
    let drawsBackground: Bool
    /// 毛玻璃底（侧栏设置面板用），与侧栏材质一致
    let usesGlassBackground: Bool
    let fitsContent: Bool
    @ViewBuilder let content: () -> Content

    /// 选中块滑动动画的几何命名空间，传给内部各 option
    @Namespace private var segmentNamespace

    /// 深浅分流（2026-06-14 大梁老师拍板）：深色下这层毛玻璃本身发亮发灰,改走透明+描边融入面板
    @Environment(\.colorScheme) private var colorScheme

    init(
        width: CGFloat? = nil,
        height: CGFloat = SettingsControlSpec.actionHeight,
        spacing: CGFloat = SettingsControlSpec.switchOptionSpacing,
        padding: CGFloat = SettingsControlSpec.switchTrackPadding,
        fill: Color = TF.settingsSegmentTrackFill,
        drawsBackground: Bool = true,
        usesGlassBackground: Bool = false,
        fitsContent: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.width = width
        self.height = height
        self.spacing = spacing
        self.padding = padding
        self.fill = fill
        self.drawsBackground = drawsBackground
        self.usesGlassBackground = usesGlassBackground
        self.fitsContent = fitsContent
        self.content = content
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous)

        return HStack(spacing: spacing) {
            content()
        }
        .padding(padding)
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil && !fitsContent ? .infinity : nil)
        .fixedSize(horizontal: fitsContent && width == nil, vertical: false)
        .background {
            // 段切换/开关轨道取消内凹阴影（2026-06-14 大梁老师拍板）：不要凹槽暗影,纯色平底
            if usesGlassBackground {
                // 浅色:毛玻璃+淡白罩+描边(大梁老师认可);深色:毛玻璃发亮发灰不能用,改透明+描边融入面板
                if colorScheme == .dark {
                    shape.strokeBorder(TF.settingsGlassPanelStroke, lineWidth: 1)
                } else {
                    SettingsSidebarMaterialView(material: .hudWindow)
                        .clipShape(shape)
                        .overlay {
                            shape.fill(TF.settingsGlassTint)
                        }
                        .overlay {
                            shape.strokeBorder(TF.settingsGlassPanelStroke, lineWidth: 1)
                        }
                }
            } else if drawsBackground {
                shape.fill(fill)
            }
        }
        .environment(\.settingsSegmentNamespace, segmentNamespace)
        .environment(\.settingsSegmentFitsContent, fitsContent)
    }
}

/// One option inside SettingsSwitchGroup. The group owns track spacing and padding.
struct SettingsSwitchOption: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.settingsSegmentNamespace) private var segmentNamespace
    @Environment(\.settingsSegmentFitsContent) private var fitsContent

    var body: some View {
        Button {
            // 丝滑滑动（2026-06-13 用户拍板）：选中块经 matchedGeometryEffect 平滑滑到目标,不再硬跳
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                action()
            }
        } label: {
            Text(title)
                .font(TF.settingsFontControl)
                .foregroundStyle(isSelected ? TF.settingsText : TF.settingsTextTertiary)
                .lineLimit(1)
                .padding(.horizontal, fitsContent ? SettingsControlSpec.actionHorizontalPadding : 0)
                .frame(maxWidth: fitsContent ? nil : .infinity, maxHeight: .infinity)
                .background {
                    if isSelected {
                        segmentHighlight
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: fitsContent ? nil : .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var segmentHighlight: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous)
        if let segmentNamespace {
            shape.fill(TF.settingsSegmentSelectedFill)
                .matchedGeometryEffect(id: "settingsSegmentHighlight", in: segmentNamespace)
        } else {
            shape.fill(TF.settingsSegmentSelectedFill)
        }
    }
}
