import SwiftUI

struct VocabularyEmptyRow: View {
    let message: String

    var body: some View {
        Text(message)
            .font(TF.settingsFontBody)
            .foregroundStyle(TF.settingsTextTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, VocabularySettingsStyle.rowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: VocabularySettingsStyle.rowHeight, alignment: .leading)
    }
}
