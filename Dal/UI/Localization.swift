import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable {
    case zh
    case en

    /// System language is Chinese? Default to zh, otherwise en.
    static var systemDefault: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? "zh" : "en"
    }

    /// 语言选择存「system」表示跟随系统语言；其余为 zh / en
    static let systemSelection = "system"

    static var current: AppLanguage {
        let stored = UserDefaults.standard.string(forKey: DefaultsKeys.language)
        guard let stored, stored != systemSelection else {
            return AppLanguage(rawValue: systemDefault) ?? .en
        }
        return AppLanguage(rawValue: stored) ?? .en
    }
}

enum SettingsAppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    /// 由存储的外观选择字符串 + 当前系统外观，判断有效外观是否为深色。
    /// selection 非 light/dark（含 system 与首次未设）时跟随系统。
    static func resolvedIsDark(selection: String, systemColorScheme: ColorScheme) -> Bool {
        switch selection {
        case dark.rawValue: return true
        case light.rawValue: return false
        default: return systemColorScheme == .dark
        }
    }
}

/// Inline localization helper. Returns Chinese or English based on app language setting.
func L(_ zh: String, _ en: String) -> String {
    AppLanguage.current == .zh ? zh : en
}
