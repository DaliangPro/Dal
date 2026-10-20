import CryptoKit
import Foundation
@testable import Dal
import XCTest

final class ModelInstallationTransactionTests: XCTestCase {
    private var rootDirectory: URL!
    private var modelsDirectory: URL!
    private var userModelsDirectory: URL!
    private var downloadsDirectory: URL!

    override func setUpWithError() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dal-model-install-\(UUID().uuidString)", isDirectory: true)
        modelsDirectory = rootDirectory.appendingPathComponent("models", isDirectory: true)
        userModelsDirectory = rootDirectory.appendingPathComponent("Models", isDirectory: true)
        downloadsDirectory = rootDirectory.appendingPathComponent("Downloads", isDirectory: true)
        for directory in [modelsDirectory, userModelsDirectory, downloadsDirectory] {
            try FileManager.default.createDirectory(
                at: try XCTUnwrap(directory),
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        if let rootDirectory,
           FileManager.default.fileExists(atPath: rootDirectory.path) {
            try FileManager.default.removeItem(at: rootDirectory)
        }
        rootDirectory = nil
        modelsDirectory = nil
        userModelsDirectory = nil
        downloadsDirectory = nil
    }

    func testCorrectSHAInstallsVerifiedDirectoryAtomically() async throws {
        let payload = Data("verified-model".utf8)
        let artifact = makeArtifact(path: "model.bin", expectedData: payload)
        let spec = makeSpec(id: "verified-directory", artifacts: [artifact])
        let destination = userModelsDirectory
            .appendingPathComponent("VerifiedModel", isDirectory: true)
        let downloader = FakeModelArtifactDownloader(outcomes: [
            artifact.url: .success(payload),
        ])
        let manager = makeManager(downloader: downloader)

        try await manager.install(
            spec: spec,
            layout: .directory(destination: destination),
            onProgress: { _ in }
        )

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("model.bin")),
            payload
        )
        try assertNoStagingDirectories(for: spec.id)
        await assertIdle(manager, key: spec.id)
    }

    func testWrongSHASameSizePreservesExistingSingleFile() async throws {
        let destination = userModelsDirectory.appendingPathComponent("local-model.gguf")
        let oldData = Data("old-data".utf8)
        let expectedData = Data("new-data".utf8)
        let tamperedData = Data("bad-data".utf8)
        XCTAssertEqual(expectedData.count, tamperedData.count)
        try oldData.write(to: destination)
        let artifact = makeArtifact(path: destination.lastPathComponent, expectedData: expectedData)
        let spec = makeSpec(id: "single-file-hash", artifacts: [artifact])
        let downloader = FakeModelArtifactDownloader(outcomes: [
            artifact.url: .success(tamperedData),
        ])
        let manager = makeManager(downloader: downloader)

        let error = await captureError {
            try await manager.install(
                spec: spec,
                layout: .singleFile(destination: destination),
                onProgress: { _ in }
            )
        }

        assertArtifactError(error, expected: .hashMismatch)
        XCTAssertEqual(try Data(contentsOf: destination), oldData)
        try assertNoStagingDirectories(for: spec.id)
        await assertIdle(manager, key: spec.id)
    }

    func testInterruptedDownloadRemovesStagingAndClearsAllActivity() async throws {
        let expectedData = Data("complete-model".utf8)
        let partialData = Data("partial".utf8)
        let artifact = makeArtifact(path: "model.bin", expectedData: expectedData)
        let spec = makeSpec(id: "interrupted-download", artifacts: [artifact])
        let destination = userModelsDirectory
            .appendingPathComponent("InterruptedModel", isDirectory: true)
        let downloader = FakeModelArtifactDownloader(outcomes: [
            artifact.url: .failureAfterWriting(
                partialData,
                ModelInstallationTestError.interrupted
            ),
        ])
        let progress = ModelProgressRecorder()
        let manager = makeManager(downloader: downloader)

        let error = await captureError {
            try await manager.install(
                spec: spec,
                layout: .directory(destination: destination),
                onProgress: { progress.record($0) }
            )
        }

        XCTAssertNotNil(error)
        XCTAssertTrue(progress.values.contains { $0 > 0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoStagingDirectories(for: spec.id)
        await assertIdle(manager, key: spec.id)
    }

    func testSecondFileFailureLeavesExistingDirectoryUnchanged() async throws {
        let destination = userModelsDirectory
            .appendingPathComponent("ExistingMultiFile", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let oldModel = Data("old-model".utf8)
        let oldConfig = Data("old-config".utf8)
        try oldModel.write(to: destination.appendingPathComponent("model.bin"))
        try oldConfig.write(to: destination.appendingPathComponent("config.json"))

        let newModel = Data("new-model".utf8)
        let newConfig = Data("new-config".utf8)
        let modelArtifact = makeArtifact(path: "model.bin", expectedData: newModel)
        let configArtifact = makeArtifact(path: "config.json", expectedData: newConfig)
        let spec = makeSpec(
            id: "multi-file-second-failure",
            artifacts: [modelArtifact, configArtifact]
        )
        let downloader = FakeModelArtifactDownloader(outcomes: [
            modelArtifact.url: .success(newModel),
            configArtifact.url: .failure(ModelInstallationTestError.interrupted),
        ])
        let manager = makeManager(downloader: downloader)

        let error = await captureError {
            try await manager.install(
                spec: spec,
                layout: .directory(destination: destination),
                onProgress: { _ in }
            )
        }

        XCTAssertNotNil(error)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("model.bin")),
            oldModel
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("config.json")),
            oldConfig
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: userModelsDirectory.path).sorted(),
            [destination.lastPathComponent]
        )
        try assertNoStagingDirectories(for: spec.id)
        await assertIdle(manager, key: spec.id)
    }

    func testIncomingRenameFailureRestoresBackupAndRemovesPartialInstall() async throws {
        let destination = userModelsDirectory
            .appendingPathComponent("RollbackModel", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let oldData = Data("known-good-model".utf8)
        try oldData.write(to: destination.appendingPathComponent("model.bin"))

        let newData = Data("new-verified-model".utf8)
        let artifact = makeArtifact(path: "model.bin", expectedData: newData)
        let spec = makeSpec(id: "rename-rollback", artifacts: [artifact])
        let downloader = FakeModelArtifactDownloader(outcomes: [
            artifact.url: .success(newData),
        ])
        let fileOperations = RenameFailingFileOperations(
            destinationToFailOnce: destination
        )
        let manager = makeManager(
            downloader: downloader,
            fileOperations: fileOperations
        )

        let error = await captureError {
            try await manager.install(
                spec: spec,
                layout: .directory(destination: destination),
                onProgress: { _ in }
            )
        }

        assertArtifactError(error, expected: .installationFailed)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("model.bin")),
            oldData
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: userModelsDirectory.path).sorted(),
            [destination.lastPathComponent],
            "回滚后不应遗留 incoming 或 backup"
        )
        try assertNoStagingDirectories(for: spec.id)
        await assertIdle(manager, key: spec.id)
    }

    func testPostInstallValidationAndRemovalFailureStillRestoresBackup() async throws {
        let destination = userModelsDirectory
            .appendingPathComponent("RollbackAfterValidation", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let oldData = Data("known-good-model".utf8)
        try oldData.write(to: destination.appendingPathComponent("model.bin"))

        let newData = Data("new-verified-model".utf8)
        let artifact = makeArtifact(path: "model.bin", expectedData: newData)
        let spec = makeSpec(id: "post-validation-rollback", artifacts: [artifact])
        let downloader = FakeModelArtifactDownloader(outcomes: [
            artifact.url: .success(newData),
        ])
        let fileOperations = PostInstallCorruptingFileOperations(
            destination: destination,
            installedFile: "model.bin"
        )
        let manager = makeManager(
            downloader: downloader,
            fileOperations: fileOperations
        )

        let error = await captureError {
            try await manager.install(
                spec: spec,
                layout: .directory(destination: destination),
                onProgress: { _ in }
            )
        }

        assertArtifactError(error, expected: .installationFailed)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("model.bin")),
            oldData
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: userModelsDirectory.path).sorted(),
            [destination.lastPathComponent],
            "回滚后不应遗留失败制品或 backup"
        )
        try assertNoStagingDirectories(for: spec.id)
        await assertIdle(manager, key: spec.id)
    }

    func testBackupCleanupErrorAfterRemovalKeepsVerifiedNewModel() async throws {
        let destination = userModelsDirectory
            .appendingPathComponent("CommittedModel", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old-model".utf8).write(
            to: destination.appendingPathComponent("model.bin")
        )
        let newData = Data("new-verified-model".utf8)
        let artifact = makeArtifact(path: "model.bin", expectedData: newData)
        let spec = makeSpec(id: "backup-cleanup-commit", artifacts: [artifact])
        let downloader = FakeModelArtifactDownloader(outcomes: [
            artifact.url: .success(newData),
        ])
        let fileOperations = BackupRemovalAfterDeleteFailingFileOperations(
            destination: destination
        )
        let manager = makeManager(
            downloader: downloader,
            fileOperations: fileOperations
        )

        try await manager.install(
            spec: spec,
            layout: .directory(destination: destination),
            onProgress: { _ in }
        )

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("model.bin")),
            newData
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: userModelsDirectory.path).sorted(),
            [destination.lastPathComponent]
        )
        try assertNoStagingDirectories(for: spec.id)
        await assertIdle(manager, key: spec.id)
    }

    func testParentTraversalArchiveIsRejectedBeforeExtraction() async throws {
        try await assertUnsafeArchiveRejectedBeforeExtraction(
            ModelArchiveEntry(path: "../escaped.bin", kind: .file, linkTarget: nil),
            id: "archive-parent-traversal"
        )
    }

    func testAbsolutePathArchiveIsRejectedBeforeExtraction() async throws {
        try await assertUnsafeArchiveRejectedBeforeExtraction(
            ModelArchiveEntry(path: "/tmp/escaped.bin", kind: .file, linkTarget: nil),
            id: "archive-absolute-path"
        )
    }

    func testLinkEscapingInstalledArchiveRootIsRejectedBeforeExtraction() async throws {
        let id = "archive-link-root-escape"
        let destination = modelsDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let oldData = Data("old-archive-model".utf8)
        try oldData.write(to: destination.appendingPathComponent("model.bin"))
        let archiveData = Data("fake-tar-bz2".utf8)
        let artifact = makeArtifact(path: "model.tar.bz2", expectedData: archiveData)
        let spec = makeSpec(id: id, artifacts: [artifact])
        let downloader = FakeModelArtifactDownloader(outcomes: [
            artifact.url: .success(archiveData),
        ])
        let archiveHandler = ArchiveHandlerSpy(entries: [
            ModelArchiveEntry(path: "model-root", kind: .directory, linkTarget: nil),
            ModelArchiveEntry(path: "payload.bin", kind: .file, linkTarget: nil),
            ModelArchiveEntry(
                path: "model-root/model.bin",
                kind: .symbolicLink,
                linkTarget: "../payload.bin"
            ),
        ])
        let manager = makeManager(
            downloader: downloader,
            archiveHandler: archiveHandler
        )

        let error = await captureError {
            try await manager.install(
                spec: spec,
                layout: .tarBz2(
                    destination: destination,
                    extractedRoot: "model-root",
                    requiredFiles: ["model.bin"]
                ),
                onProgress: { _ in }
            )
        }

        assertArtifactError(error, expected: .unsafeArchiveEntry)
        XCTAssertEqual(archiveHandler.extractInvocationCount, 0)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("model.bin")),
            oldData
        )
        try assertNoStagingDirectories(for: spec.id)
        await assertIdle(manager, key: spec.id)
    }

    func testCancellingCallerCancelsUnderlyingDownloadAndCleansActivity() async throws {
        let payload = Data("cancelled-model".utf8)
        let artifact = makeArtifact(path: "model.bin", expectedData: payload)
        let spec = makeSpec(id: "caller-cancellation", artifacts: [artifact])
        let destination = userModelsDirectory
            .appendingPathComponent("CancelledModel", isDirectory: true)
        let downloader = CancellationObservingDownloader(payload: payload)
        let manager = makeManager(downloader: downloader)

        let installTask = Task {
            try await manager.install(
                spec: spec,
                layout: .directory(destination: destination),
                onProgress: { _ in }
            )
        }
        await downloader.waitUntilStarted()
        installTask.cancel()

        let error = await captureError {
            try await installTask.value
        }

        let didObserveCancellation = await downloader.didObserveCancellation()
        XCTAssertTrue(error is CancellationError)
        XCTAssertTrue(didObserveCancellation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoStagingDirectories(for: spec.id)
        await assertIdle(manager, key: spec.id)
    }

    func testLateProgressCallbackIsIgnoredAfterFailedOperationFinishes() async throws {
        let payload = Data("late-progress-model".utf8)
        let artifact = makeArtifact(path: "model.bin", expectedData: payload)
        let spec = makeSpec(id: "late-progress", artifacts: [artifact])
        let destination = userModelsDirectory
            .appendingPathComponent("LateProgress", isDirectory: true)
        let downloader = LateProgressDownloader()
        let progress = ModelProgressRecorder()
        let manager = makeManager(downloader: downloader)

        _ = await captureError {
            try await manager.install(
                spec: spec,
                layout: .directory(destination: destination),
                onProgress: { progress.record($0) }
            )
        }
        let countAfterFailure = progress.values.count

        await downloader.emitLateProgress(0.75)

        XCTAssertEqual(progress.values.count, countAfterFailure)
        await assertIdle(manager, key: spec.id)
    }

    func testResumeDataIsNotReusedAcrossArtifactRevisions() async throws {
        let oldData = Data("old-revision".utf8)
        let newData = Data("new-revision".utf8)
        XCTAssertEqual(oldData.count, newData.count)
        let oldArtifact = makeArtifact(path: "model.bin", expectedData: oldData)
        let newArtifact = ModelArtifactFile(
            relativePath: "model.bin",
            url: URL(string: "https://example.invalid/revision-2/model.bin")!,
            expectedSize: Int64(newData.count),
            sha256: SHA256.hash(data: newData)
                .map { String(format: "%02x", $0) }
                .joined()
        )
        let oldSpec = ModelArtifactSpec(
            id: "revision-bound-resume",
            revision: "revision-1",
            files: [oldArtifact]
        )
        let newSpec = ModelArtifactSpec(
            id: oldSpec.id,
            revision: "revision-2",
            files: [newArtifact]
        )
        let destination = userModelsDirectory
            .appendingPathComponent("RevisionBound", isDirectory: true)
        let staleResumeData = Data("stale-resume".utf8)
        let downloader = RevisionRecordingDownloader(
            staleResumeData: staleResumeData,
            successPayload: newData
        )
        let manager = makeManager(downloader: downloader)

        _ = await captureError {
            try await manager.install(
                spec: oldSpec,
                layout: .directory(destination: destination),
                onProgress: { _ in }
            )
        }
        try await manager.install(
            spec: newSpec,
            layout: .directory(destination: destination),
            onProgress: { _ in }
        )

        let receivedResumeData = await downloader.receivedResumeData()
        XCTAssertEqual(receivedResumeData.count, 2)
        XCTAssertNil(receivedResumeData[0])
        XCTAssertNil(receivedResumeData[1], "新 revision 不得复用旧制品的断点数据")
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("model.bin")),
            newData
        )
        try assertNoStagingDirectories(for: newSpec.id)
        await assertIdle(manager, key: newSpec.id)
    }

    private func assertUnsafeArchiveRejectedBeforeExtraction(
        _ unsafeEntry: ModelArchiveEntry,
        id: String
    ) async throws {
        let destination = modelsDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let oldData = Data("old-archive-model".utf8)
        try oldData.write(to: destination.appendingPathComponent("model.bin"))
        let archiveData = Data("fake-tar-bz2".utf8)
        let artifact = makeArtifact(path: "model.tar.bz2", expectedData: archiveData)
        let spec = makeSpec(id: id, artifacts: [artifact])
        let downloader = FakeModelArtifactDownloader(outcomes: [
            artifact.url: .success(archiveData),
        ])
        let archiveHandler = ArchiveHandlerSpy(entries: [unsafeEntry])
        let manager = makeManager(
            downloader: downloader,
            archiveHandler: archiveHandler
        )

        let error = await captureError {
            try await manager.install(
                spec: spec,
                layout: .tarBz2(
                    destination: destination,
                    extractedRoot: "model-root",
                    requiredFiles: ["model.bin"]
                ),
                onProgress: { _ in }
            )
        }

        assertArtifactError(error, expected: .unsafeArchiveEntry)
        XCTAssertEqual(archiveHandler.entriesInvocationCount, 1)
        XCTAssertEqual(
            archiveHandler.extractInvocationCount,
            0,
            "不安全 archive 必须在调用 extract 前拒绝"
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("model.bin")),
            oldData
        )
        try assertNoStagingDirectories(for: spec.id)
        await assertIdle(manager, key: spec.id)
    }

    private func makeManager(
        downloader: any ModelArtifactDownloading,
        fileOperations: any ModelFileOperating = TestModelFileOperations(),
        archiveHandler: any ModelArchiveHandling = ArchiveHandlerSpy(entries: [])
    ) -> ModelManager {
        ModelManager(
            modelsDirectory: modelsDirectory,
            userModelsDirectory: userModelsDirectory,
            downloadsDirectory: downloadsDirectory,
            downloader: downloader,
            fileOperations: fileOperations,
            archiveHandler: archiveHandler,
            maxRetries: 1
        )
    }

    private func makeArtifact(path: String, expectedData: Data) -> ModelArtifactFile {
        ModelArtifactFile(
            relativePath: path,
            url: URL(string: "https://example.invalid/pinned-revision/\(path)")!,
            expectedSize: Int64(expectedData.count),
            sha256: SHA256.hash(data: expectedData)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    private func makeSpec(
        id: String,
        artifacts: [ModelArtifactFile]
    ) -> ModelArtifactSpec {
        ModelArtifactSpec(id: id, revision: "pinned-revision", files: artifacts)
    }

    private func captureError(
        _ operation: () async throws -> Void
    ) async -> Error? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }

    private func assertArtifactError(
        _ error: Error?,
        expected: InstallExpectedArtifactError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let artifactError = error as? ModelArtifactError else {
            XCTFail("预期 ModelArtifactError，实际为 \(String(describing: error))", file: file, line: line)
            return
        }
        let actual: InstallExpectedArtifactError?
        switch artifactError {
        case .invalidHTTPStatus:
            actual = .invalidHTTPStatus
        case .sizeMismatch:
            actual = .sizeMismatch
        case .hashMismatch:
            actual = .hashMismatch
        case .fileNameMismatch:
            actual = .fileNameMismatch
        case .unsafeArchiveEntry:
            actual = .unsafeArchiveEntry
        case .installationFailed:
            actual = .installationFailed
        default:
            actual = nil
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertNoStagingDirectories(
        for key: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let modelDownloads = downloadsDirectory.appendingPathComponent(key, isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelDownloads.path) else { return }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: modelDownloads.path).isEmpty,
            "下载异常后不得遗留 staging 目录",
            file: file,
            line: line
        )
    }

    private func assertIdle(
        _ manager: ModelManager,
        key: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let snapshot = await manager.activitySnapshot(for: key)
        XCTAssertFalse(snapshot.hasTask, file: file, line: line)
        XCTAssertFalse(snapshot.hasSession, file: file, line: line)
        XCTAssertNil(snapshot.progress, file: file, line: line)
    }
}

