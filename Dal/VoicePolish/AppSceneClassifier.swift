import Foundation

enum AppSceneClassifier {
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
    ]

    private static let fixedScenes: [String: WritingScene] = [
        "com.apple.MobileSMS": .chat,
        "com.tencent.xinWeChat": .workChat,
        "com.tinyspeck.slackmacgap": .workChat,
        "com.microsoft.teams2": .workChat,
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.apple.TextEdit": .document,
        "com.microsoft.Word": .document,
        "com.apple.iWork.Pages": .document,
        "com.apple.Notes": .note,
        "md.obsidian": .note,
        "com.apple.dt.Xcode": .code,
        "com.microsoft.VSCode": .code,
        "com.openai.chat": .aiPrompt,
        "ai.perplexity.mac": .aiPrompt,
    ]

    static func classify(
        bundleID: String?,
        focusedRole: String?,
        userOverrides: [String: WritingScene] = [:]
    ) -> WritingScene {
        guard let bundleID, !bundleID.isEmpty else { return .unknown }
        if let override = userOverrides[bundleID] { return override }
        if browserBundleIDs.contains(bundleID) { return .unknown }
        if let fixed = fixedScenes[bundleID] { return fixed }
        if focusedRole == "AXTextArea" || focusedRole == "AXTextField" {
            return .unknown
        }
        return .unknown
    }
}
