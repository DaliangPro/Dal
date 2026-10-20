import SwiftUI

/// 两档润色共用原有隐私偏好，放在模式设置中，避免占用编辑与试跑空间。
struct OutputContextSettings: View {
    @Binding var context: String
    @Binding var recentInput: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L("输入框文字", "Field text"), selection: $context) {
                Text(L("不读取正文", "No body text")).tag(WritingContextLevel.metadataOnly.rawValue)
                Text(L("仅选中文字", "Selected text")).tag(WritingContextLevel.selectedText.rawValue)
                Text(L("光标附近文字", "Nearby text")).tag(WritingContextLevel.nearbyText.rawValue)
            }
            Toggle(L("参考 Dal 最近输入", "Recent Dal input"), isOn: $recentInput)
                .toggleStyle(.switch)
            Text(L("两档润色共用。仅限支持的标准输入框；最近输入只参考同一应用内的记录。", "Shared by both polish modes. Uses supported standard fields and recent Dal input from the same app."))
                .font(TF.settingsFontCaption)
                .foregroundStyle(TF.settingsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
