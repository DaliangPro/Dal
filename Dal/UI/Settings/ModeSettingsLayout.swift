import SwiftUI

enum ModeSettingsLayout {
    static let inspectorLabelWidth: CGFloat = ModelSettingsStyle.inspectorLabelWidth
    static let inspectorRowHeight: CGFloat = ModelSettingsStyle.inspectorRowHeight
    static let inspectorControlWidth: CGFloat = ModelSettingsStyle.inspectorControlWidth
    /// 铺满可用宽（600 − 左右页边距 16×2 = 568）：四边留白统一 16（2026-07-09 大梁老师）
    static let modeWorkspaceWidth: CGFloat =
        SettingsLayout.functionalAreaWidth - SettingsLayout.pageLeadingInset - SettingsLayout.pageTrailingInset
    static let modeWorkspaceMinHeight: CGFloat =
        SettingsLayout.windowContentHeight - SettingsLayout.pageTopInset - SettingsLayout.pageBottomInset
    static let modeGutter: CGFloat = 18
    // 工具栏高度 = 控件高（2026-06-13 用户拍板）：控件紧贴工具栏不再居中,
    // 顶部第一个组件离背景顶距与其他页一致(16),消除原 42 高居中多出的 7pt 留白
    static let modeToolbarControlHeight: CGFloat = TF.settingsControlHeight
    static let modeToolbarHeight: CGFloat = modeToolbarControlHeight
    // 2026-06-12 用户拍板：模式选择按钮的可视块与下方两张卡的左缘对齐（同贴 x=0）
    static let modeToolbarLeadingInset: CGFloat = 0
    static let modeToolbarTrailingInset: CGFloat = modeGutter
    static let modeModelStatusWidth: CGFloat = 156
    static let modePickerWidth: CGFloat = 118
    static let modePickerPopoverWidth: CGFloat = 178
    static let modePickerPopoverTopOffset: CGFloat = modeToolbarControlHeight + 4
    static let modeWorkbenchGap: CGFloat = TF.settingsInnerCardPadding
    static let modeSectionHeadHeight: CGFloat = 34
    static let modeFieldCornerRadius: CGFloat = TF.settingsInnerCardCornerRadius
    static let modePromptActionSpacing: CGFloat = 8
    static let modeSettingsButtonWidth: CGFloat = 54
    static let modePromptRestoreButtonSize: CGFloat = TF.settingsControlHeight
    static let modePromptSaveButtonWidth: CGFloat = 72
    static let modePromptVerticalPadding: CGFloat = 16
    static let modeSampleVerticalPadding: CGFloat = 14
    // Prompt/测试区高度不再用窗口常量预算——由 ModesSettingsTab 现场几何计算后传入
    // （2026-07-08 大梁老师：写死常量在隐藏标题栏窗口下会产生页尾死白）；
    // 比例仍为 Prompt 50% / 测试区拿剩余（2026-06-25 拍板），见 ModeDetailInner
}

enum ModeSettingsStyle {
    static let cardCornerRadius: CGFloat = TF.settingsPrimaryCardCornerRadius
    static let cardFillColor: Color = Color.clear
    static let sectionSpacing: CGFloat = TF.settingsCardSpacing
}

@MainActor
extension SettingsCardHelpers {
    func modeSettingsCard<Content: View>(
        _ title: String,
        trailing: AnyView? = nil,
        showsHeader: Bool = true,
        contentPadding: CGFloat = 16,
        @ViewBuilder content: () -> Content
    ) -> some View {
        settingsGroupCard(
            title,
            trailing: trailing,
            expandVertically: false,
            showsHeader: showsHeader,
            cornerRadius: ModeSettingsStyle.cardCornerRadius,
            contentPadding: contentPadding,
            fillColor: ModeSettingsStyle.cardFillColor,
            showsBorder: false,
            content: content
        )
    }

}
