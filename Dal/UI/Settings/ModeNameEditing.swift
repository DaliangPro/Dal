import Foundation

enum ModeNameEditing {
    static func sanitizedName(_ candidate: String, fallback: String) -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }

        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? L("新模式", "New Mode") : trimmedFallback
    }

    static func uniqueName(base: String, existingNames: [String]) -> String {
        let normalizedBase = sanitizedName(base, fallback: L("新模式", "New Mode"))
        let names = Set(existingNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard names.contains(normalizedBase) else {
            return normalizedBase
        }

        var index = 2
        while names.contains("\(normalizedBase) \(index)") {
            index += 1
        }
        return "\(normalizedBase) \(index)"
    }
}
