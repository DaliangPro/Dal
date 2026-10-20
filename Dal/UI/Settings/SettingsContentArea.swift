import SwiftUI

private enum SettingsTabPageStyle {
    case fixed
    case scroll(showsIndicators: Bool)
}

struct SettingsContentArea: View {
    let selectedTab: SettingsTab
    let pageInsets: EdgeInsets

    var body: some View {
        currentTabPage
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .settingsPopupHost()
            .background(Rectangle().fill(TF.settingsCanvas))
    }
}

private extension SettingsContentArea {
    @ViewBuilder
    var currentTabPage: some View {
        switch selectedTab.pageStyle {
        case .fixed:
            currentTabContent
                .padding(pageInsets)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .scroll(let showsIndicators):
            GeometryReader { proxy in
                let contentMinHeight = max(0, proxy.size.height - pageInsets.top - pageInsets.bottom)

                ScrollView(showsIndicators: showsIndicators) {
                    VStack(alignment: .leading, spacing: 0) {
                        currentTabContent
                            .frame(maxWidth: .infinity, minHeight: contentMinHeight, alignment: .topLeading)
                    }
                    .padding(pageInsets)
                }
                .settingsThinScrollIndicators()
            }
        }
    }

    @ViewBuilder
    var currentTabContent: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsTab()
        case .models:
            ModelSettingsTab()
        case .vocabulary:
            TerminologySettingsTab()
        case .modes:
            ModesSettingsTab()
        case .about:
            AboutTab()
        }
    }
}

private extension SettingsTab {
    var pageStyle: SettingsTabPageStyle {
        switch self {
        case .general, .modes, .vocabulary:
            .fixed
        case .models, .about:
            .scroll(showsIndicators: false)
        }
    }
}
