import SwiftUI

enum VocabularySettingsStyle {
    static let pageSpacing: CGFloat = 12
    static let panelSwitchWidth: CGFloat = 220
    static let workspaceGap: CGFloat = 10
    static let surfacePadding: CGFloat = 12
    static let panelHeaderHeight: CGFloat = 32
    static let detailPanelPadding: CGFloat = 12
    static let detailPanelWidth: CGFloat = 248
    static let tableHeaderHeight: CGFloat = 28
    static let ruleRowHeight: CGFloat = 42
    static let ruleRowHorizontalPadding: CGFloat = 18
    static let ruleRowSelectionHorizontalInset: CGFloat = 8
    static let ruleRowSelectionVerticalInset: CGFloat = 4
    static let ruleReplacementColumnWidth: CGFloat = 108
    static let ruleActionsColumnWidth: CGFloat = 30
    static let visibleTriggerLimit = 2
    static let compactTokenHeight: CGFloat = 22
    // 与替换规则编辑卡的输入行同宽（卡宽减两侧内边距），两页输入框逐像素一致
    static let hotwordAddControlsWidth: CGFloat = detailPanelWidth - detailPanelPadding * 2
    static let tokenGridTopPadding: CGFloat = 12
    static let stretchedCardBottomSpacing: CGFloat = 12
    static let outerCardCornerRadius: CGFloat = TF.settingsPrimaryCardCornerRadius
    static let outerCardFillColor: Color = TF.settingsCardAlt
    static let footerDividerTopSpacing: CGFloat = 12
    static let footerTopSpacing: CGFloat = 12
    static let rowHeight: CGFloat = 34
    static let inputHeight: CGFloat = 28
    static let rowVerticalPadding: CGFloat = 10
    static let vocabularyTagFillColor: Color = TF.settingsAccentAmber.opacity(0.14)
    static let vocabularyTagHeight: CGFloat = inputHeight
    static let vocabularyTagHorizontalPadding: CGFloat = 10
}
