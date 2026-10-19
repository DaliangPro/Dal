import CommonCrypto
import Foundation

// MARK: - 制品清单

struct ModelArtifactFile: Sendable, Equatable {
    let relativePath: String
    let url: URL
    let expectedSize: Int64
    let sha256: String
}

struct ModelArtifactSpec: Sendable, Equatable {
    let id: String
    let revision: String
    let files: [ModelArtifactFile]
}

enum ModelArtifactManifest {
    static let sherpaSenseVoiceArchive = ModelArtifactSpec(
        id: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17",
        revision: "asr-models",
        files: [
            file(
                "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2",
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2",
                163_002_883,
                "7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e"
            ),
        ]
    )

    static let punctuationArchive = ModelArtifactSpec(
        id: "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12",
        revision: "punctuation-models",
        files: [
            file(
                "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12.tar.bz2",
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12.tar.bz2",
                279_028_058,
                "50f73f8cccffc2303999fda28b785ffcffbd7ea442c47385c30b9d045ee6afc3"
            ),
        ]
    )

    static let qwen3LLM = ModelArtifactSpec(
        id: "qwen3.5-9b",
        revision: "3885219b6810b007914f3a7950a8d1b469d598a5",
        files: [
            file(
                "qwen3.5-9b-q4_k_m.gguf",
                "https://hf-mirror.com/unsloth/Qwen3.5-9B-GGUF/resolve/3885219b6810b007914f3a7950a8d1b469d598a5/Qwen3.5-9B-Q4_K_M.gguf",
                5_680_522_464,
                "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8"
            ),
        ]
    )

    static let senseVoice = ModelArtifactSpec(
        id: "sensevoice",
        revision: "3847d57b6bdf2dd8875cb1508d2af43d80a16bf7",
        files: [
            file(
                "model.pt",
                "https://hf-mirror.com/FunAudioLLM/SenseVoiceSmall/resolve/3847d57b6bdf2dd8875cb1508d2af43d80a16bf7/model.pt",
                936_291_369,
                "833ca2dcfdf8ec91bd4f31cfac36d6124e0c459074d5e909aec9cabe6204a3ea"
            ),
            file(
                "config.yaml",
                "https://hf-mirror.com/FunAudioLLM/SenseVoiceSmall/resolve/3847d57b6bdf2dd8875cb1508d2af43d80a16bf7/config.yaml",
                1_855,
                "f71e239ba36705564b5bf2d2ffd07eece07b8e3f2bbf6d2c99d8df856339ac19"
            ),
            file(
                "am.mvn",
                "https://hf-mirror.com/FunAudioLLM/SenseVoiceSmall/resolve/3847d57b6bdf2dd8875cb1508d2af43d80a16bf7/am.mvn",
                11_203,
                "29b3c740a2c0cfc6b308126d31d7f265fa2be74f3bb095cd2f143ea970896ae5"
            ),
            file(
                "chn_jpn_yue_eng_ko_spectok.bpe.model",
                "https://hf-mirror.com/FunAudioLLM/SenseVoiceSmall/resolve/3847d57b6bdf2dd8875cb1508d2af43d80a16bf7/chn_jpn_yue_eng_ko_spectok.bpe.model",
                377_341,
                "aa87f86064c3730d799ddf7af3c04659151102cba548bce325cf06ba4da4e6a8"
            ),
            file(
                "configuration.json",
                "https://hf-mirror.com/FunAudioLLM/SenseVoiceSmall/resolve/3847d57b6bdf2dd8875cb1508d2af43d80a16bf7/configuration.json",
                396,
                "02810a7f8e9e8aee10370a265f7e799728ce25b4c00cdbf4602b303ee395a38e"
            ),
        ]
    )

