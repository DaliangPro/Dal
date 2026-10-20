import AppKit
import SwiftUI

struct ASRGuideLinksView: View {
    let links: [ASRProviderGuideLink]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(links.enumerated()), id: \.offset) { index, link in
                if index > 0 {
                    Text("·")
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                ASRGuideLinkButton(link: link)
            }
        }
    }
}

struct ASRInlineGuideLink: View {
    let link: ASRProviderGuideLink

    var body: some View {
        ASRGuideLinkButton(link: link)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ASRGuideLinkButton: View {
    let link: ASRProviderGuideLink

    var body: some View {
        SettingsLinkButton(link.label, systemImage: "arrow.up.right") {
            NSWorkspace.shared.open(link.url)
        }
    }
}
