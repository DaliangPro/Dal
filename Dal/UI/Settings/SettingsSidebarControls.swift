import SwiftUI

/// 纯文字导航行：选中态只使用暖灰层级与墨色字重，不引入彩色导航指示。
struct SettingsSidebarNavItem: View {
    let tab: SettingsTab
    let isActive: Bool
    let isHovered: Bool
    let showBadge: Bool
    let textLeadingInset: CGFloat
    let verticalPadding: CGFloat
    let cornerRadius: CGFloat
    let controlWidth: CGFloat
    let action: () -> Void

    private var foreground: Color {
        if isActive {
            return TF.settingsSidebarSelectionText
        }
        if isHovered {
            return TF.settingsSidebarHoverText
        }
        return TF.settingsSidebarText
    }

    private var rowFill: Color {
        if isActive {
            return TF.settingsSidebarActiveFill
        }
        if isHovered {
            return TF.settingsSidebarHoverFill
        }
        return .clear
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return SettingsPlainButton(action: action) {
            HStack(spacing: 0) {
                // 不做自动缩字（2026-06-12 用户拍板：各项字号必须一致）；
                // 文案长度由 SettingsTab.displayName 保证放得下
                Text(tab.displayName)
                    .font(
                        isActive
                            ? SettingsSidebarLayout.navItemSelectedTextFont
                            : SettingsSidebarLayout.navItemTextFont
                    )
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                Spacer()
                if showBadge {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, textLeadingInset)
            .padding(.trailing, 12)
            .frame(height: SettingsSidebarLayout.navItemHeight)
            .background {
                shape.fill(rowFill)
            }
            .contentShape(shape)
        }
        .frame(width: controlWidth, height: SettingsSidebarLayout.navItemHeight, alignment: .leading)
    }
}