    static let qwen3ASR = ModelArtifactSpec(
        id: "qwen3-asr",
        revision: "313d850181767edf09f00a9c289becca70e58cd0",
        files: [
            file(
                "config.json",
                "https://hf-mirror.com/mlx-community/Qwen3-ASR-0.6B-4bit/resolve/313d850181767edf09f00a9c289becca70e58cd0/config.json",
                7_187,
                "923618cf5ca452fda0253a6be5c1a17f94a2e4851d3b98beb45848565587bd72"
            ),
            file(
                "model.safetensors",
                "https://hf-mirror.com/mlx-community/Qwen3-ASR-0.6B-4bit/resolve/313d850181767edf09f00a9c289becca70e58cd0/model.safetensors",
                708_236_945,
                "70c7e67e588062adce4f10796e47ad42ead51c6671eda61a0987eae38ca95ddf"
            ),
            file(
                "model.safetensors.index.json",
                "https://hf-mirror.com/mlx-community/Qwen3-ASR-0.6B-4bit/resolve/313d850181767edf09f00a9c289becca70e58cd0/model.safetensors.index.json",
                71_814,
                "e3bb80ef0fd42a5be07b04e90c97d60460bbde8af3531e0bfe9100a61404d81a"
            ),
            file(
                "generation_config.json",
                "https://hf-mirror.com/mlx-community/Qwen3-ASR-0.6B-4bit/resolve/313d850181767edf09f00a9c289becca70e58cd0/generation_config.json",
                142,
                "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"
            ),
            file(
                "merges.txt",
                "https://hf-mirror.com/mlx-community/Qwen3-ASR-0.6B-4bit/resolve/313d850181767edf09f00a9c289becca70e58cd0/merges.txt",
                1_671_853,
                "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"
            ),
            file(
                "preprocessor_config.json",
                "https://hf-mirror.com/mlx-community/Qwen3-ASR-0.6B-4bit/resolve/313d850181767edf09f00a9c289becca70e58cd0/preprocessor_config.json",
                330,
                "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"
            ),
            file(
                "tokenizer_config.json",
                "https://hf-mirror.com/mlx-community/Qwen3-ASR-0.6B-4bit/resolve/313d850181767edf09f00a9c289becca70e58cd0/tokenizer_config.json",
                12_487,
                "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"
            ),
            file(
                "vocab.json",
                "https://hf-mirror.com/mlx-community/Qwen3-ASR-0.6B-4bit/resolve/313d850181767edf09f00a9c289becca70e58cd0/vocab.json",
                2_776_833,
                "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"
            ),
            file(
                "chat_template.json",
                "https://hf-mirror.com/mlx-community/Qwen3-ASR-0.6B-4bit/resolve/313d850181767edf09f00a9c289becca70e58cd0/chat_template.json",
                1_161,
                "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff"
            ),
        ]
    )

    static let all: [ModelArtifactSpec] = [
        sherpaSenseVoiceArchive,
        punctuationArchive,
        qwen3LLM,
        senseVoice,
        qwen3ASR,
    ]

    static func spec(id: String) -> ModelArtifactSpec? {
        all.first { $0.id == id }
    }

    private static func file(
        _ relativePath: String,
        _ url: String,
        _ expectedSize: Int64,
        _ sha256: String
    ) -> ModelArtifactFile {
        ModelArtifactFile(
            relativePath: relativePath,
            url: URL(string: url)!,
            expectedSize: expectedSize,
            sha256: sha256
        )
    }
}

struct ModelArtifactDownloadResult: Sendable, Equatable {
    let statusCode: Int
    let expectedContentLength: Int64
    let suggestedFilename: String?
    let responseURL: URL?
}

enum ModelArtifactError: Error, LocalizedError, Sendable {
    case invalidHTTPStatus(Int)
    case sizeMismatch(expected: Int64, actual: Int64)
    case hashMismatch(expected: String, actual: String)
    case fileNameMismatch(expected: String, actual: String)
    case unsafeArchiveEntry(String)
    case installationFailed(String)
    case downloadFailed(String)
    case archiveOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPStatus(let status):
            return "模型下载返回了无效 HTTP 状态码：\(status)"
        case .sizeMismatch(let expected, let actual):
            return "模型文件大小不匹配：预期 \(expected)，实际 \(actual)"
        case .hashMismatch(let expected, let actual):
            return "模型文件 SHA256 不匹配：预期 \(expected)，实际 \(actual)"
        case .fileNameMismatch(let expected, let actual):
            return "模型下载文件名不匹配：预期 \(expected)，实际 \(actual)"
        case .unsafeArchiveEntry(let detail):
            return "模型归档包含不安全条目：\(detail)"
        case .installationFailed(let detail):
            return "模型安装失败：\(detail)"
        case .downloadFailed(let detail):
            return "模型下载失败：\(detail)"
        case .archiveOperationFailed(let detail):
            return "模型归档操作失败：\(detail)"
        }
    }
}

