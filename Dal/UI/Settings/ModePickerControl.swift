import AppKit
import SwiftUI

struct ModePickerControl: View {
    let selectedMode: ProcessingMode?
    @Binding var isOpen: Bool
    @Binding var triggerFrame: CGRect

    var body: some View {
        SettingsButton(
            variant: .secondary,
            width: ModeSettingsLayout.modePickerWidth,
            // 与 modeGutter 同值：收起态按钮文字与下方卡内正文左对齐（2026-06-12 用户拍板）
            horizontalPadding: ModeSettingsLayout.modeGutter,
            onCanvas: true
        ) {
            isOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(selectedMode?.name ?? L("选择模式", "Select Mode"))
                    .foregroundStyle(TF.settingsText)

                Spacer(minLength: 0)

                Image(systemName: "chevron.down")
                    .font(TF.settingsFontIconMicro)
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityLabel(L("选择输出模式", "Select output mode"))
        .settingsScreenFrame($triggerFrame)
        .frame(
            width: ModeSettingsLayout.modePickerWidth,
            height: ModeSettingsLayout.modeToolbarControlHeight,
            alignment: .topLeading
        )
    }
}

struct ModePickerPopover: View {
    let modes: [ProcessingMode]
    let selectedModeId: UUID?
    @Binding var popoverFrame: CGRect
    let hotkeyTitle: (ProcessingMode) -> String
    let onSelect: (UUID) -> Void
    let onCreate: () -> Void

    var body: some View {
        SettingsPopupCard(
            width: ModeSettingsLayout.modePickerPopoverWidth,
            padding: ModePickerControlMetrics.cardPadding
        ) {
            VStack(spacing: ModePickerControlMetrics.rowSpacing) {
                ForEach(modes) { mode in
                    ModePickerOptionRow(
                        mode: mode,
                        isActive: mode.id == selectedModeId,
                        hotkeyTitle: hotkeyTitle(mode)
                    ) {
                        onSelect(mode.id)
                    }
                }

                Rectangle()
                    .fill(TF.settingsStroke.opacity(0.55))
                    .frame(height: ModePickerControlMetrics.dividerHeight)
                    .padding(.vertical, ModePickerControlMetrics.dividerVerticalPadding)

                ModePickerCreateRow {
                    onCreate()
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                NSCursor.arrow.set()
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.arrow.set()
            case .ended:
                break
            }
        }
        .settingsScreenFrame($popoverFrame)
    }
}

enum ModePickerControlMetrics {
    static let rowHeight: CGFloat = 34
    static let rowSpacing: CGFloat = 3
    static let dividerHeight: CGFloat = 1
    static let dividerVerticalPadding: CGFloat = 2
    static let cardPadding: CGFloat = 8

    static func popoverHeight(optionCount: Int) -> CGFloat {
        let safeOptionCount = max(optionCount, 0)
        let rowTotal = CGFloat(safeOptionCount + 1) * rowHeight
        let dividerTotal = dividerHeight + dividerVerticalPadding * 2
        let spacingTotal = CGFloat(safeOptionCount + 1) * rowSpacing
        return rowTotal + dividerTotal + spacingTotal + cardPadding * 2
    }
}

private struct ModePickerCreateRow: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        SettingsSelectableRow(
            isSelected: isHovered,
            minHeight: ModePickerControlMetrics.rowHeight,
            // 与 ModePickerOptionRow 同步：文字与下方卡内正文左对齐
            horizontalPadding: 10,
            verticalPadding: 0,
            action: action
        ) {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(TF.settingsFontCaption)

                Text(L("新建模式", "New Mode"))
                    .font(TF.settingsFontSectionTitle)

                Spacer(minLength: 0)
            }
            .foregroundStyle(isHovered ? TF.settingsSelectionText : TF.settingsTextSecondary)
        }
        .accessibilityLabel(L("新建模式", "New Mode"))
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
