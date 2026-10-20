import SwiftUI

/// 使用原生文字呈现品牌，避免旧位图在安装后继续显示旧名称。
struct SettingsBrandLogo: View {
    @Environment(\.colorScheme) private var colorScheme

    let width: CGFloat
    var lightOpacity: Double = 0.64
    var darkOpacity: Double = 0.70

    var body: some View {
        Text("Dal")
            .font(.system(size: width * 0.40, weight: .semibold, design: .rounded))
            .tracking(-width * 0.012)
            .foregroundStyle(Color.primary)
            .opacity(colorScheme == .dark ? darkOpacity : lightOpacity)
            .frame(width: width, alignment: .leading)
            .accessibilityLabel("Dal")
    }
}