enum ModelArtifactVerifier {
    /// 校验已经落地的模型目录。运行本地推理前必须重新核对清单中的
    /// 文件集合、普通文件类型、大小和 SHA-256，避免直接信任缓存目录。
    static func verifyInstalledDirectory(
        at directory: URL,
        spec: ModelArtifactSpec
    ) async throws {
        let task = Task.detached(priority: .utility) {
            try verifyInstalledDirectorySynchronously(at: directory, spec: spec)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func verifyInstalledDirectorySynchronously(
        at directory: URL,
        spec: ModelArtifactSpec
    ) throws {
        let rootValues = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ModelArtifactError.installationFailed("模型根目录不是实体目录")
        }

        var expectedFiles = Set<String>()
        for artifact in spec.files {
            let relativePath = artifact.relativePath
            guard !relativePath.isEmpty,
                  !relativePath.hasPrefix("/"),
                  !relativePath.split(separator: "/").contains("..") else {
                throw ModelArtifactError.installationFailed("模型清单路径不安全：\(relativePath)")
            }

            let fileURL = directory.appendingPathComponent(relativePath, isDirectory: false)
            let values = try fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw ModelArtifactError.installationFailed("模型文件不是普通文件：\(relativePath)")
            }
            let actualSize = Int64(values.fileSize ?? -1)
            guard actualSize == artifact.expectedSize else {
                throw ModelArtifactError.sizeMismatch(
                    expected: artifact.expectedSize,
                    actual: actualSize
                )
            }
            let actualHash = try sha256(fileAt: fileURL, checkCancellation: {
                try Task.checkCancellation()
            })
            guard actualHash == artifact.sha256.lowercased() else {
                throw ModelArtifactError.hashMismatch(
                    expected: artifact.sha256.lowercased(),
                    actual: actualHash
                )
            }
            expectedFiles.insert(relativePath)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw ModelArtifactError.installationFailed("无法枚举模型目录")
        }
        let rootPath = directory.resolvingSymlinksInPath().standardizedFileURL.path

        for case let entry as URL in enumerator {
            try Task.checkCancellation()
            let values = try entry.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw ModelArtifactError.unsafeArchiveEntry(
                    "模型目录包含符号链接：\(entry.lastPathComponent)"
                )
            }
            guard values.isDirectory != true else { continue }
            guard values.isRegularFile == true else {
                throw ModelArtifactError.installationFailed(
                    "模型目录包含不可执行的文件类型：\(entry.lastPathComponent)"
                )
            }
            let entryPath = entry.resolvingSymlinksInPath().standardizedFileURL.path
            guard entryPath.hasPrefix(rootPath + "/") else {
                throw ModelArtifactError.installationFailed(
                    "模型目录条目越出根目录：\(entry.lastPathComponent)"
                )
            }
            let relative = String(entryPath.dropFirst(rootPath.count + 1))
            guard expectedFiles.contains(relative) else {
                throw ModelArtifactError.installationFailed(
                    "模型目录包含清单外文件：\(relative)"
                )
            }
        }
    }

    static func verify(
        fileAt fileURL: URL,
        artifact: ModelArtifactFile,
        download: ModelArtifactDownloadResult
    ) throws {
        try verify(
            fileAt: fileURL,
            artifact: artifact,
            download: download,
            checkCancellation: {}
        )
    }

    static func verifyAsync(
        fileAt fileURL: URL,
        artifact: ModelArtifactFile,
        download: ModelArtifactDownloadResult
    ) async throws {
        let task = Task.detached(priority: .utility) {
            try verify(
                fileAt: fileURL,
                artifact: artifact,
                download: download,
                checkCancellation: {
                    try Task.checkCancellation()
                }
            )
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func verify(
        fileAt fileURL: URL,
        artifact: ModelArtifactFile,
        download: ModelArtifactDownloadResult,
        checkCancellation: () throws -> Void
    ) throws {
        try checkCancellation()
        guard download.statusCode == 200 || download.statusCode == 206 else {
            throw ModelArtifactError.invalidHTTPStatus(download.statusCode)
        }

        if download.statusCode == 200,
           download.expectedContentLength != NSURLSessionTransferSizeUnknown,
           download.expectedContentLength != artifact.expectedSize {
            throw ModelArtifactError.sizeMismatch(
                expected: artifact.expectedSize,
                actual: download.expectedContentLength
            )
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch {
            throw ModelArtifactError.downloadFailed(error.localizedDescription)
        }
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualSize == artifact.expectedSize else {
            throw ModelArtifactError.sizeMismatch(
                expected: artifact.expectedSize,
                actual: actualSize
            )
        }

        let expectedFilename = artifact.url.lastPathComponent.removingPercentEncoding
            ?? artifact.url.lastPathComponent
        let actualFilename = download.suggestedFilename
            ?? download.responseURL?.lastPathComponent.removingPercentEncoding
            ?? download.responseURL?.lastPathComponent
            ?? "<missing>"
        guard actualFilename == expectedFilename else {
            throw ModelArtifactError.fileNameMismatch(
                expected: expectedFilename,
                actual: actualFilename
            )
        }

        let expectedHash = artifact.sha256.lowercased()
        guard expectedHash.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil else {
            throw ModelArtifactError.downloadFailed("制品清单缺少有效 SHA256")
        }

        let actualHash = try sha256(
            fileAt: fileURL,
            checkCancellation: checkCancellation
        )
        guard actualHash == expectedHash else {
            throw ModelArtifactError.hashMismatch(
                expected: expectedHash,
                actual: actualHash
            )
        }
    }

    private static func sha256(
        fileAt url: URL,
        checkCancellation: () throws -> Void
    ) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw ModelArtifactError.downloadFailed("无法打开已下载的模型文件")
        }
        stream.open()
        defer { stream.close() }

        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)

        let bufferSize = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            try checkCancellation()
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 {
                CC_SHA256_Update(&context, buffer, CC_LONG(count))
            } else if count == 0 {
                break
            } else {
                throw ModelArtifactError.downloadFailed(
                    stream.streamError?.localizedDescription ?? "读取模型文件失败"
                )
            }
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 下载与文件系统边界

protocol ModelArtifactDownloading: Sendable {
    func download(
        _ artifact: ModelArtifactFile,
        to destination: URL,
        session: URLSession,
        resumeData: Data?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelArtifactDownloadResult
}

final class URLSessionModelArtifactDownloader: ModelArtifactDownloading, @unchecked Sendable {
    func download(
        _ artifact: ModelArtifactFile,
        to destination: URL,
        session: URLSession,
        resumeData: Data?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelArtifactDownloadResult {
        let progressDelegate = ModelArtifactDownloadProgressDelegate(onProgress: onProgress)
        let downloadedFile: URL
        let response: URLResponse

        if let resumeData, !resumeData.isEmpty {
            (downloadedFile, response) = try await session.download(
                resumeFrom: resumeData,
                delegate: progressDelegate
            )
        } else {
            var request = URLRequest(url: artifact.url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpShouldHandleCookies = false
            (downloadedFile, response) = try await session.download(
                for: request,
                delegate: progressDelegate
            )
        }

        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: downloadedFile, to: destination)

        let httpResponse = response as? HTTPURLResponse
        return ModelArtifactDownloadResult(
            statusCode: httpResponse?.statusCode ?? -1,
            expectedContentLength: response.expectedContentLength,
            suggestedFilename: response.suggestedFilename,
            responseURL: response.url
        )
    }
}

private final class ModelArtifactDownloadProgressDelegate:
    NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        _ = session
        _ = bytesWritten
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(min(max(fraction, 0), 1))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        _ = session
        _ = downloadTask
        _ = location
    }
}

protocol ModelFileOperating: Sendable {
    func fileExists(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
    func removeItem(at url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
}

struct DefaultModelFileOperations: ModelFileOperating, Sendable {
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }
}

// MARK: - 安全归档边界

struct ModelArchiveEntry: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case file
        case directory
        case symbolicLink
        case hardLink
    }

    let path: String
    let kind: Kind
    let linkTarget: String?
}

