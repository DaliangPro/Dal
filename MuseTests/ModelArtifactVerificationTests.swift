import CryptoKit
import Foundation
@testable import Muse
import XCTest

final class ModelArtifactVerificationTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-model-verification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory,
           FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testVerifierAcceptsMatchingHTTPMetadataSizeNameAndSHA256() throws {
        let data = Data("verified model payload".utf8)
        let fileURL = try write(data, named: "model.bin")
        let artifact = makeArtifact(
            relativePath: "weights/model.bin",
            data: data
        )

        XCTAssertNoThrow(
            try ModelArtifactVerifier.verify(
                fileAt: fileURL,
                artifact: artifact,
                download: matchingDownload(for: artifact)
            )
        )
    }

    func testVerifierRejectsSameSizeDifferentContentWithHashMismatch() throws {
        let expectedData = Data("expected".utf8)
        let downloadedData = Data("tampered".utf8)
        XCTAssertEqual(expectedData.count, downloadedData.count)
        let fileURL = try write(downloadedData, named: "model.bin")
        let artifact = makeArtifact(relativePath: "model.bin", data: expectedData)

        assertArtifactError(.hashMismatch) {
            try ModelArtifactVerifier.verify(
                fileAt: fileURL,
                artifact: artifact,
                download: matchingDownload(for: artifact)
            )
        }
    }

    func testVerifierRejectsUnexpectedHTTPStatus() throws {
        let data = Data("model".utf8)
        let fileURL = try write(data, named: "model.bin")
        let artifact = makeArtifact(relativePath: "model.bin", data: data)
        let download = ModelArtifactDownloadResult(
            statusCode: 404,
            expectedContentLength: Int64(data.count),
            suggestedFilename: "model.bin",
            responseURL: artifact.url
        )

        assertArtifactError(.invalidHTTPStatus) {
            try ModelArtifactVerifier.verify(
                fileAt: fileURL,
                artifact: artifact,
                download: download
            )
        }
    }

    func testVerifierRejectsContentLengthMismatch() throws {
        let data = Data("model".utf8)
        let fileURL = try write(data, named: "model.bin")
        let artifact = makeArtifact(relativePath: "model.bin", data: data)
        let download = ModelArtifactDownloadResult(
            statusCode: 200,
            expectedContentLength: Int64(data.count + 1),
            suggestedFilename: "model.bin",
            responseURL: artifact.url
        )

        assertArtifactError(.sizeMismatch) {
            try ModelArtifactVerifier.verify(
                fileAt: fileURL,
                artifact: artifact,
                download: download
            )
        }
    }

    func testVerifierRejectsActualFileSizeMismatchWhenResponseLengthIsUnknown() throws {
        let expectedData = Data("complete model".utf8)
        let incompleteData = Data("short".utf8)
        let fileURL = try write(incompleteData, named: "model.bin")
        let artifact = makeArtifact(relativePath: "model.bin", data: expectedData)
        let download = ModelArtifactDownloadResult(
            statusCode: 200,
            expectedContentLength: NSURLSessionTransferSizeUnknown,
            suggestedFilename: "model.bin",
            responseURL: artifact.url
        )

        assertArtifactError(.sizeMismatch) {
            try ModelArtifactVerifier.verify(
                fileAt: fileURL,
                artifact: artifact,
                download: download
            )
        }
    }

    func testVerifierRejectsUnexpectedResponseFilename() throws {
        let data = Data("model".utf8)
        let fileURL = try write(data, named: "model.bin")
        let artifact = makeArtifact(relativePath: "weights/model.bin", data: data)
        let download = ModelArtifactDownloadResult(
            statusCode: 200,
            expectedContentLength: Int64(data.count),
            suggestedFilename: "login.html",
            responseURL: URL(string: "https://example.invalid/login.html")!
        )

        assertArtifactError(.fileNameMismatch) {
            try ModelArtifactVerifier.verify(
                fileAt: fileURL,
                artifact: artifact,
                download: download
            )
        }
    }

    func testArchiveSecurityRejectsParentTraversalAndAbsolutePaths() {
        let traversal = ModelArchiveEntry(
            path: "../outside/model.bin",
            kind: .file,
            linkTarget: nil
        )
        let absolute = ModelArchiveEntry(
            path: "/tmp/outside/model.bin",
            kind: .file,
            linkTarget: nil
        )

        assertArtifactError(.unsafeArchiveEntry) {
            try ModelArchiveSecurity.validate(entries: [traversal])
        }
        assertArtifactError(.unsafeArchiveEntry) {
            try ModelArchiveSecurity.validate(entries: [absolute])
        }
    }

    func testArchiveSecurityRejectsEscapingSymbolicLink() {
        let entry = ModelArchiveEntry(
            path: "model/link",
            kind: .symbolicLink,
            linkTarget: "../../outside"
        )

        assertArtifactError(.unsafeArchiveEntry) {
            try ModelArchiveSecurity.validate(entries: [entry])
        }
    }

    func testArchiveSecurityRejectsEscapingHardLink() {
        let entry = ModelArchiveEntry(
            path: "model/link",
            kind: .hardLink,
            linkTarget: "../../outside"
        )

        assertArtifactError(.unsafeArchiveEntry) {
            try ModelArchiveSecurity.validate(entries: [entry])
        }
    }

    func testArchiveSecurityAcceptsNestedFilesAndContainedLinks() throws {
        let entries = [
            ModelArchiveEntry(path: "model", kind: .directory, linkTarget: nil),
            ModelArchiveEntry(path: "model/model.bin", kind: .file, linkTarget: nil),
            ModelArchiveEntry(
                path: "model/current.bin",
                kind: .symbolicLink,
                linkTarget: "model.bin"
            ),
            ModelArchiveEntry(
                path: "model/copy.bin",
                kind: .hardLink,
                linkTarget: "model/model.bin"
            ),
        ]

        XCTAssertNoThrow(try ModelArchiveSecurity.validate(entries: entries))
    }

    func testArchiveSecurityRejectsLinksEscapingSelectedInstallRoot() {
        let entries = [
            ModelArchiveEntry(path: "model-root", kind: .directory, linkTarget: nil),
            ModelArchiveEntry(path: "payload.bin", kind: .file, linkTarget: nil),
            ModelArchiveEntry(
                path: "model-root/symbolic.bin",
                kind: .symbolicLink,
                linkTarget: "../payload.bin"
            ),
            ModelArchiveEntry(
                path: "model-root/hard.bin",
                kind: .hardLink,
                linkTarget: "payload.bin"
            ),
        ]

        assertArtifactError(.unsafeArchiveEntry) {
            try ModelArchiveSecurity.validate(
                entries: entries,
                withinRoot: "model-root"
            )
        }
    }

    func testTarHandlerListsAndExtractsSafeArchiveInStaging() throws {
        let source = temporaryDirectory.appendingPathComponent("safe-source", isDirectory: true)
        let modelRoot = source.appendingPathComponent("model-root", isDirectory: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        let payload = Data("safe archive model".utf8)
        try payload.write(to: modelRoot.appendingPathComponent("model.bin"))
        let archive = temporaryDirectory.appendingPathComponent("safe.tar.bz2")
        try runTar(["-cjf", archive.path, "-C", source.path, "model-root"])

        let handler = TarModelArchiveHandler()
        let entries = try handler.entries(in: archive)
        XCTAssertNoThrow(
            try ModelArchiveSecurity.validate(entries: entries, withinRoot: "model-root")
        )

        let extraction = temporaryDirectory.appendingPathComponent("safe-extraction", isDirectory: true)
        try handler.extract(archive, to: extraction)
        XCTAssertEqual(
            try Data(contentsOf: extraction.appendingPathComponent("model-root/model.bin")),
            payload
        )
    }

    func testTarHandlerRejectsRealParentTraversalArchiveBeforeExtraction() throws {
        let source = temporaryDirectory.appendingPathComponent("unsafe-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("unsafe".utf8).write(to: source.appendingPathComponent("safe.bin"))
        let archive = temporaryDirectory.appendingPathComponent("unsafe.tar.bz2")
        try runTar([
            "-cjf", archive.path,
            "-C", source.path,
            "-s", "|^safe.bin$|../escaped.bin|",
            "safe.bin",
        ])
        let extraction = temporaryDirectory.appendingPathComponent("unsafe-extraction", isDirectory: true)
        let handler = TarModelArchiveHandler()

        let entries = try handler.entries(in: archive)
        assertArtifactError(.unsafeArchiveEntry) {
            try ModelArchiveSecurity.validate(entries: entries)
        }
        assertArtifactError(.unsafeArchiveEntry) {
            try handler.extract(archive, to: extraction)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.path))
    }

    func testTarHandlerRecognizesContainedSymbolicAndHardLinks() throws {
        let source = temporaryDirectory.appendingPathComponent("link-source", isDirectory: true)
        let modelRoot = source.appendingPathComponent("model-root", isDirectory: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        let original = modelRoot.appendingPathComponent("original.bin")
        try Data("linked model".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(
            atPath: modelRoot.appendingPathComponent("symbolic.bin").path,
            withDestinationPath: "original.bin"
        )
        try FileManager.default.linkItem(
            at: original,
            to: modelRoot.appendingPathComponent("hard.bin")
        )
        let archive = temporaryDirectory.appendingPathComponent("links.tar.bz2")
        try runTar(["-cjf", archive.path, "-C", source.path, "model-root"])

        let entries = try TarModelArchiveHandler().entries(in: archive)

        XCTAssertTrue(entries.contains { $0.kind == .symbolicLink })
        XCTAssertTrue(entries.contains { $0.kind == .hardLink })
        XCTAssertNoThrow(
            try ModelArchiveSecurity.validate(entries: entries, withinRoot: "model-root")
        )
    }

    func testDownloadSessionConfigurationIsEphemeralWithoutCookiesOrCache() {
        let configuration = ModelManager.makeDownloadSessionConfiguration()

        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testManifestUsesPinnedRevisionsAndCompleteIntegrityMetadata() {
        let specs = ModelArtifactManifest.all

        XCTAssertFalse(specs.isEmpty)
        XCTAssertEqual(Set(specs.map(\.id)).count, specs.count, "制品 id 必须唯一")

        for spec in specs {
            let revision = spec.revision.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(revision.isEmpty, "\(spec.id) 缺少固定 revision")
            XCTAssertFalse(
                ["main", "master", "latest"].contains(revision.lowercased()),
                "\(spec.id) 不得使用浮动 revision"
            )
            XCTAssertFalse(spec.files.isEmpty, "\(spec.id) 清单不得为空")

            for artifact in spec.files {
                let urlString = artifact.url.absoluteString
                XCTAssertFalse(
                    urlString.localizedCaseInsensitiveContains("/resolve/main/"),
                    "\(spec.id)/\(artifact.relativePath) 仍使用 resolve/main"
                )
                if urlString.contains("/resolve/") {
                    XCTAssertTrue(
                        urlString.contains("/resolve/\(revision)/"),
                        "\(spec.id)/\(artifact.relativePath) URL 未固定到清单 revision"
                    )
                }
                XCTAssertGreaterThan(
                    artifact.expectedSize,
                    0,
                    "\(spec.id)/\(artifact.relativePath) 缺少正数文件大小"
                )
                XCTAssertNotNil(
                    artifact.sha256.range(
                        of: "^[0-9a-fA-F]{64}$",
                        options: .regularExpression
                    ),
                    "\(spec.id)/\(artifact.relativePath) SHA256 必须是 64 位十六进制"
                )
            }
        }
    }

    func testInstalledDirectoryVerifierRequiresPinnedFilesAndHashes() async throws {
        let modelDirectory = temporaryDirectory.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let payload = Data("verified local model".utf8)
        let artifact = makeArtifact(relativePath: "model.pt", data: payload)
        try payload.write(to: modelDirectory.appendingPathComponent("model.pt"))
        let spec = ModelArtifactSpec(id: "fixture", revision: "revision-1", files: [artifact])

        try await ModelArtifactVerifier.verifyInstalledDirectory(
            at: modelDirectory,
            spec: spec
        )

        try Data("unexpected file".utf8).write(
            to: modelDirectory.appendingPathComponent("unexpected.txt")
        )
        do {
            try await ModelArtifactVerifier.verifyInstalledDirectory(
                at: modelDirectory,
                spec: spec
            )
            XCTFail("清单外文件不应通过模型目录校验")
        } catch let error as ModelArtifactError {
            XCTAssertEqual(error.caseName, "installationFailed")
        }
    }

    private func makeArtifact(relativePath: String, data: Data) -> ModelArtifactFile {
        ModelArtifactFile(
            relativePath: relativePath,
            url: URL(string: "https://example.invalid/revision-1/\(relativePath)")!,
            expectedSize: Int64(data.count),
            sha256: sha256(data)
        )
    }

    private func matchingDownload(for artifact: ModelArtifactFile) -> ModelArtifactDownloadResult {
        ModelArtifactDownloadResult(
            statusCode: 200,
            expectedContentLength: artifact.expectedSize,
            suggestedFilename: URL(fileURLWithPath: artifact.relativePath).lastPathComponent,
            responseURL: artifact.url
        )
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func runTar(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.environment = [
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ModelArtifactVerificationTests.tar",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "tar failed",
                ]
            )
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func assertArtifactError(
        _ expected: ExpectedArtifactError,
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let artifactError = error as? ModelArtifactError else {
                XCTFail("预期 ModelArtifactError，实际为 \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(
                artifactError.caseName,
                expected.rawValue,
                file: file,
                line: line
            )
        }
    }
}

private enum ExpectedArtifactError: String {
    case invalidHTTPStatus
    case sizeMismatch
    case hashMismatch
    case fileNameMismatch
    case unsafeArchiveEntry
    case installationFailed
}

private extension ModelArtifactError {
    var caseName: String {
        switch self {
        case .invalidHTTPStatus:
            return "invalidHTTPStatus"
        case .sizeMismatch:
            return "sizeMismatch"
        case .hashMismatch:
            return "hashMismatch"
        case .fileNameMismatch:
            return "fileNameMismatch"
        case .unsafeArchiveEntry:
            return "unsafeArchiveEntry"
        case .installationFailed:
            return "installationFailed"
        default:
            return "unexpected"
        }
    }
}
