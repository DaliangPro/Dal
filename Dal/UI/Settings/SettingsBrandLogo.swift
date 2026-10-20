import SwiftUI

/// 三处共用手写字标，原生文字随明暗主题着色并保留无障碍名称。
struct SettingsBrandLogo: View {
    @Environment(\.colorScheme) private var colorScheme

    let width: CGFloat
    var lightOpacity: Double = 0.64
    var darkOpacity: Double = 0.70

    var body: some View {
        Text("Dal")
            .font(.custom("SnellRoundhand-Bold", size: width * 0.52))
            .foregroundStyle(Color.primary)
            .opacity(colorScheme == .dark ? darkOpacity : lightOpacity)
            .frame(width: width, alignment: .leading)
            .accessibilityLabel("Dal")
    }
}