enum ModelArchiveSecurity {
    static func validate(entries: [ModelArchiveEntry]) throws {
        for entry in entries {
            let entryComponents = try validatedEntryComponents(entry.path)
            _ = try resolvedLinkTarget(for: entry, entryComponents: entryComponents)
        }
    }

    static func validate(
        entries: [ModelArchiveEntry],
        withinRoot root: String
    ) throws {
        try validate(entries: entries)
        let rootComponents = try validatedEntryComponents(root)

        for entry in entries {
            let entryComponents = try validatedEntryComponents(entry.path)
            guard entryComponents.starts(with: rootComponents) else {
                throw ModelArtifactError.unsafeArchiveEntry(
                    "\(entry.path) 位于安装根目录 \(root) 之外"
                )
            }
            if let resolvedTarget = try resolvedLinkTarget(
                for: entry,
                entryComponents: entryComponents
            ), !resolvedTarget.starts(with: rootComponents) {
                throw ModelArtifactError.unsafeArchiveEntry(
                    "\(entry.path) 的链接目标位于安装根目录 \(root) 之外"
                )
            }
        }
    }

    private static func resolvedLinkTarget(
        for entry: ModelArchiveEntry,
        entryComponents: [String]
    ) throws -> [String]? {
        guard entry.kind == .symbolicLink || entry.kind == .hardLink else {
            return nil
        }
        guard let target = entry.linkTarget, !target.isEmpty else {
            throw ModelArtifactError.unsafeArchiveEntry(
                "\(entry.path) 缺少链接目标"
            )
        }

        let label = "\(entry.path) -> \(target)"
        let targetComponents = try pathComponents(target, label: label)
        let baseComponents: [String]
        switch entry.kind {
        case .symbolicLink:
            baseComponents = Array(entryComponents.dropLast())
        case .hardLink:
            // tar 中的 hardlink target 以归档根目录为基准。
            baseComponents = []
        case .file, .directory:
            return nil
        }
        return try resolving(
            targetComponents,
            against: baseComponents,
            label: label
        )
    }

