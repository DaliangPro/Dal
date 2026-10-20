import Foundation
import os

/// 管理本地语音与语言模型的固定版本下载、校验和原子安装。
actor ModelManager {

    static let shared = ModelManager()

    private let logger = Logger(subsystem: "pro.daliang.muse.models", category: "ModelManager")

    // MARK: - 路径与依赖

    static var defaultModelsDir: String {
        AppPaths.support("models", isDirectory: true).path
    }

    static var userModelsDir: String {
        AppPaths.support("Models", isDirectory: true).path
    }

    private static var downloadsDir: String {
        AppPaths.support("Downloads", isDirectory: true).path
    }

    private let modelsDirectory: URL
    private let userModelsDirectory: URL
    private let downloadsDirectory: URL
    private let downloader: any ModelArtifactDownloading
    private let fileOperations: any ModelFileOperating
    private let archiveHandler: any ModelArchiveHandling
    private let maxRetries: Int

    init(
        modelsDirectory: URL = URL(fileURLWithPath: ModelManager.defaultModelsDir, isDirectory: true),
        userModelsDirectory: URL = URL(fileURLWithPath: ModelManager.userModelsDir, isDirectory: true),
        downloadsDirectory: URL = URL(fileURLWithPath: ModelManager.downloadsDir, isDirectory: true),
        downloader: any ModelArtifactDownloading = URLSessionModelArtifactDownloader(),
        fileOperations: any ModelFileOperating = DefaultModelFileOperations(),
        archiveHandler: any ModelArchiveHandling = TarModelArchiveHandler(),
        maxRetries: Int = 20
    ) {
        self.modelsDirectory = modelsDirectory
        self.userModelsDirectory = userModelsDirectory
        self.downloadsDirectory = downloadsDirectory
        self.downloader = downloader
        self.fileOperations = fileOperations
        self.archiveHandler = archiveHandler
        self.maxRetries = max(1, maxRetries)
    }

    nonisolated static func makeDownloadSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 7_200
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }

    // MARK: - 流式模型

    enum StreamingModel: String, CaseIterable, Sendable {
        case senseVoiceSmall = "sensevoice-small"

        var displayName: String {
            L("SenseVoice 智能识别", "SenseVoice Smart")
        }

        var description: String {
            L(
                "阿里最新模型，中文准确率最高，支持中英粤日韩",
                "Alibaba's latest, best Chinese accuracy, zh/en/yue/ja/ko"
            )
        }

        var directoryName: String {
            "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
        }

        var downloadURL: URL {
            ModelArtifactManifest.sherpaSenseVoiceArchive.files[0].url
        }

        var requiredFiles: [String] {
            ["model.int8.onnx", "tokens.txt"]
        }

        var approximateSizeMB: Int {
            156
        }
    }

    // MARK: - SenseVoice 可用性

    nonisolated static var isSenseVoiceBundled: Bool {
        isSenseVoiceBundled(using: .live)
    }

    nonisolated static func isSenseVoiceBundled(
        using resolver: ServerExecutableResolver
    ) -> Bool {
        resolver.isAvailable(name: "sensevoice-server")
    }

    // MARK: - 辅助模型

    enum AuxModelType: String, CaseIterable, Sendable {
        case punctuation = "punctuation"

        var displayName: String {
            switch self {
            case .punctuation:
                return L("标点恢复模型", "Punctuation")
            }
        }

        var directoryName: String {
            switch self {
            case .punctuation:
                return "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12"
            }
        }

        var downloadURL: URL {
            switch self {
            case .punctuation:
                return ModelArtifactManifest.punctuationArchive.files[0].url
            }
        }

        var isSingleFile: Bool { false }

        var requiredFiles: [String] {
            switch self {
            case .punctuation:
                return ["model.onnx"]
            }
        }

        var approximateSizeMB: Int {
            switch self {
            case .punctuation:
                return 267
            }
        }
    }

    // MARK: - 当前模型选择

    private static let selectedModelKey = "tf_selectedStreamingModel"
    private static let removedModelRawValues: Set<String> = [
        "zipformer-small-ctc", "zipformer-ctc-multi", "paraformer-bilingual",
    ]

    nonisolated static var selectedStreamingModel: StreamingModel {
        get {
            if let raw = UserDefaults.standard.string(forKey: selectedModelKey) {
                if let model = StreamingModel(rawValue: raw) {
                    return model
                }
                if removedModelRawValues.contains(raw) {
                    UserDefaults.standard.set(
                        StreamingModel.senseVoiceSmall.rawValue,
                        forKey: selectedModelKey
                    )
                    return .senseVoiceSmall
                }
            }
            return .senseVoiceSmall
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedModelKey)
        }
    }

    // MARK: - 下载状态

    enum ModelStatus: Sendable, Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case invalid
    }

    private var downloadProgress: [String: Double] = [:]
    private var activeTasks: [String: Task<Void, Error>] = [:]
    private var activeSessions: [String: URLSession] = [:]
    private var resumeData: [String: Data] = [:]
    private var operationIDs: [String: UUID] = [:]
    private var progressGates: [String: ModelOperationProgressGate] = [:]

    // MARK: - 查询

    nonisolated func isModelAvailable(_ model: StreamingModel) -> Bool {
        Self.isLocalASRModelAvailable
    }

    nonisolated static var isLocalASRModelAvailable: Bool {
        isSenseVoiceBundled
            || isSenseVoiceModelDownloaded
            || SenseVoiceServerManager.resolveQwen3ModelPath() != nil
    }

    nonisolated func isSelectedModelAvailable() -> Bool {
        Self.isLocalASRModelAvailable
    }

    nonisolated func areRequiredModelsAvailable() -> Bool {
        isSelectedModelAvailable()
    }

    func status(for model: StreamingModel) -> ModelStatus {
        let key = model.directoryName
        if let progress = downloadProgress[key], progress < 1 {
            return .downloading(progress: progress)
        }
        return isModelAvailable(model) ? .downloaded : .notDownloaded
    }

    nonisolated func modelPath(for model: StreamingModel) -> String? {
        guard isModelAvailable(model) else { return nil }
        return (Self.defaultModelsDir as NSString)
            .appendingPathComponent(model.directoryName)
    }

    nonisolated func isModelAvailable(_ aux: AuxModelType) -> Bool {
        checkFilesInDefaultDirectory(dir: aux.directoryName, files: aux.requiredFiles)
    }

    nonisolated func modelPath(for aux: AuxModelType) -> String? {
        guard isModelAvailable(aux) else { return nil }
        return (Self.defaultModelsDir as NSString)
            .appendingPathComponent(aux.directoryName)
    }

    nonisolated static var isSenseVoiceModelDownloaded: Bool {
        let path = (userModelsDir as NSString)
            .appendingPathComponent("SenseVoiceSmall/model.pt")
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - 下载入口

    func downloadModel(
        _ model: StreamingModel,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let spec = try requiredArtifactSpec(id: model.directoryName)
        let destination = modelsDirectory
            .appendingPathComponent(model.directoryName, isDirectory: true)
        try await install(
            spec: spec,
            layout: .tarBz2(
                destination: destination,
                extractedRoot: model.directoryName,
                requiredFiles: model.requiredFiles
            ),
            onProgress: onProgress
        )
    }

    func cancelDownload(_ model: StreamingModel) {
        cancelGeneric(key: model.directoryName)
    }

    func deleteModel(_ model: StreamingModel) throws {
        cancelGeneric(key: model.directoryName)
        try deleteGeneric(key: model.directoryName)
    }

    func downloadModel(
        _ aux: AuxModelType,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let spec = try requiredArtifactSpec(id: aux.directoryName)
        let destination = modelsDirectory
            .appendingPathComponent(aux.directoryName, isDirectory: true)
        try await install(
            spec: spec,
            layout: .tarBz2(
                destination: destination,
                extractedRoot: aux.directoryName,
                requiredFiles: aux.requiredFiles
            ),
            onProgress: onProgress
        )
    }

    func cancelDownload(_ aux: AuxModelType) {
        cancelGeneric(key: aux.directoryName)
    }

    func deleteModel(_ aux: AuxModelType) throws {
        cancelGeneric(key: aux.directoryName)
        try deleteGeneric(key: aux.directoryName)
    }

    func downloadQwen3LLM(
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let spec = try requiredArtifactSpec(id: "qwen3.5-9b")
        let destination = userModelsDirectory
            .appendingPathComponent("qwen3.5-9b-q4_k_m.gguf")
        try await install(
            spec: spec,
            layout: .singleFile(destination: destination),
            onProgress: onProgress
        )
    }

    func cancelQwen3LLMDownload() {
        cancelGeneric(key: "qwen3.5-9b")
    }

    struct MultiFileModelSpec: Sendable {
        let key: String
        let subdir: String
        let repoBase: String
        let files: [String]
        let requiredFiles: [String]
    }

    static let senseVoiceMultiFile = MultiFileModelSpec(
        key: "sensevoice",
        subdir: "SenseVoiceSmall",
        repoBase: "https://hf-mirror.com/FunAudioLLM/SenseVoiceSmall/resolve/3847d57b6bdf2dd8875cb1508d2af43d80a16bf7/",
        files: [
            "model.pt", "config.yaml", "am.mvn",
            "chn_jpn_yue_eng_ko_spectok.bpe.model", "configuration.json",
        ],
        requiredFiles: ["model.pt", "config.yaml"]
    )

    static let qwen3ASRMultiFile = MultiFileModelSpec(
        key: "qwen3-asr",
        subdir: "Qwen3-ASR",
        repoBase: "https://hf-mirror.com/mlx-community/Qwen3-ASR-0.6B-4bit/resolve/313d850181767edf09f00a9c289becca70e58cd0/",
        files: [
            "config.json", "model.safetensors", "model.safetensors.index.json",
            "generation_config.json", "merges.txt", "preprocessor_config.json",
            "tokenizer_config.json", "vocab.json", "chat_template.json",
        ],
        requiredFiles: ["config.json", "model.safetensors"]
    )

    func downloadMultiFileModel(
        _ model: MultiFileModelSpec,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let spec = try requiredArtifactSpec(id: model.key)
        let manifestFiles = spec.files.map(\.relativePath)
        guard manifestFiles == model.files else {
            throw ModelArtifactError.downloadFailed("下载清单与模型文件列表不一致：\(model.key)")
        }

        let destination = userModelsDirectory
            .appendingPathComponent(model.subdir, isDirectory: true)
        try await install(
            spec: spec,
            layout: .directory(destination: destination),
            onProgress: onProgress
        )
    }

    func cancelMultiFileDownload(_ model: MultiFileModelSpec) {
        cancelGeneric(key: model.key)
    }

    // MARK: - 原子安装事务

    func install(
        spec: ModelArtifactSpec,
        layout: ModelInstallationLayout,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try validate(spec: spec)

        let key = spec.id
        cancelGeneric(key: key, clearResumeData: false)
        pruneResumeData(for: spec)

        let operationID = UUID()
        operationIDs[key] = operationID
        downloadProgress[key] = 0
        let progressGate = ModelOperationProgressGate(handler: onProgress)
        progressGates[key] = progressGate
        progressGate.report(0)

        let session = URLSession(configuration: Self.makeDownloadSessionConfiguration())
        activeSessions[key] = session

        let task = Task { [self] in
            try await performInstallation(
                spec: spec,
                layout: layout,
                operationID: operationID,
                session: session,
                progressGate: progressGate
            )
        }
        activeTasks[key] = task

        defer {
            finishOperation(key: key, operationID: operationID)
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            progressGate.deactivate()
            task.cancel()
            session.invalidateAndCancel()
        }
    }

    func activitySnapshot(for key: String) -> ModelActivitySnapshot {
        ModelActivitySnapshot(
            hasTask: activeTasks[key] != nil,
            hasSession: activeSessions[key] != nil,
            progress: downloadProgress[key]
        )
    }

    private func performInstallation(
        spec: ModelArtifactSpec,
        layout: ModelInstallationLayout,
        operationID: UUID,
        session: URLSession,
        progressGate: ModelOperationProgressGate
    ) async throws {
        let modelDownloads = downloadsDirectory
            .appendingPathComponent(spec.id, isDirectory: true)
        let operationRoot = modelDownloads
            .appendingPathComponent(operationID.uuidString, isDirectory: true)

        defer {
            removeIfPresent(operationRoot)
        }

        try fileOperations.createDirectory(at: operationRoot)
        let artifactRoot = operationRoot.appendingPathComponent("artifacts", isDirectory: true)
        try fileOperations.createDirectory(at: artifactRoot)

        let totalFiles = spec.files.count
        for (index, artifact) in spec.files.enumerated() {
            try Task.checkCancellation()
            let destination = try safeURL(
                for: artifact.relativePath,
                under: artifactRoot
            )
            try fileOperations.createDirectory(at: destination.deletingLastPathComponent())

            let progressHandler: @Sendable (Double) -> Void = { [weak self] fraction in
                let bounded = min(max(fraction, 0), 1)
                let overall = (Double(index) + bounded) / Double(totalFiles)
                progressGate.report(overall)
                Task {
                    await self?.recordProgress(
                        overall,
                        key: spec.id,
                        operationID: operationID
                    )
                }
            }

            try await downloadAndVerify(
                artifact,
                to: destination,
                key: spec.id,
                revision: spec.revision,
                session: session,
                onProgress: progressHandler
            )
        }

        try Task.checkCancellation()
        let candidate = try await prepareCandidate(
            spec: spec,
            layout: layout,
            artifactRoot: artifactRoot,
            operationRoot: operationRoot
        )
        let destination = destination(for: layout)

        try Task.checkCancellation()
        try atomicReplace(candidate: candidate, destination: destination) {
            try self.verifyInstalled(spec: spec, layout: layout, destination: destination)
        }

        recordProgress(1, key: spec.id, operationID: operationID)
        progressGate.report(1)
        logger.info("模型制品 \(spec.id, privacy: .public) 已通过校验并完成原子安装")
    }

    private func downloadAndVerify(
        _ artifact: ModelArtifactFile,
        to destination: URL,
        key: String,
        revision: String,
        session: URLSession,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let resumeKey = Self.resumeKey(
            key: key,
            revision: revision,
            artifact: artifact
        )
        var lastError: Error?

        for attempt in 0..<maxRetries {
            try Task.checkCancellation()
            if attempt > 0 {
                let delay = min(3 + (2 * Double(attempt - 1)), 10)
                logger.info(
                    "重试模型制品 \(key, privacy: .public)/\(artifact.relativePath, privacy: .private)，等待 \(delay)s"
                )
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                try Task.checkCancellation()
            }

            if fileOperations.fileExists(at: destination) {
                try fileOperations.removeItem(at: destination)
            }

            do {
                let result = try await downloader.download(
                    artifact,
                    to: destination,
                    session: session,
                    resumeData: resumeData[resumeKey],
                    onProgress: onProgress
                )
                resumeData[resumeKey] = nil
                try Task.checkCancellation()
                try await ModelArtifactVerifier.verifyAsync(
                    fileAt: destination,
                    artifact: artifact,
                    download: result
                )
                return
            } catch {
                lastError = error
                if Task.isCancelled {
                    throw CancellationError()
                }
                if error is ModelArtifactError {
                    throw error
                }

                if let data = Self.extractResumeData(from: error) {
                    resumeData[resumeKey] = data
                }

                guard attempt + 1 < maxRetries,
                      Self.isRetryableDownloadError(error) || resumeData[resumeKey] != nil else {
                    throw error
                }
            }
        }

        throw lastError ?? ModelArtifactError.downloadFailed(artifact.url.absoluteString)
    }

    private func prepareCandidate(
        spec: ModelArtifactSpec,
        layout: ModelInstallationLayout,
        artifactRoot: URL,
        operationRoot: URL
    ) async throws -> URL {
        switch layout {
        case .directory:
            return artifactRoot

        case .singleFile:
            guard spec.files.count == 1, let artifact = spec.files.first else {
                throw ModelArtifactError.installationFailed("单文件安装清单必须只含一个文件")
            }
            return try safeURL(for: artifact.relativePath, under: artifactRoot)

        case .tarBz2(_, let extractedRoot, let requiredFiles):
            guard spec.files.count == 1, let artifact = spec.files.first else {
                throw ModelArtifactError.installationFailed("归档安装清单必须只含一个文件")
            }
            let archive = try safeURL(for: artifact.relativePath, under: artifactRoot)
            let archiveHandler = self.archiveHandler
            let entries = try await Self.runDetached {
                try archiveHandler.entries(in: archive)
            }
            try Task.checkCancellation()
            try ModelArchiveSecurity.validate(
                entries: entries,
                withinRoot: extractedRoot
            )

            // 列表预检后再次校验归档，避免 staging 文件在预检与解压间被替换。
            try await ModelArtifactVerifier.verifyAsync(
                fileAt: archive,
                artifact: artifact,
                download: ModelArtifactDownloadResult(
                    statusCode: 200,
                    expectedContentLength: artifact.expectedSize,
                    suggestedFilename: artifact.url.lastPathComponent,
                    responseURL: artifact.url
                )
            )
            try Task.checkCancellation()

            let extractionRoot = operationRoot.appendingPathComponent("extracted", isDirectory: true)
            try fileOperations.createDirectory(at: extractionRoot)
            try await Self.runDetached {
                try archiveHandler.extract(archive, to: extractionRoot)
            }
            try Task.checkCancellation()
            try await ModelArtifactVerifier.verifyAsync(
                fileAt: archive,
                artifact: artifact,
                download: ModelArtifactDownloadResult(
                    statusCode: 200,
                    expectedContentLength: artifact.expectedSize,
                    suggestedFilename: artifact.url.lastPathComponent,
                    responseURL: artifact.url
                )
            )
            try Task.checkCancellation()

            let candidate = try safeURL(for: extractedRoot, under: extractionRoot)
            guard fileOperations.fileExists(at: candidate) else {
                throw ModelArtifactError.installationFailed("归档缺少预期根目录：\(extractedRoot)")
            }
            try verifyArchiveCandidate(candidate)
            try verifyRequiredFiles(requiredFiles, under: candidate)
            return candidate
        }
    }

    private func destination(for layout: ModelInstallationLayout) -> URL {
        switch layout {
        case .directory(let destination), .singleFile(let destination):
            return destination
        case .tarBz2(let destination, _, _):
            return destination
        }
    }

    private func atomicReplace(
        candidate: URL,
        destination: URL,
        validate: () throws -> Void
    ) throws {
        guard fileOperations.fileExists(at: candidate) else {
            throw ModelArtifactError.installationFailed("待安装制品不存在")
        }

        try fileOperations.createDirectory(at: destination.deletingLastPathComponent())
        let backup = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).backup-\(UUID().uuidString)"
        )
        var movedOldModel = false
        var installedCandidate = false

        do {
            if fileOperations.fileExists(at: destination) {
                try fileOperations.moveItem(at: destination, to: backup)
                movedOldModel = true
            }

            try fileOperations.moveItem(at: candidate, to: destination)
            installedCandidate = true
            try validate()
        } catch {
            let originalError = error
            var rollbackMessages: [String] = []
            var displacedFailedInstall: URL?

            if installedCandidate, fileOperations.fileExists(at: destination) {
                do {
                    try fileOperations.removeItem(at: destination)
                } catch {
                    let removalError = error
                    let failedInstall = destination.deletingLastPathComponent()
                        .appendingPathComponent(
                            ".\(destination.lastPathComponent).failed-\(UUID().uuidString)"
                        )
                    do {
                        // 删除失败时先把坏制品移出正式路径，确保旧 backup 仍可恢复。
                        try fileOperations.moveItem(at: destination, to: failedInstall)
                        displacedFailedInstall = failedInstall
                    } catch {
                        rollbackMessages.append(
                            "移除失败的新制品：\(removalError.localizedDescription)；"
                                + "隔离失败：\(error.localizedDescription)"
                        )
                    }
                }
            }

            if movedOldModel, fileOperations.fileExists(at: backup) {
                do {
                    try fileOperations.moveItem(at: backup, to: destination)
                } catch {
                    rollbackMessages.append("恢复旧制品：\(error.localizedDescription)")
                }
            }

            if let displacedFailedInstall,
               fileOperations.fileExists(at: displacedFailedInstall) {
                do {
                    try fileOperations.removeItem(at: displacedFailedInstall)
                } catch {
                    rollbackMessages.append("清理已隔离的新制品：\(error.localizedDescription)")
                }
            }

            let rollbackDetail = rollbackMessages.isEmpty
                ? ""
                : "；回滚异常：\(rollbackMessages.joined(separator: "；"))"
            throw ModelArtifactError.installationFailed(
                "\(originalError.localizedDescription)\(rollbackDetail)"
            )
        }

        if movedOldModel, fileOperations.fileExists(at: backup) {
            do {
                try fileOperations.removeItem(at: backup)
            } catch {
                // 新制品已通过安装后校验，此时不能再破坏正式路径；遗留 backup
                // 比尝试回滚到一个可能已被部分删除的 backup 更安全。
                logger.error(
                    "模型 backup 清理失败，将保留已验证的新制品：\(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    private func verifyInstalled(
        spec: ModelArtifactSpec,
        layout: ModelInstallationLayout,
        destination: URL
    ) throws {
        switch layout {
        case .directory:
            for artifact in spec.files {
                let installed = try safeURL(for: artifact.relativePath, under: destination)
                try verifyInstalledArtifact(installed, artifact: artifact)
            }

        case .singleFile:
            guard let artifact = spec.files.first else {
                throw ModelArtifactError.installationFailed("单文件安装清单为空")
            }
            try verifyInstalledArtifact(destination, artifact: artifact)

        case .tarBz2(_, _, let requiredFiles):
            try verifyRequiredFiles(requiredFiles, under: destination)
        }
    }

    private func verifyInstalledArtifact(
        _ installed: URL,
        artifact: ModelArtifactFile
    ) throws {
        // 入场前已做完整 SHA256；同卷原子 rename 后只需确认实体文件和大小仍一致。
        let values = try installed.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == artifact.expectedSize else {
            throw ModelArtifactError.installationFailed(
                "原子安装后的文件完整性检查失败：\(artifact.relativePath)"
            )
        }
    }

    private func verifyRequiredFiles(_ files: [String], under root: URL) throws {
        guard !files.isEmpty else {
            throw ModelArtifactError.installationFailed("归档安装缺少完整性检查文件")
        }
        for file in files {
            let expected = try safeURL(for: file, under: root)
            guard fileOperations.fileExists(at: expected) else {
                throw ModelArtifactError.installationFailed("安装后缺少文件：\(file)")
            }
            let values = try expected.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ModelArtifactError.installationFailed("安装文件不是普通文件：\(file)")
            }
        }
    }

    private func verifyArchiveCandidate(_ candidate: URL) throws {
        let rootValues = try candidate.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ModelArtifactError.installationFailed("归档根目录不是实体目录")
        }

        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: candidate,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ModelArtifactError.installationFailed("无法审计归档安装目录")
        }
        for case let entry as URL in enumerator {
            let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw ModelArtifactError.unsafeArchiveEntry(
                    "安装目录包含符号链接：\(entry.lastPathComponent)"
                )
            }
        }
        if let enumerationError {
            throw ModelArtifactError.installationFailed(
                "归档安装目录审计失败：\(enumerationError.localizedDescription)"
            )
        }
    }

    private func validate(spec: ModelArtifactSpec) throws {
        _ = try safeURL(for: spec.id, under: downloadsDirectory)
        let revision = spec.revision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty,
              !["main", "master", "latest"].contains(revision.lowercased()),
              !spec.files.isEmpty else {
            throw ModelArtifactError.downloadFailed("制品清单缺少固定版本或文件")
        }

        var paths = Set<String>()
        for artifact in spec.files {
            _ = try safeURL(for: artifact.relativePath, under: downloadsDirectory)
            guard paths.insert(artifact.relativePath).inserted,
                  artifact.expectedSize > 0,
                  artifact.sha256.range(
                    of: "^[0-9a-fA-F]{64}$",
                    options: .regularExpression
                  ) != nil,
                  !artifact.url.absoluteString.localizedCaseInsensitiveContains("/resolve/main/") else {
                throw ModelArtifactError.downloadFailed(
                    "制品清单元数据无效：\(artifact.relativePath)"
                )
            }
        }
    }

    private func safeURL(for relativePath: String, under root: URL) throws -> URL {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ModelArtifactError.unsafeArchiveEntry(relativePath)
        }

        let standardizedRoot = root.standardizedFileURL
        let candidate = standardizedRoot
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        let rootPrefix = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw ModelArtifactError.unsafeArchiveEntry(relativePath)
        }
        return candidate
    }

    // MARK: - 状态与重试清理

    private func recordProgress(_ value: Double, key: String, operationID: UUID) {
        guard operationIDs[key] == operationID else { return }
        downloadProgress[key] = min(max(value, 0), 1)
    }

    private func finishOperation(key: String, operationID: UUID) {
        guard operationIDs[key] == operationID else { return }
        progressGates[key]?.deactivate()
        progressGates[key] = nil
        activeTasks[key] = nil
        activeSessions[key]?.invalidateAndCancel()
        activeSessions[key] = nil
        downloadProgress[key] = nil
        operationIDs[key] = nil
    }

    private func cancelGeneric(key: String, clearResumeData: Bool = true) {
        operationIDs[key] = nil
        progressGates[key]?.deactivate()
        progressGates[key] = nil
        activeTasks[key]?.cancel()
        activeTasks[key] = nil
        activeSessions[key]?.invalidateAndCancel()
        activeSessions[key] = nil
        downloadProgress[key] = nil

        if clearResumeData {
            let prefix = key + "\u{1F}"
            for resumeKey in resumeData.keys.filter({ $0.hasPrefix(prefix) }) {
                resumeData[resumeKey] = nil
            }
        }
    }

    private func deleteGeneric(key: String) throws {
        let destination = modelsDirectory.appendingPathComponent(key, isDirectory: true)
        if fileOperations.fileExists(at: destination) {
            try fileOperations.removeItem(at: destination)
            logger.info("已删除模型：\(key, privacy: .public)")
        }
        downloadProgress[key] = nil
    }

    private func removeIfPresent(_ url: URL) {
        guard fileOperations.fileExists(at: url) else { return }
        do {
            try fileOperations.removeItem(at: url)
        } catch {
            logger.error(
                "清理模型 staging 失败：\(url.path, privacy: .private(mask: .hash))，\(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func requiredArtifactSpec(id: String) throws -> ModelArtifactSpec {
        guard let spec = ModelArtifactManifest.spec(id: id) else {
            throw ModelError.manifestMissing(id)
        }
        return spec
    }

    private nonisolated func checkFilesInDefaultDirectory(
        dir: String,
        files: [String]
    ) -> Bool {
        let directory = (Self.defaultModelsDir as NSString).appendingPathComponent(dir)
        return files.allSatisfy { file in
            FileManager.default.fileExists(
                atPath: (directory as NSString).appendingPathComponent(file)
            )
        }
    }

    private static func extractResumeData(from error: Error) -> Data? {
        let nsError = error as NSError
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            return data
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        }
        return nil
    }

    private static func resumeKey(
        key: String,
        revision: String,
        artifact: ModelArtifactFile
    ) -> String {
        [
            key,
            revision,
            artifact.url.absoluteString,
            artifact.sha256.lowercased(),
            artifact.relativePath,
        ].joined(separator: "\u{1F}")
    }

    private func pruneResumeData(for spec: ModelArtifactSpec) {
        let prefix = spec.id + "\u{1F}"
        let validKeys = Set(spec.files.map {
            Self.resumeKey(key: spec.id, revision: spec.revision, artifact: $0)
        })
        for key in resumeData.keys.filter({ $0.hasPrefix(prefix) && !validKeys.contains($0) }) {
            resumeData[key] = nil
        }
    }

    private static func isRetryableDownloadError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let retryableCodes: Set<Int> = [
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorSecureConnectionFailed,
        ]
        return nsError.domain == NSURLErrorDomain && retryableCodes.contains(nsError.code)
    }

    private nonisolated static func runDetached<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - 删除入口

    func deleteLocalModel(id: String) throws {
        let destination: URL?
        let operationKey: String?
        switch id {
        case "qwen3.5-9b":
            destination = userModelsDirectory.appendingPathComponent("qwen3.5-9b-q4_k_m.gguf")
            operationKey = id
        case "sensevoice":
            destination = userModelsDirectory.appendingPathComponent("SenseVoiceSmall", isDirectory: true)
            operationKey = id
        case "qwen3-asr":
            destination = userModelsDirectory.appendingPathComponent("Qwen3-ASR", isDirectory: true)
            operationKey = id
        case "punctuation":
            destination = modelsDirectory.appendingPathComponent(
                AuxModelType.punctuation.directoryName,
                isDirectory: true
            )
            operationKey = AuxModelType.punctuation.directoryName
        default:
            destination = nil
            operationKey = nil
        }

        if let operationKey {
            cancelGeneric(key: operationKey)
        }
        if let destination, fileOperations.fileExists(at: destination) {
            try fileOperations.removeItem(at: destination)
        }
    }

    enum ModelError: Error, LocalizedError {
        case downloadFailed(URL)
        case extractionFailed
        case manifestMissing(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let url):
                return L(
                    "模型下载失败: \(url.lastPathComponent)",
                    "Model download failed: \(url.lastPathComponent)"
                )
            case .extractionFailed:
                return L("模型解压失败", "Model extraction failed")
            case .manifestMissing(let id):
                return L("模型缺少发布清单: \(id)", "Missing model manifest: \(id)")
            }
        }
    }
}

private final class ModelOperationProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (Double) -> Void
    private var isActive = true

    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func report(_ progress: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return }
        handler(progress)
    }

    func deactivate() {
        lock.lock()
        isActive = false
        lock.unlock()
    }
}