private enum InstallExpectedArtifactError: Equatable {
    case invalidHTTPStatus
    case sizeMismatch
    case hashMismatch
    case fileNameMismatch
    case unsafeArchiveEntry
    case installationFailed
}

private enum ModelInstallationTestError: Error {
    case interrupted
    case forcedRenameFailure
    case forcedRemovalFailure
    case unexpectedDownload
}

private enum FakeDownloadOutcome: @unchecked Sendable {
    case success(Data)
    case failure(Error)
    case failureAfterWriting(Data, Error)
}

private actor FakeModelArtifactDownloader: ModelArtifactDownloading {
    private let outcomes: [URL: FakeDownloadOutcome]

    init(outcomes: [URL: FakeDownloadOutcome]) {
        self.outcomes = outcomes
    }

    func download(
        _ artifact: ModelArtifactFile,
        to destination: URL,
        session: URLSession,
        resumeData: Data?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelArtifactDownloadResult {
        _ = session
        _ = resumeData
        guard let outcome = outcomes[artifact.url] else {
            throw ModelInstallationTestError.unexpectedDownload
        }

        switch outcome {
        case .success(let data):
            try write(data, to: destination)
            onProgress(1)
            return ModelArtifactDownloadResult(
                statusCode: 200,
                expectedContentLength: Int64(data.count),
                suggestedFilename: URL(fileURLWithPath: artifact.relativePath).lastPathComponent,
                responseURL: artifact.url
            )
        case .failure(let error):
            onProgress(0.25)
            throw error
        case .failureAfterWriting(let data, let error):
            try write(data, to: destination)
            onProgress(0.5)
            throw error
        }
    }

    private func write(_ data: Data, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination)
    }
}

