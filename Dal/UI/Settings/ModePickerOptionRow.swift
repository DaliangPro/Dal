import SwiftUI

struct ModePickerOptionRow: View {
    let mode: ProcessingMode
    let isActive: Bool
    let hotkeyTitle: String
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        SettingsSelectableRow(
            isSelected: isActive || isHovered,
            minHeight: ModePickerControlMetrics.rowHeight,
            // 8(弹窗内边距)+10 = 18 = modeGutter：模式名与下方卡内正文左对齐（2026-06-12 用户拍板）
            horizontalPadding: 10,
            verticalPadding: 0,
            action: onSelect
        ) {
            HStack(alignment: .center, spacing: 8) {
                Text(mode.name)
                    .font(TF.settingsFontSectionTitle)
                    .foregroundStyle(isActive || isHovered ? TF.settingsSelectionText : TF.settingsText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(hotkeyTitle)
                    .font(mode.hotkeyCode == nil ? TF.settingsFontCaption : TF.settingsFontMono)
                    .foregroundStyle(TF.settingsTextTertiary)
            }
        }
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
}
