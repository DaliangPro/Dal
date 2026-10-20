import AppKit
import SwiftUI

enum GeneralSettingsStyle {
    static let surfaceSpacing: CGFloat = TF.settingsInnerCardPadding
    static let componentSpacing: CGFloat = TF.settingsCardSpacing
    static let surfaceCornerRadius: CGFloat = TF.settingsPrimaryCardCornerRadius
    static let sectionCardCornerRadius: CGFloat = surfaceCornerRadius
    static let sectionCardFillColor: Color = TF.settingsCardAlt
    static let sectionCardContentPadding: CGFloat = TF.settingsPrimaryCardPadding
    static let sectionTitleSpacing: CGFloat = componentSpacing
    static let statCardCornerRadius: CGFloat = surfaceCornerRadius
    static let recordRowVerticalPadding: CGFloat = 10
    static let recordColumnSpacing: CGFloat = TF.settingsCardSpacing
    static let recordInfoColumnWidth: CGFloat = 62
    static let recordActionButtonSize: CGFloat = 20
    // 光学对齐 metrics 专用字号，从不渲染（capHeight 计算），不并入字体 token
    static let recordActionIconFontSize: CGFloat = 8.5
    private static let recordBodyMetricsFont = TF.settingsNSFontReading
    private static let recordActionMetricsFont = NSFont.systemFont(ofSize: recordActionIconFontSize, weight: .medium)
    static let recordActionRowOpticalOffset: CGFloat = -(
        ((recordActionButtonSize - recordActionMetricsFont.capHeight) / 2)
        - (recordBodyMetricsFont.ascender - recordBodyMetricsFont.capHeight)
    )
    static let overviewTopSpacing: CGFloat = componentSpacing
    static let overviewHistoryTopSpacing: CGFloat = componentSpacing
    /// Banner 与三张指标卡统一高度；识别记录卡占满剩余空间，
    /// 因此摘要区增高时页面总高度保持不变。
    static let overviewSummaryCardHeight: CGFloat = 76
    static let dalBannerCornerRadius: CGFloat = surfaceCornerRadius
    static let dalBannerHorizontalPadding: CGFloat = surfaceSpacing
    /// 光学补偿：状态按钮有固定行高，实际字形顶部比视图边界低约 8 点。
    static let dalBannerStatusTopPadding: CGFloat = 6
    /// 光学补偿：Caption 行框底部比可见字形多约 2 点。
    static let dalBannerSloganBottomPadding: CGFloat = 12
    static let dalBannerStatusFont = TF.settingsFontCaption
    static let recordBodyLineSpacing: CGFloat = 2
}