private actor CancellationObservingDownloader: ModelArtifactDownloading {
    private let payload: Data
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var observedCancellation = false

    init(payload: Data) {
        self.payload = payload
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func didObserveCancellation() -> Bool {
        observedCancellation
    }

    func download(
        _ artifact: ModelArtifactFile,
        to destination: URL,
        session: URLSession,
        resumeData: Data?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelArtifactDownloadResult {
        _ = session
        _ = resumeData
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        onProgress(0.25)

        do {
            try await Task.sleep(nanoseconds: 300_000_000)
        } catch {
            observedCancellation = true
            throw CancellationError()
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: destination)
        return ModelArtifactDownloadResult(
            statusCode: 200,
            expectedContentLength: Int64(payload.count),
            suggestedFilename: artifact.url.lastPathComponent,
            responseURL: artifact.url
        )
    }
}

private actor LateProgressDownloader: ModelArtifactDownloading {
    private var progressHandler: (@Sendable (Double) -> Void)?

    func download(
        _ artifact: ModelArtifactFile,
        to destination: URL,
        session: URLSession,
        resumeData: Data?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelArtifactDownloadResult {
        _ = artifact
        _ = destination
        _ = session
        _ = resumeData
        progressHandler = onProgress
        throw ModelInstallationTestError.interrupted
    }

    func emitLateProgress(_ value: Double) {
        progressHandler?(value)
    }
}

private actor RevisionRecordingDownloader: ModelArtifactDownloading {
    private let staleResumeData: Data
    private let successPayload: Data
    private var invocationCount = 0
    private var storedResumeData: [Data?] = []

    init(staleResumeData: Data, successPayload: Data) {
        self.staleResumeData = staleResumeData
        self.successPayload = successPayload
    }

    func receivedResumeData() -> [Data?] {
        storedResumeData
    }

    func download(
        _ artifact: ModelArtifactFile,
        to destination: URL,
        session: URLSession,
        resumeData: Data?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelArtifactDownloadResult {
        _ = session
        storedResumeData.append(resumeData)
        invocationCount += 1

        if invocationCount == 1 {
            throw NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNetworkConnectionLost,
                userInfo: [NSURLSessionDownloadTaskResumeData: staleResumeData]
            )
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try successPayload.write(to: destination)
        onProgress(1)
        return ModelArtifactDownloadResult(
            statusCode: 200,
            expectedContentLength: Int64(successPayload.count),
            suggestedFilename: artifact.url.lastPathComponent,
            responseURL: artifact.url
        )
    }
}

private final class TestModelFileOperations: ModelFileOperating, @unchecked Sendable {
    private let fileManager = FileManager.default

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try fileManager.moveItem(at: source, to: destination)
    }
}

private final class RenameFailingFileOperations: ModelFileOperating, @unchecked Sendable {
    private let fileManager = FileManager.default
    private let destinationToFailOnce: URL
    private let lock = NSLock()
    private var didFail = false

    init(destinationToFailOnce: URL) {
        self.destinationToFailOnce = destinationToFailOnce.standardizedFileURL
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        lock.lock()
        let shouldFail = !didFail && destination.standardizedFileURL == destinationToFailOnce
        if shouldFail {
            didFail = true
        }
        lock.unlock()

        if shouldFail {
            throw ModelInstallationTestError.forcedRenameFailure
        }
        try fileManager.moveItem(at: source, to: destination)
    }
}

private final class PostInstallCorruptingFileOperations: ModelFileOperating, @unchecked Sendable {
    private let fileManager = FileManager.default
    private let destination: URL
    private let installedFile: String
    private let lock = NSLock()
    private var didCorruptIncoming = false
    private var didFailDestinationRemoval = false

    init(destination: URL, installedFile: String) {
        self.destination = destination.standardizedFileURL
        self.installedFile = installedFile
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func removeItem(at url: URL) throws {
        lock.lock()
        let shouldFail = !didFailDestinationRemoval
            && url.standardizedFileURL == destination
        if shouldFail {
            didFailDestinationRemoval = true
        }
        lock.unlock()
        if shouldFail {
            throw ModelInstallationTestError.forcedRemovalFailure
        }
        try fileManager.removeItem(at: url)
    }

    func moveItem(at source: URL, to target: URL) throws {
        try fileManager.moveItem(at: source, to: target)

        lock.lock()
        let shouldCorrupt = !didCorruptIncoming
            && target.standardizedFileURL == destination
        if shouldCorrupt {
            didCorruptIncoming = true
        }
        lock.unlock()

        if shouldCorrupt {
            try Data("corrupt".utf8).write(
                to: target.appendingPathComponent(installedFile)
            )
        }
    }
}

private final class BackupRemovalAfterDeleteFailingFileOperations:
    ModelFileOperating,
    @unchecked Sendable
{
    private let fileManager = FileManager.default
    private let backupPrefix: String
    private let lock = NSLock()
    private var didFail = false

    init(destination: URL) {
        backupPrefix = ".\(destination.lastPathComponent).backup-"
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func removeItem(at url: URL) throws {
        lock.lock()
        let shouldFail = !didFail && url.lastPathComponent.hasPrefix(backupPrefix)
        if shouldFail {
            didFail = true
        }
        lock.unlock()

        try fileManager.removeItem(at: url)
        if shouldFail {
            throw ModelInstallationTestError.forcedRemovalFailure
        }
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try fileManager.moveItem(at: source, to: destination)
    }
}

private final class ArchiveHandlerSpy: ModelArchiveHandling, @unchecked Sendable {
    private let returnedEntries: [ModelArchiveEntry]
    private let lock = NSLock()
    private var storedEntriesInvocationCount = 0
    private var storedExtractInvocationCount = 0

    init(entries: [ModelArchiveEntry]) {
        returnedEntries = entries
    }

    var entriesInvocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedEntriesInvocationCount
    }

    var extractInvocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedExtractInvocationCount
    }

    func entries(in archive: URL) throws -> [ModelArchiveEntry] {
        _ = archive
        lock.lock()
        storedEntriesInvocationCount += 1
        lock.unlock()
        return returnedEntries
    }

    func extract(_ archive: URL, to destination: URL) throws {
        _ = archive
        _ = destination
        lock.lock()
        storedExtractInvocationCount += 1
        lock.unlock()
    }
}

private final class ModelProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func record(_ value: Double) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }
}
