import SwiftUI

// MARK: - Shared UI Helpers

/// 底排按钮组实际宽度上报：弹窗内输入框宽度与按钮排取齐（2026-06-11 用户拍板）
struct SettingsFooterActionsWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

protocol SettingsCardHelpers {}

@MainActor
extension SettingsCardHelpers {

    func settingsGroupCard<Content: View>(
        _ title: String,
        titleFont: Font = TF.settingsFontSectionTitle,
        icon: String? = nil,
        titleLeading: AnyView? = nil,
        titleAccessory: AnyView? = nil,
        trailing: AnyView? = nil,
        expandVertically: Bool = true,
        showsHeader: Bool = true,
        cornerRadius: CGFloat = TF.settingsPrimaryCardCornerRadius,
        headerBottomSpacing: CGFloat = 14,
        contentPadding: CGFloat = TF.settingsPrimaryCardPadding,
        fillColor: Color = TF.settingsCard,
        showsBorder: Bool = true,
        shadowColor: Color = .clear,
        shadowRadius: CGFloat = 0,
        shadowY: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                            .font(TF.settingsFontControl)
                            .foregroundStyle(TF.settingsTextTertiary)
                    }
                    if let titleLeading {
                        titleLeading
                    }
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(TF.settingsText)
                    if let titleAccessory {
                        titleAccessory
                    }
                    Spacer()
                    if let trailing {
                        trailing
                    }
                }
                .padding(.bottom, headerBottomSpacing)
            }

            content()
        }
        .padding(contentPadding)
        .frame(
            maxWidth: .infinity,
            maxHeight: expandVertically ? .infinity : nil,
            alignment: .topLeading
        )
        .background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(fillColor)
                .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
        }
        .overlay {
            if showsBorder {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(TF.settingsStroke, lineWidth: 1)
            }
        }
    }

    // MARK: - Custom Controls

    func settingsInspectorDivider() -> some View {
        Rectangle()
            .fill(TF.settingsStroke.opacity(0.85))
            .frame(height: 1)
    }

    func settingsInspectorRow<Control: View>(
        _ label: String,
        labelWidth: CGFloat = 92,
        rowHeight: CGFloat = 36,
        horizontalPadding: CGFloat = 16,
        pushControlToTrailing: Bool = true,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsText)
                .frame(width: labelWidth, alignment: .leading)

            if pushControlToTrailing {
                Spacer(minLength: 8)
            }

            control()
        }
        .padding(.horizontal, horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
    }

    func settingsInspectorInlineDropdown(
        selection: Binding<String>,
        options: [(value: String, label: String)],
        width: CGFloat? = nil,
        height: CGFloat = 28
    ) -> some View {
        SettingsPopupDropdown(
            selection: selection,
            options: options,
            width: width,
            height: height
        )
    }

    func settingsInspectorInlineField(
        text: Binding<String>,
        prompt: String,
        width: CGFloat = 180,
        height: CGFloat = 28,
        showsUnderline: Bool = true
    ) -> some View {
        // 可编辑性必须可见：原 1px 下划线在深底上不可辨，
        // 改为与下拉同款的圆角底色（showsUnderline 由调用方保留语义，等同「显示外观」）
        // 统一左对齐（与下拉一致）：字符串从头读，左起+尾截断保留有效前缀
        return FixedWidthTextField(text: text, placeholder: prompt, alignment: .left)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, showsUnderline ? 9 : 0)
            .frame(width: width, height: height, alignment: .leading)
            .background {
                if showsUnderline {
                    RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous)
                        .fill(TF.settingsSecondaryActionFill)
                }
            }
    }

    func settingsInspectorInlineSecureField(
        text: Binding<String>,
        prompt: String,
        width: CGFloat = 180,
        height: CGFloat = 28
    ) -> some View {
        FixedWidthSecureField(text: text, placeholder: prompt, alignment: .left)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .frame(width: width, height: height, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: SettingsControlSpec.controlCornerRadius, style: .continuous)
                    .fill(TF.settingsSecondaryActionFill)
            }
    }

    func settingsInspectorReadOnlyValue(
        _ value: String,
        width: CGFloat = 180,
        alignment: Alignment = .leading
    ) -> some View {
        Text(value)
            .font(TF.settingsFontBody)
            .foregroundStyle(TF.settingsText)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: alignment)
            .frame(width: width, alignment: alignment)
    }

    func settingsHeaderStatus(title: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: TF.settingsStatusDotSize, height: TF.settingsStatusDotSize)
            Text(title)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextSecondary)
        }
    }

    func maskedSecret(_ value: String) -> String {
        // 固定 12 点：不随密钥长度抖动，也不泄露首尾字符
        value.isEmpty ? L("未设置", "Not set") : "••••••••••••"
    }
}
