import SwiftUI

struct VocabularyBuiltInFooter: View {
    let summary: String
    let warning: String?
    let onOpenUserFile: () -> Void
    let onReload: () -> Void

    init(
        summary: String,
        warning: String? = nil,
        onOpenUserFile: @escaping () -> Void,
        onReload: @escaping () -> Void
    ) {
        self.summary = summary
        self.warning = warning
        self.onOpenUserFile = onOpenUserFile
        self.onReload = onReload
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(summary)
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsTextTertiary)

                footerTextAction(
                    L("打开用户自定义文件", "Open user custom file"),
                    action: onOpenUserFile
                )
                footerTextAction(L("重新加载", "Reload"), action: onReload)

                Spacer(minLength: 0)
            }

            if let warning {
                Text(warning)
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsAccentAmber)
            }
        }
    }
}

private extension VocabularyBuiltInFooter {
    func footerTextAction(_ title: String, action: @escaping () -> Void) -> some View {
        SettingsLinkButton(title, action: action)
    }
}
