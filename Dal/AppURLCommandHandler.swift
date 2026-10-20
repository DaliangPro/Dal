import Foundation

enum AppURLCommandHandler {
    static func handle(_ urls: [URL]) {
        for url in urls {
            guard url.scheme == "dal" else { continue }
            switch url.host {
            case "reload-vocabulary":
                AppLogger.log("[Dal] URL command: reload-vocabulary")
                SnippetStorage.reloadFromDisk()
                HotwordStorage.reloadFromDisk()
            default:
                AppLogger.log("[Dal] Unknown URL command: \(url)")
            }
        }
    }
}
