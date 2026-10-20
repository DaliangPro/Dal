import Foundation

struct SherpaASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.sherpa

    static var credentialFields: [CredentialField] { [] }

    let modelDir: String

    init?(credentials: [String: String]) {
        let dir = credentials["modelDir"] ?? ModelManager.defaultModelsDir
        guard !dir.isEmpty else { return nil }
        self.modelDir = (dir as NSString).expandingTildeInPath
    }

    func toCredentials() -> [String: String] {
        ["modelDir": modelDir]
    }

    var isValid: Bool {
        FileManager.default.fileExists(atPath: modelDir)
    }
}
