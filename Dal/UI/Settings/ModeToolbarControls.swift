import SwiftUI

struct ModeSettingsButton: View {
    let modeName: String
    let onOpen: () -> Void

    var body: some View {
        SettingsButton(
            variant: .secondary,
            width: ModeSettingsLayout.modeSettingsButtonWidth,
            onCanvas: true,
            action: onOpen
        ) {
            Text(L("设置", "Settings"))
                .font(TF.settingsFontControl)
        }
        .help(L("模式设置", "Mode settings"))
        .accessibilityLabel(L("模式设置", "Mode settings") + " \(modeName)")
    }
}

struct ModeDeleteButton: View {
    let modeName: String
    let onDelete: () -> Void

    var body: some View {
        // 极简版（2026-06-12 用户二次拍板）：细线叉号，悬停变红；确认弹窗保留兜底
        SettingsDeleteIconButton(
            systemName: "xmark",
            accessibilityLabel: L("删除模式", "Delete mode") + " \(modeName)",
            size: ModeSettingsLayout.modeToolbarControlHeight,
            onCanvas: true,
            action: onDelete
        )
    }
}

struct ModeModelStatusIndicator: View {
    let status: ModeModelStatus

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: TF.settingsStatusDotSize, height: TF.settingsStatusDotSize)

            Text(status.title)
                .font(TF.settingsFontControl)
                .foregroundStyle(TF.settingsTextTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(
            width: ModeSettingsLayout.modeModelStatusWidth,
            height: ModeSettingsLayout.modeToolbarControlHeight,
            alignment: .trailing
        )
        .help("\(status.serviceTitle)：\(status.title) · \(status.availabilityTitle)")
        .accessibilityLabel("\(status.serviceTitle)：\(status.title)，\(status.availabilityTitle)")
    }

    private var statusColor: Color {
        status.isAvailable ? TF.settingsAccentGreen : TF.settingsAccentRed
    }
}
