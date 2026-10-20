import SwiftUI

enum SettingsLayout {
    /// 2026-07-08 大梁老师拍板：整体高度定 560；
    /// 各页自适应——概览/词库缩底部撑满区，输出模式提示词 与测试区等比缩
    static let windowContentHeight: CGFloat = 560
    static let windowMinimumContentWidth: CGFloat = 240
    static let windowMinimumContentHeight: CGFloat = windowContentHeight

    static let sidebarNavTopInset: CGFloat = 48
    /// 纯文字导航收窄（2026-06-11）：最长标题「概览与记录」约 68pt，112 足够并留余量；
    /// 设置浮层面板与此同宽，再窄会挤压面板内的开关行
    static let sidebarControlWidth: CGFloat = 112
    /// 导航左边距（2026-06-11 用户两轮调整后定稿：文字离左缘约 24pt）
    static let sidebarLeadingInset: CGFloat = 12
    static let sidebarTrailingInset: CGFloat = 12
    static let sidebarWidth: CGFloat = sidebarLeadingInset + sidebarControlWidth + sidebarTrailingInset
    static let dividerWidth: CGFloat = 1

    static let functionalAreaWidth: CGFloat = 600
    static let windowContentWidth: CGFloat = sidebarWidth + dividerWidth + functionalAreaWidth

    static let pageTopInset: CGFloat = TF.settingsPagePadding
    /// 2026-07-09 大梁老师拍板：所有页面底部留白 20（试过 25 偏高；其余三边保持 16）
    static let pageBottomInset: CGFloat = 20
    static let pageLeadingInset: CGFloat = TF.settingsPagePadding
    static let pageTrailingInset: CGFloat = TF.settingsPagePadding

    static var pageInsets: EdgeInsets {
        EdgeInsets(
            top: pageTopInset,
            leading: pageLeadingInset,
            bottom: pageBottomInset,
            trailing: pageTrailingInset
        )
    }
}
