import Darwin
import Foundation

enum ServerExecutableBuildMode: Sendable {
    case debug
    case release
}

enum ServerExecutableSource: Sendable, Equatable {
    case bundle
    case development
}

struct ResolvedServerExecutable: Sendable, Equatable {
    let executableURL: URL
    let serverScriptURL: URL?
    let source: ServerExecutableSource
}

enum ServerExecutableResolutionError: Error, Equatable {
    case serverNotFound
    case pathEscapesBundle
    case bundleNotExecutable
    case pathEscapesDevelopmentRoot
    case untrustedOwner
    case serverScriptMissing
    case pythonMissing
    case pythonNotExecutable
}

/// 本地 Python 服务入口的唯一信任策略。
///
/// 正式构建只允许执行 App bundle 内的已打包二进制。DEBUG 构建在 bundle
/// 缺少二进制时，才允许通过 `DAL_DEV_SERVER_ROOT` 显式指定仓库根目录；
/// 不扫描当前目录、父目录或家目录中的同名工程。
struct ServerExecutableResolver {
    typealias OwnerIDProvider = (URL) -> UInt32?

    private let fileManager: FileManager
    private let bundleExecutableDirectory: URL?
    private let environment: [String: String]
    private let buildMode: ServerExecutableBuildMode
    private let currentUserID: UInt32
    private let ownerID: OwnerIDProvider

    init(
        fileManager: FileManager,
        bundleExecutableDirectory: URL?,
        environment: [String: String],
        buildMode: ServerExecutableBuildMode,
        currentUserID: UInt32,
        ownerID: @escaping OwnerIDProvider = ServerExecutableResolver.fileOwnerID
    ) {
        self.fileManager = fileManager
        self.bundleExecutableDirectory = bundleExecutableDirectory
        self.environment = environment
        self.buildMode = buildMode
        self.currentUserID = currentUserID
        self.ownerID = ownerID
    }

    static var live: ServerExecutableResolver {
        #if DEBUG
        let buildMode = ServerExecutableBuildMode.debug
        let environment = ProcessInfo.processInfo.environment
        #else
        let buildMode = ServerExecutableBuildMode.release
        let environment: [String: String] = [:]
        #endif
        return ServerExecutableResolver(
            fileManager: .default,
            bundleExecutableDirectory: Bundle.main.executableURL?.deletingLastPathComponent(),
            environment: environment,
            buildMode: buildMode,
            currentUserID: UInt32(geteuid())
        )
    }

    func resolve(name: String) throws -> ResolvedServerExecutable {
        guard isSafeServerName(name) else {
            throw ServerExecutableResolutionError.serverNotFound
        }

        if let bundled = try resolveBundledExecutable(name: name) {
            return bundled
        }

        guard buildMode == .debug,
              let configuredRoot = environment["DAL_DEV_SERVER_ROOT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !configuredRoot.isEmpty,
              configuredRoot.hasPrefix("/") else {
            throw ServerExecutableResolutionError.serverNotFound
        }

        return try resolveDevelopmentExecutable(
            name: name,
            configuredRoot: URL(fileURLWithPath: configuredRoot, isDirectory: true)
        )
    }

    func isAvailable(name: String) -> Bool {
        (try? resolve(name: name)) != nil
    }

    private func resolveBundledExecutable(name: String) throws -> ResolvedServerExecutable? {
        guard let bundleExecutableDirectory else { return nil }
        let bundleRoot = bundleExecutableDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate = bundleExecutableDirectory
            .appendingPathComponent(name, isDirectory: false)
            .standardizedFileURL

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return nil
        }

        let resolvedCandidate = candidate
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard Self.contains(resolvedCandidate, in: bundleRoot) else {
            throw ServerExecutableResolutionError.pathEscapesBundle
        }
        guard !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: resolvedCandidate.path) else {
            throw ServerExecutableResolutionError.bundleNotExecutable
        }

        return ResolvedServerExecutable(
            executableURL: candidate,
            serverScriptURL: nil,
            source: .bundle
        )
    }

    private func resolveDevelopmentExecutable(
        name: String,
        configuredRoot: URL
    ) throws -> ResolvedServerExecutable {
        let developmentRoot = configuredRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isDirectory(developmentRoot), isOwnedByCurrentUser(developmentRoot) else {
            throw ServerExecutableResolutionError.untrustedOwner
        }

        let serverDirectory = configuredRoot
            .appendingPathComponent(name, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard Self.contains(serverDirectory, in: developmentRoot) else {
            throw ServerExecutableResolutionError.pathEscapesDevelopmentRoot
        }
        guard isDirectory(serverDirectory), isOwnedByCurrentUser(serverDirectory) else {
            throw ServerExecutableResolutionError.untrustedOwner
        }

        let serverScript = serverDirectory
            .appendingPathComponent("server.py", isDirectory: false)
            .standardizedFileURL
        let resolvedServerScript = serverScript
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard Self.contains(resolvedServerScript, in: serverDirectory) else {
            throw ServerExecutableResolutionError.pathEscapesDevelopmentRoot
        }
        guard isRegularFile(resolvedServerScript) else {
            throw ServerExecutableResolutionError.serverScriptMissing
        }
        guard isOwnedByCurrentUser(resolvedServerScript) else {
            throw ServerExecutableResolutionError.untrustedOwner
        }

        let python = serverDirectory
            .appendingPathComponent(".venv/bin/python", isDirectory: false)
            .standardizedFileURL
        let resolvedPython = python
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isRegularFile(resolvedPython) else {
            throw ServerExecutableResolutionError.pythonMissing
        }
        guard isTrustedExecutableOwner(resolvedPython) else {
            throw ServerExecutableResolutionError.untrustedOwner
        }
        guard fileManager.isExecutableFile(atPath: resolvedPython.path) else {
            throw ServerExecutableResolutionError.pythonNotExecutable
        }

        return ResolvedServerExecutable(
            executableURL: python,
            serverScriptURL: serverScript,
            source: .development
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func isOwnedByCurrentUser(_ url: URL) -> Bool {
        ownerID(url) == currentUserID
    }

    /// venv 的 python 常是指向 Homebrew/uv 解释器的链接，因此不要求目标仍在
    /// 开发根目录内；目标必须是当前用户或 root 所有的普通可执行文件。
    private func isTrustedExecutableOwner(_ url: URL) -> Bool {
        guard let id = ownerID(url) else { return false }
        return id == currentUserID || id == 0
    }

    private func isSafeServerName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains(":")
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func fileOwnerID(_ url: URL) -> UInt32? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value
    }
}