    private static func validatedEntryComponents(_ path: String) throws -> [String] {
        let components = try pathComponents(path, label: path)
        if components.contains("..") {
            throw ModelArtifactError.unsafeArchiveEntry("\(path) 包含父目录跳转")
        }
        let filtered = components.filter { $0 != "." }
        guard !filtered.isEmpty else {
            // `.` 作为单独的根目录条目无需落盘，统一拒绝以便缩小解压边界。
            throw ModelArtifactError.unsafeArchiveEntry("\(path) 不是有效的相对路径")
        }
        return filtered
    }

    private static func pathComponents(_ path: String, label: String) throws -> [String] {
        guard !path.isEmpty,
              !path.contains("\0"),
              !path.contains("\n"),
              !path.contains("\r") else {
            throw ModelArtifactError.unsafeArchiveEntry("\(label) 包含无效字符")
        }

        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"), !hasWindowsDrivePrefix(normalized) else {
            throw ModelArtifactError.unsafeArchiveEntry("\(label) 使用绝对路径")
        }
        return normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func hasWindowsDrivePrefix(_ path: String) -> Bool {
        guard path.count >= 2 else { return false }
        let characters = Array(path.utf8.prefix(2))
        let isLetter = (characters[0] >= 65 && characters[0] <= 90)
            || (characters[0] >= 97 && characters[0] <= 122)
        return isLetter && characters[1] == 58
    }

