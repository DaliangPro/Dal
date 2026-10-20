import SwiftUI

struct SettingsSearchField: View {
    @Binding var text: String
    let prompt: String
    /// 底色可调：默认与卡片同底；放在同色容器上时传深一档的填充以显出输入区
    var fill: Color = TF.settingsCardAlt

    var body: some View {
        TextField(
            "",
            text: $text,
            prompt: Text(prompt).foregroundStyle(TF.settingsTextTertiary)
        )
        .textFieldStyle(.plain)
        .font(TF.settingsFontBody)
        .foregroundStyle(TF.settingsText)
        .padding(.horizontal, 10)
        .frame(height: TF.settingsControlHeight)
        .background(
            RoundedRectangle(cornerRadius: TF.settingsControlCornerRadius)
                .fill(fill)
        )
    }
}
