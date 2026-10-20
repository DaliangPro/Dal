import Foundation
import Security

/// Dal 进程与本地推理子进程之间的会话鉴权。
/// token 只存在于当前进程内存，并通过子进程环境变量传递，不持久化。
enum LocalServiceAuth {
    static let headerName = "X-Muse-Local-Token"
    static let environmentName = "MUSE_LOCAL_AUTH_TOKEN"

    static let token: String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            fatalError("无法生成本地服务会话 token")
        }

        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }()

    static func authorize(_ request: inout URLRequest) {
        request.setValue(token, forHTTPHeaderField: headerName)
    }

    static func serverEnvironment(
        inheriting environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        // 本地服务只需要运行时基础变量。不要把父进程里的 API key、云凭据、
        // 代理认证和开发工具变量带进 Python/打包服务进程。
        let inheritedAllowlist: Set<String> = [
            "PATH",
            "HOME",
            "TMPDIR",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "LC_MESSAGES",
        ]
        var result = environment.filter { inheritedAllowlist.contains($0.key) }
        result[environmentName] = token
        return result
    }
}