    private static func resolving(
        _ components: [String],
        against base: [String],
        label: String
    ) throws -> [String] {
        var resolved = base
        for component in components {
            switch component {
            case ".", "":
                continue
            case "..":
                guard !resolved.isEmpty else {
                    throw ModelArtifactError.unsafeArchiveEntry("\(label) 跳出归档根目录")
                }
                resolved.removeLast()
            default:
                resolved.append(component)
            }
        }
        return resolved
    }
}

protocol ModelArchiveHandling: Sendable {
    func entries(in archive: URL) throws -> [ModelArchiveEntry]
    func extract(_ archive: URL, to destination: URL) throws
}

struct TarModelArchiveHandler: ModelArchiveHandling, Sendable {
    func entries(in archive: URL) throws -> [ModelArchiveEntry] {
        let paths = try runTar(["-tjf", archive.path])
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let verboseLines = try runTar(["-tvjf", archive.path])
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        guard paths.count == verboseLines.count else {
            throw ModelArtifactError.archiveOperationFailed(
                "tar 列表的条目数不一致，无法安全识别链接"
            )
        }

        return try zip(paths, verboseLines).map { path, verboseLine in
            guard let type = verboseLine.first else {
                throw ModelArtifactError.archiveOperationFailed("tar 返回了空的详细条目")
            }
            switch type {
            case "d":
                return ModelArchiveEntry(path: path, kind: .directory, linkTarget: nil)
            case "l":
                let target = try linkTarget(
                    in: verboseLine,
                    path: path,
                    separator: " -> "
                )
                return ModelArchiveEntry(path: path, kind: .symbolicLink, linkTarget: target)
            case "h":
                let target = try linkTarget(
                    in: verboseLine,
                    path: path,
                    separator: " link to "
                )
                return ModelArchiveEntry(path: path, kind: .hardLink, linkTarget: target)
            case "-":
                return ModelArchiveEntry(path: path, kind: .file, linkTarget: nil)
            default:
                throw ModelArtifactError.unsafeArchiveEntry(
                    "\(path) 是不支持的特殊文件类型 \(type)"
                )
            }
        }
    }

    func extract(_ archive: URL, to destination: URL) throws {
        // 默认实现自身也守住预检闸门，不依赖调用方正确组合两个 API。
        try ModelArchiveSecurity.validate(entries: entries(in: archive))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try runTar([
            "-xjf", archive.path,
            "-C", destination.path,
            "--no-same-owner",
            "--no-same-permissions",
        ])
    }

    private func linkTarget(
        in verboseLine: String,
        path: String,
        separator: String
    ) throws -> String {
        let marker = path + separator
        guard let markerRange = verboseLine.range(of: marker, options: .backwards) else {
            throw ModelArtifactError.archiveOperationFailed(
                "无法识别 tar 链接条目：\(path)"
            )
        }
        let target = String(verboseLine[markerRange.upperBound...])
        guard !target.isEmpty else {
            throw ModelArtifactError.archiveOperationFailed(
                "tar 链接条目缺少目标：\(path)"
            )
        }
        return target
    }

    private func runTar(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.environment = [
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]

        // stdout/stderr 共用同一条管道，避免先等进程退出时 stderr
        // 填满独立管道导致死锁。列表阶段如有警告混入也会解析失败并闭锁拒绝。
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw ModelArtifactError.archiveOperationFailed(error.localizedDescription)
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ModelArtifactError.archiveOperationFailed(
                detail?.isEmpty == false ? detail! : "tar 退出码 \(process.terminationStatus)"
            )
        }
        guard let result = String(data: output, encoding: .utf8) else {
            throw ModelArtifactError.archiveOperationFailed("tar 输出不是有效 UTF-8")
        }
        return result
    }
}

// MARK: - 安装事务对象

enum ModelInstallationLayout: Sendable, Equatable {
    case directory(destination: URL)
    case singleFile(destination: URL)
    case tarBz2(destination: URL, extractedRoot: String, requiredFiles: [String])
}

struct ModelActivitySnapshot: Sendable, Equatable {
    let hasTask: Bool
    let hasSession: Bool
    let progress: Double?
}
