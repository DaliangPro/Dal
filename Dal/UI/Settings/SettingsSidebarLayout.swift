import SwiftUI

enum SettingsSidebarLayout {
    static let navTopInset: CGFloat = SettingsLayout.sidebarNavTopInset
    static let controlWidth: CGFloat = SettingsLayout.sidebarControlWidth
    static let leadingInset: CGFloat = SettingsLayout.sidebarLeadingInset
    static let navItemSpacing: CGFloat = 2
    static let navTextLeadingInset: CGFloat = 12
    static let navItemHeight: CGFloat = 30
    static let navItemVerticalPadding: CGFloat = 0
    static let navItemCornerRadius: CGFloat = 8
    static let navItemTextFont = TF.settingsFontNavigation
    static let navItemSelectedTextFont = TF.settingsFontNavigationSelected

    /// 同一个连续区域接收鼠标位置，行间隙延续上一行，跨行不经过空高亮。
    static func navigationTab(at location: CGPoint) -> SettingsTab? {
        let tabs = SettingsTab.allCases
        let stride = navItemHeight + navItemSpacing
        let height = CGFloat(tabs.count) * stride - navItemSpacing
        guard location.x >= 0, location.x < controlWidth,
              location.y >= 0, location.y < height else { return nil }
        return tabs[Int(location.y / stride)]
    }

    static let settingsLeadingInset: CGFloat = SettingsLayout.sidebarLeadingInset
    static let settingsBottomInset: CGFloat = 12
    static let settingsControlWidth: CGFloat = SettingsLayout.sidebarControlWidth
    static let settingsControlHeight: CGFloat = navItemHeight
    static let settingsControlHorizontalPadding: CGFloat = navTextLeadingInset
    static let settingsCornerRadius: CGFloat = TF.settingsPrimaryCardCornerRadius
    static let settingsPanelHorizontalInset: CGFloat = 8
    static let settingsPanelTopInset: CGFloat = 8
    static let settingsPanelBottomInset: CGFloat = 8
    static let settingsPanelTextColor = TF.settingsTextSecondary

    /// 外观、语言、HUD 样式与三个开关，共六行。
    static let settingsPanelOptionHeight: CGFloat = 26
    static let settingsPanelOptionSpacing: CGFloat = 5
    static let settingsPanelOptionRowCount: CGFloat = 6

    static var settingsPanelHeight: CGFloat {
        settingsPanelTopInset
            + settingsPanelBottomInset
            + settingsPanelOptionHeight * settingsPanelOptionRowCount
            + settingsPanelOptionSpacing * settingsPanelOptionRowCount
            + 1 // 上下两区之间的分隔线
    }

    // 红绿灯保持在系统惯例的 16pt，不跟着导航边距走
    private static let trafficLightOpticalInset: CGFloat = 4
    static let trafficLightTopInset: CGFloat = trafficLightLeadingInset

    static var trafficLightLeadingInset: CGFloat {
        leadingInset + trafficLightOpticalInset
    }
}
