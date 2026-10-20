import XCTest
@testable import Dal

final class SettingsSidebarHoverTests: XCTestCase {
    func testEachNavigationRowResolvesAcrossItsFullWidth() {
        let stride = SettingsSidebarLayout.navItemHeight + SettingsSidebarLayout.navItemSpacing
        for (index, tab) in SettingsTab.allCases.enumerated() {
            for x in [CGFloat(0), 56, SettingsSidebarLayout.controlWidth - 0.01] {
                for inset in [CGFloat(0), 15, SettingsSidebarLayout.navItemHeight - 0.01] {
                    XCTAssertEqual(SettingsSidebarLayout.navigationTab(at: CGPoint(
                        x: x, y: CGFloat(index) * stride + inset
                    )), tab)
                }
            }
        }
    }

    func testRapidPassesAcrossRowGapsNeverProduceAnEmptyHighlight() {
        let stride = SettingsSidebarLayout.navItemHeight + SettingsSidebarLayout.navItemSpacing
        let height = CGFloat(SettingsTab.allCases.count) * stride - SettingsSidebarLayout.navItemSpacing
        let positions = Array(Swift.stride(from: CGFloat(0), to: height, by: 0.25))
        for pass in [positions, positions.reversed().map { $0 }] {
            let tabs = pass.compactMap {
                SettingsSidebarLayout.navigationTab(at: CGPoint(x: 56, y: $0))
            }
            XCTAssertEqual(tabs.count, pass.count, "行间2pt空隙不能清空悬停高亮")
            let transitions = zip(tabs, tabs.dropFirst()).filter { $0 != $1 }.count
            XCTAssertEqual(transitions, SettingsTab.allCases.count - 1,
                           "一次完整划过只能在相邻行之间切换，不应反复重置")
        }
    }

    func testLeavingNavigationClearsHoverIncludingOuterPadding() {
        let height = CGFloat(SettingsTab.allCases.count)
            * (SettingsSidebarLayout.navItemHeight + SettingsSidebarLayout.navItemSpacing)
            - SettingsSidebarLayout.navItemSpacing
        for point in [CGPoint(x: -0.01, y: 15), CGPoint(x: 112, y: 15),
                      CGPoint(x: 56, y: -0.01), CGPoint(x: 56, y: height)] {
            XCTAssertNil(SettingsSidebarLayout.navigationTab(at: point))
        }
    }
}
