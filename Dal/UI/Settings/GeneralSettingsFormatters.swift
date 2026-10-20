import Foundation

enum GeneralSettingsFormatters {
    static func compactCharacterCount(_ count: Int) -> (main: String, unit: String) {
        if count >= 1000 {
            return (String(format: "%.1f", Double(count) / 1000), "K")
        }
        return ("\(count)", "")
    }

    static func compactSavedTime(_ seconds: Double) -> (main: String, unit: String) {
        guard seconds > 0 else { return ("0", L("min", "min")) }
        let minutes = seconds / 60
        if minutes < 60 {
            return (String(format: "%.0f", minutes), L("min", "min"))
        }
        return (String(format: "%.1f", minutes / 60), "h")
    }

    static func recentTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
