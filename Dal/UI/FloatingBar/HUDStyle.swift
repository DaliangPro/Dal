import SwiftUI

enum HUDStyle: String, CaseIterable, Identifiable {
    case appleNative
    case ink

    var id: String { rawValue }

    static func resolved(_ value: String?) -> HUDStyle {
        value.flatMap(Self.init(rawValue:)) ?? .appleNative
    }

    var title: String {
        switch self {
        case .appleNative: L("苹果原生", "Apple Native")
        case .ink: L("墨色", "Ink")
        }
    }

    var subtitle: String {
        switch self {
        case .appleNative: L("通透玻璃，融入桌面", "Translucent glass")
        case .ink: L("纯色沉静，清晰专注", "Solid, calm and clear")
        }
    }
}

private struct HUDStyleKey: EnvironmentKey {
    static let defaultValue = HUDStyle.appleNative
}

extension EnvironmentValues {
    var hudStyle: HUDStyle {
        get { self[HUDStyleKey.self] }
        set { self[HUDStyleKey.self] = newValue }
    }
}

enum InkHUDPalette {
    static let surface = Color(red: 0.11, green: 0.115, blue: 0.125)
    static let border = Color(red: 0.28, green: 0.285, blue: 0.30)
    static let text = Color(red: 0.96, green: 0.95, blue: 0.92)
}

/// 实心底与细描边；内部区域始终完全不透明。
struct InkHUDSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(InkHUDPalette.surface)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(InkHUDPalette.border, lineWidth: 1)
            }
    }
}
