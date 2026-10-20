import SwiftUI

/// 历史记录中的 Voice Polish 结果状态。状态映射与视图分离，避免所有结果都被
/// “语音润色”这一笼统标签掩盖，也让颜色之外仍有明确文字和辅助功能说明。
struct VoicePolishHistoryPresentation: Equatable {
    enum Kind: Equatable {
        case success
        case validationFallback
        case timeoutFallback
        case fallback
        case canonical
        case cancelled
        case unknown
    }

    enum Tone: Equatable {
        case success
        case caution
        case failure
    }

    let kind: Kind
    let tone: Tone
    let labelZH: String
    let labelEN: String
    let detailZH: String
    let detailEN: String

    init?(status: String) {
        guard status.hasPrefix("voice_polish_") else { return nil }

        switch status {
        case "voice_polish_success":
            self.init(
                kind: .success,
                tone: .success,
                labelZH: "润色完成",
                labelEN: "Polished",
                detailZH: "语音润色完成，已使用润色结果。",
                detailEN: "Voice Polish completed and the polished result was used."
            )
        case "voice_polish_validation_failed":
            self.init(
                kind: .validationFallback,
                tone: .failure,
                labelZH: "校验回退",
                labelEN: "Check fallback",
                detailZH: "润色结果未通过安全校验，已使用术语纠正后的内容；可安全判断时仅补本地排版。",
                detailEN: "The polished result failed validation, so the terminology-corrected content was used with safe local formatting when possible."
            )
        case "voice_polish_timeout":
            self.init(
                kind: .timeoutFallback,
                tone: .caution,
                labelZH: "超时回退",
                labelEN: "Timed out",
                detailZH: "语音润色超时，已使用术语纠正后的内容；可安全判断时仅补本地排版。",
                detailEN: "Voice Polish timed out, so the terminology-corrected content was used with safe local formatting when possible."
            )
        case "voice_polish_fallback":
            self.init(
                kind: .fallback,
                tone: .failure,
                labelZH: "润色回退",
                labelEN: "Fallback",
                detailZH: "语音润色未完成，已使用术语纠正后的内容；可安全判断时仅补本地排版。",
                detailEN: "Voice Polish did not complete, so the terminology-corrected content was used with safe local formatting when possible."
            )
        case "voice_polish_canonical":
            self.init(
                kind: .canonical,
                tone: .caution,
                labelZH: "主动原文",
                labelEN: "Used original",
                detailZH: "你主动停止等待，已使用术语纠正后的原文。",
                detailEN: "You stopped waiting and used the terminology-corrected transcript."
            )
        case "voice_polish_cancelled":
            self.init(
                kind: .cancelled,
                tone: .caution,
                labelZH: "已取消",
                labelEN: "Cancelled",
                detailZH: "润色未完成且你取消了本次输出，文字没有写入目标位置；这里保存了术语纠正后的原转写，可复制使用。",
                detailEN: "Voice Polish did not complete and you cancelled the output, so nothing was inserted. The terminology-corrected transcript is kept here for copying."
            )
        default:
            self.init(
                kind: .unknown,
                tone: .caution,
                labelZH: "语音润色",
                labelEN: "Voice Polish",
                detailZH: "这是一条语音润色记录。",
                detailEN: "This is a Voice Polish record."
            )
        }
    }

    private init(
        kind: Kind,
        tone: Tone,
        labelZH: String,
        labelEN: String,
        detailZH: String,
        detailEN: String
    ) {
        self.kind = kind
        self.tone = tone
        self.labelZH = labelZH
        self.labelEN = labelEN
        self.detailZH = detailZH
        self.detailEN = detailEN
    }
}

struct RecentHistoryRowView: View {
    let record: HistoryRecord
    let timeText: String
    let isCopied: Bool
    let isCorrected: Bool
    let copyAction: () -> Void
    let learnAction: (() -> Void)?
    let undoCorrectionAction: (() -> Void)?
    let deleteAction: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: GeneralSettingsStyle.recordColumnSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(timeText)
                    .font(TF.settingsFontMono)
                    .monospacedDigit()
                    .foregroundStyle(TF.settingsTextTertiary.opacity(isHovering ? 1.0 : 0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let modeName = record.processingModeDisplayName {
                    Text(modeName)
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(modeName)
                        .accessibilityLabel(L("输出模式", "Output mode"))
                        .accessibilityValue(modeName)
                }

            }
            .frame(width: GeneralSettingsStyle.recordInfoColumnWidth, alignment: .leading)

            // 默认淡一档（与 Prompt 输入区同色），悬停整行提亮（2026-06-12 用户拍板）
            Text(record.finalText)
                .font(TF.settingsFontReading)
                .foregroundStyle(isHovering ? TF.settingsText : TF.settingsTextSecondary)
                .textSelection(.enabled)
                .lineSpacing(GeneralSettingsStyle.recordBodyLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 1) {
                RecentHistoryActionIconButton(
                    systemName: isCopied ? "checkmark" : "square.on.square",
                    accessibilityLabel: isCopied ? L("已复制", "Copied") : L("复制", "Copy"),
                    isDestructive: false,
                    isRowHovering: isHovering,
                    action: copyAction
                )

                if let learnAction {
                    SettingsTextButton(
                        isCorrected ? L("查看/编辑", "View/Edit") : L("纠正", "Correct"),
                        variant: isCorrected ? .success : .secondary,
                        controlSize: .compact,
                        minWidth: isCorrected ? 66 : 52,
                        action: learnAction
                    )
                    .help(isCorrected
                        ? L("查看或修改上次保存的纠正和学习授权", "View or edit the saved correction and learning permissions")
                        : L("纠正结果，并分别选择是否记住术语或学习表达习惯", "Correct the result and separately choose term memory or style learning"))
                    .accessibilityLabel(isCorrected
                        ? L("查看或编辑这条纠正", "View or edit this correction")
                        : L("纠正这条语音润色结果", "Correct this Voice Polish result"))
                }

                if let undoCorrectionAction {
                    RecentHistoryActionIconButton(
                        systemName: "arrow.uturn.backward",
                        accessibilityLabel: L("撤销这条学习记录", "Undo this learned correction"),
                        isDestructive: false,
                        isRowHovering: isHovering,
                        action: undoCorrectionAction
                    )
                }

                RecentHistoryActionIconButton(
                    systemName: "xmark",
                    accessibilityLabel: L("删除", "Delete"),
                    isDestructive: true,
                    isRowHovering: isHovering,
                    action: deleteAction
                )
            }
            .offset(y: GeneralSettingsStyle.recordActionRowOpticalOffset)
        }
        .padding(.vertical, GeneralSettingsStyle.recordRowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }

}

// 最近记录行的图标按钮，可供其他行式列表复用
struct RecentHistoryActionIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let isDestructive: Bool
    let isRowHovering: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        // 纯图标、零背景（2026-06-20 大梁老师拍板）：融入识别记录块,不要 ghost 的矩形底;
        // 图标默认与左侧时间戳同色(三级文字、整行悬停提亮),悬停到按钮上才变绿/红
        Button(action: action) {
            Image(systemName: systemName)
                .font(TF.settingsFontIconBody)
                .foregroundStyle(iconColor)
                .frame(width: GeneralSettingsStyle.recordActionButtonSize, height: GeneralSettingsStyle.recordActionButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var iconColor: Color {
        if isHovering {
            return isDestructive ? TF.settingsAccentRed : TF.settingsAccentGreen
        }
        // 与左侧时间戳完全同色：三级文字，整行悬停时提亮
        return TF.settingsTextTertiary.opacity(isRowHovering ? 1.0 : 0.7)
    }
}
