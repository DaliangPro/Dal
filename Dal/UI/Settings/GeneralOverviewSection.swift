import AppKit
import SwiftUI

struct GeneralOverviewSection: View {
    let stats: HistoryStore.Statistics
    let hasMicrophonePermission: Bool
    let hasAccessibilityPermission: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            introBanner
            metricsCard
                .padding(.top, GeneralSettingsStyle.overviewTopSpacing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension GeneralOverviewSection {
    /// 标志垂直居中，右侧角标+标语纵向叠放；高度与下方指标卡一致。
    var introBanner: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(
                cornerRadius: GeneralSettingsStyle.dalBannerCornerRadius,
                style: .continuous
            )
            .fill(GeneralSettingsStyle.sectionCardFillColor)

            HStack(alignment: .center, spacing: 12) {
                SettingsBrandLogo(
                    width: 90,
                    lightOpacity: 0.62,
                    darkOpacity: 0.52
                )
                .rotationEffect(.degrees(-3))
                .offset(y: 1)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, GeneralSettingsStyle.dalBannerHorizontalPadding)

            introStatusStrip
                .padding(.top, GeneralSettingsStyle.dalBannerStatusTopPadding)
                .padding(.trailing, GeneralSettingsStyle.dalBannerHorizontalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            Text(L("让表达自然流畅", "Speak naturally. Write clearly."))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextSecondary.opacity(colorScheme == .dark ? 0.62 : 0.58))
                .lineLimit(1)
                .padding(.trailing, GeneralSettingsStyle.dalBannerHorizontalPadding)
                .padding(.bottom, GeneralSettingsStyle.dalBannerSloganBottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: GeneralSettingsStyle.overviewSummaryCardHeight,
            maxHeight: GeneralSettingsStyle.overviewSummaryCardHeight
        )
    }

    var introStatusStrip: some View {
        HStack(alignment: .center, spacing: 12) {
            IntroStatusChip(
                title: L("麦克风", "Microphone"),
                color: hasMicrophonePermission ? TF.settingsAccentGreen : TF.settingsAccentRed
            ) {
                PermissionManager.openMicrophoneSettings()
            }
            IntroStatusChip(
                title: L("辅助功能", "Accessibility"),
                color: hasAccessibilityPermission ? TF.settingsAccentGreen : TF.settingsAccentRed
            ) {
                PermissionManager.openAccessibilitySettings()
            }

        }
        .fixedSize(horizontal: true, vertical: false)
    }

    var metricsCard: some View {
        HStack(alignment: .top, spacing: GeneralSettingsStyle.componentSpacing) {
            statCard(
                label: L("累计字数", "Total Chars"),
                main: GeneralSettingsFormatters.compactCharacterCount(stats.totalCharacters).main,
                unit: GeneralSettingsFormatters.compactCharacterCount(stats.totalCharacters).unit,
                color: TF.settingsAccentGreen
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)

            statCard(
                label: L("平均速度", "Avg Speed"),
                main: String(format: "%.0f", stats.averageSpeed),
                unit: "token/min",
                color: TF.settingsAccentBlue,
                compactUnit: true
            )

            statCard(
                label: L("节约时间", "Time Saved"),
                main: GeneralSettingsFormatters.compactSavedTime(stats.timeSavedSeconds).main,
                unit: GeneralSettingsFormatters.compactSavedTime(stats.timeSavedSeconds).unit,
                color: TF.settingsAccentAmber
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func statCard(
        label: String,
        main: String,
        unit: String,
        color: Color,
        compactUnit: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(TF.settingsFontMetadata)
                .foregroundStyle(TF.settingsTextTertiary)

            Spacer(minLength: 0)

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(main)
                    .font(TF.settingsFontMetric)
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if !unit.isEmpty {
                    Text(unit)
                        .font(TF.settingsFontBody)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(GeneralSettingsStyle.surfaceSpacing)
        .frame(
            maxWidth: .infinity,
            minHeight: GeneralSettingsStyle.overviewSummaryCardHeight,
            maxHeight: GeneralSettingsStyle.overviewSummaryCardHeight,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: GeneralSettingsStyle.statCardCornerRadius, style: .continuous)
                .fill(TF.settingsStatCardBase)
                .overlay(
                    RoundedRectangle(cornerRadius: GeneralSettingsStyle.statCardCornerRadius, style: .continuous)
                        .fill(color.opacity(0.10))
                )
                // 明暗分层打底 + 一层柔到几乎无形的环境投影补足「浮起」体积（2026-06-14 大梁老师）：
                // 大模糊 + 极低浓度,不是贴上去的硬影;仅浅色,深色不投影
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0 : 0.08), radius: 10, x: 0, y: 2)
        )
    }
}

/// 概览页右上角可点击状态角标：麦克风/辅助功能跳系统授权页（2026-06-22）
private struct IntroStatusChip: View {
    let title: String
    let color: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: TF.settingsStatusDotSize, height: TF.settingsStatusDotSize)
                Text(title)
                    .font(GeneralSettingsStyle.dalBannerStatusFont)
                    .foregroundStyle(isHovered ? TF.settingsTextSecondary : TF.settingsTextTertiary)
                    .lineLimit(1)
            }
            .frame(height: TF.settingsCompactControlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
