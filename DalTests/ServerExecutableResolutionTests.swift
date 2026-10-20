import Darwin
import Foundation
import XCTest
@testable import Dal

final class ServerExecutableResolutionTests: XCTestCase {
    private var temporaryDirectory: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("dal-server-resolver-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory,
           fileManager.fileExists(atPath: temporaryDirectory.path) {
            try fileManager.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testReleaseRejectsExplicitDevelopmentServer() throws {
        let developmentRoot = temporaryDirectory.appendingPathComponent("dev", isDirectory: true)
        _ = try makeDevelopmentServer(root: developmentRoot, name: "sensevoice-server")
        let resolver = makeResolver(
            bundleDirectory: temporaryDirectory.appendingPathComponent("bundle", isDirectory: true),
            environment: ["DAL_DEV_SERVER_ROOT": developmentRoot.path],
            buildMode: .release
        )

        XCTAssertThrowsError(try resolver.resolve(name: "sensevoice-server")) { error in
            XCTAssertEqual(error as? ServerExecutableResolutionError, .serverNotFound)
        }
    }

    func testDebugRequiresExplicitDevelopmentRoot() throws {
        let nearbyRoot = temporaryDirectory.appendingPathComponent("nearby", isDirectory: true)
        _ = try makeDevelopmentServer(root: nearbyRoot, name: "sensevoice-server")
        let resolver = makeResolver(
            bundleDirectory: temporaryDirectory.appendingPathComponent("bundle", isDirectory: true),
            environment: [:],
            buildMode: .debug
        )

        XCTAssertThrowsError(try resolver.resolve(name: "sensevoice-server")) { error in
            XCTAssertEqual(error as? ServerExecutableResolutionError, .serverNotFound)
        }
    }

    func testDebugRejectsRelativeDevelopmentRoot() throws {
        let resolver = makeResolver(
            bundleDirectory: temporaryDirectory.appendingPathComponent("bundle", isDirectory: true),
            environment: ["DAL_DEV_SERVER_ROOT": "relative/repository"],
            buildMode: .debug
        )

        XCTAssertThrowsError(try resolver.resolve(name: "sensevoice-server")) { error in
            XCTAssertEqual(error as? ServerExecutableResolutionError, .serverNotFound)
        }
    }

    func testDebugAcceptsOnlyValidExplicitDevelopmentServer() throws {
        let developmentRoot = temporaryDirectory.appendingPathComponent("dev", isDirectory: true)
        let server = try makeDevelopmentServer(root: developmentRoot, name: "sensevoice-server")
        let resolver = makeResolver(
            bundleDirectory: temporaryDirectory.appendingPathComponent("bundle", isDirectory: true),
            environment: ["DAL_DEV_SERVER_ROOT": developmentRoot.path],
            buildMode: .debug
        )

        let resolved = try resolver.resolve(name: "sensevoice-server")

        XCTAssertEqual(resolved.source, .development)
        XCTAssertEqual(resolved.serverScriptURL, server.appendingPathComponent("server.py"))
        XCTAssertEqual(resolved.executableURL, server.appendingPathComponent(".venv/bin/python"))
    }

    func testBundledExecutableAlwaysWinsOverDevelopmentRoot() throws {
        let bundleDirectory = temporaryDirectory.appendingPathComponent("bundle", isDirectory: true)
        try fileManager.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        let bundled = bundleDirectory.appendingPathComponent("sensevoice-server")
        try makeExecutable(at: bundled)

        let developmentRoot = temporaryDirectory.appendingPathComponent("dev", isDirectory: true)
        _ = try makeDevelopmentServer(root: developmentRoot, name: "sensevoice-server")
        let resolver = makeResolver(
            bundleDirectory: bundleDirectory,
            environment: ["DAL_DEV_SERVER_ROOT": developmentRoot.path],
            buildMode: .debug
        )

        let resolved = try resolver.resolve(name: "sensevoice-server")

        XCTAssertEqual(resolved.source, .bundle)
        XCTAssertEqual(resolved.executableURL, bundled)
        XCTAssertNil(resolved.serverScriptURL)
    }

    func testBundledExecutableSymlinkEscapeFailsClosedWithoutDevelopmentFallback() throws {
        let bundleDirectory = temporaryDirectory.appendingPathComponent("bundle", isDirectory: true)
        try fileManager.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        let outsideBinary = temporaryDirectory.appendingPathComponent("outside-binary")
        try makeExecutable(at: outsideBinary)
        try fileManager.createSymbolicLink(
            at: bundleDirectory.appendingPathComponent("sensevoice-server"),
            withDestinationURL: outsideBinary
        )

        let developmentRoot = temporaryDirectory.appendingPathComponent("dev", isDirectory: true)
        _ = try makeDevelopmentServer(root: developmentRoot, name: "sensevoice-server")
        let resolver = makeResolver(
            bundleDirectory: bundleDirectory,
            environment: ["DAL_DEV_SERVER_ROOT": developmentRoot.path],
            buildMode: .debug
        )

        XCTAssertThrowsError(try resolver.resolve(name: "sensevoice-server")) { error in
            XCTAssertEqual(error as? ServerExecutableResolutionError, .pathEscapesBundle)
        }
    }

    func testNonExecutableBundledCandidateFailsClosedWithoutDevelopmentFallback() throws {
        let bundleDirectory = temporaryDirectory.appendingPathComponent("bundle", isDirectory: true)
        try fileManager.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        try Data().write(to: bundleDirectory.appendingPathComponent("sensevoice-server"))
        let developmentRoot = temporaryDirectory.appendingPathComponent("dev", isDirectory: true)
        _ = try makeDevelopmentServer(root: developmentRoot, name: "sensevoice-server")
        let resolver = makeResolver(
            bundleDirectory: bundleDirectory,
            environment: ["DAL_DEV_SERVER_ROOT": developmentRoot.path],
            buildMode: .debug
        )

        XCTAssertThrowsError(try resolver.resolve(name: "sensevoice-server")) { error in
            XCTAssertEqual(error as? ServerExecutableResolutionError, .bundleNotExecutable)
        }
    }

    func testDevelopmentServerSymlinkEscapeIsRejected() throws {
        let developmentRoot = temporaryDirectory.appendingPathComponent("dev", isDirectory: true)
        try fileManager.createDirectory(at: developmentRoot, withIntermediateDirectories: true)
        let outsideRoot = temporaryDirectory.appendingPathComponent("outside", isDirectory: true)
        let outsideServer = try makeDevelopmentServer(root: outsideRoot, name: "sensevoice-server")
        try fileManager.createSymbolicLink(
            at: developmentRoot.appendingPathComponent("sensevoice-server"),
            withDestinationURL: outsideServer
        )
        let resolver = makeResolver(
            bundleDirectory: temporaryDirectory.appendingPathComponent("bundle", isDirectory: true),
            environment: ["DAL_DEV_SERVER_ROOT": developmentRoot.path],
            buildMode: .debug
        )

        XCTAssertThrowsError(try resolver.resolve(name: "sensevoice-server")) { error in
            XCTAssertEqual(error as? ServerExecutableResolutionError, .pathEscapesDevelopmentRoot)
        }
    }

    func testDevelopmentServerScriptSymlinkEscapeIsRejected() throws {
        let developmentRoot = temporaryDirectory.appendingPathComponent("dev", isDirectory: true)
        let server = try makeDevelopmentServer(root: developmentRoot, name: "sensevoice-server")
        let script = server.appendingPathComponent("server.py")
        try fileManager.removeItem(at: script)
        let outsideScript = temporaryDirectory.appendingPathComponent("outside-server.py")
        try Data("print('outside')\n".utf8).write(to: outsideScript)
        try fileManager.createSymbolicLink(at: script, withDestinationURL: outsideScript)
        let resolver = makeResolver(
            bundleDirectory: temporaryDirectory.appendingPathComponent("bundle", isDirectory: true),
            environment: ["DAL_DEV_SERVER_ROOT": developmentRoot.path],
            buildMode: .debug
        )

        XCTAssertThrowsError(try resolver.resolve(name: "sensevoice-server")) { error in
            XCTAssertEqual(error as? ServerExecutableResolutionError, .pathEscapesDevelopmentRoot)
        }
    }

    func testDevelopmentServerRequiresServerScript() throws {
        let developmentRoot = temporaryDirectory.appendingPathComponent("dev", isDirectory: true)
        let server = try makeDevelopmentServer(root: developmentRoot, name: "sensevoice-server")
        try fileManager.removeItem(at: server.appendingPathComponent("server.py"))
        let resolver = makeResolver(
            bundleDirectory: temporaryDirectory.appendingPathComponent("bundle", isDirectory: true),
            environment: ["DAL_DEV_SERVER_ROOT": developmentRoot.path],
            buildMode: .debug
        )

        XCTAssertThrowsError(try resolver.resolve(name: "sensevoice-server")) { error in
            XCTAssertEqual(error as? ServerExecutableResolutionError, .serverScriptMissing)
        }
    }

    func testDevelopmentPythonMustBeExecutable() throws {
        let developmentRoot = temporaryDirectory.appendingPathComponent("dev", isDirectory: true)
        let server = try makeDevelopmentServer(root: developmentRoot, name: "sensevoice-server")
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: server.appendingPathComponent(".venv/bin/python").path
        )
        let resolver = makeResolver(
            bundleDirectory: temporaryDirectory.appendingPathComponent("bundle", isDirectory: true),
            environment: ["DAL_DEV_SERVER_ROOT": developmentRoot.path],
            buildMode: .debug
        )

        XCTAssertThrowsError(try resolver.resolve(name: "sensevoice-server")) { error in
            XCTAssertEqual(error as? ServerExecutableResolutionError, .pythonNotExecutable)
        }
    }

    func testDevelopmentServerRequiresPython() throws {
        let developmentRoot = temporaryDirectory.appendingPathComponent("dev", isDirectory: true)
        let server = try makeDevelopmentServer(root: developmentRoot, name: "sensevoice-server")
        try fileManager.removeItem(at: server.appendingPathComponent(".venv/bin/python"))
        let resolver = makeResolver(
            bundleDirectory: temporaryDirectory.appendingPathComponent("bundle", isDirectory: true),
            environment: ["DAL_DEV_SERVER_ROOT": developmentRoot.path],
            buildMode: .debug
        )

        XCTAssertThrowsError(try resolver.resolve(name: "sensevoice-server")) { error in
            XCTAssertEqual(error as? ServerExecutableResolutionError, .pythonMissing)
        }
    }

    func testDevelopmentPythonTargetMustHaveTrustedOwner() throws {
        let developmentRoot = temporaryDirectory.appendingPathComponent("dev", isDirectory: true)
        let server = try makeDevelopmentServer(root: developmentRoot, name: "sensevoice-server")
        let pythonPath = server.appendingPathComponent(".venv/bin/python")
            .resolvingSymlinksInPath().standardizedFileURL.path
        let resolver = makeResolver(
            bundleDirectory: temporaryDirectory.appendingPathComponent("bundle", isDirectory: true),
            environment: ["DAL_DEV_SERVER_ROOT": developmentRoot.path],
            buildMode: .debug,
            ownerID: { url in
                url.resolvingSymlinksInPath().standardizedFileURL.path == pythonPath
                    ? UInt32(getuid()) &+ 1
                    : UInt32(getuid())
            }
        )

        XCTAssertThrowsError(try resolver.resolve(name: "sensevoice-server")) { error in
            XCTAssertEqual(error as? ServerExecutableResolutionError, .untrustedOwner)
        }
    }

    func testTrustedExecutablePythonSymlinkOutsideDevelopmentRootIsAccepted() throws {
        let developmentRoot = temporaryDirectory.appendingPathComponent("dev", isDirectory: true)
        let server = try makeDevelopmentServer(root: developmentRoot, name: "sensevoice-server")
        let python = server.appendingPathComponent(".venv/bin/python")
        try fileManager.removeItem(at: python)
        let externalPython = temporaryDirectory.appendingPathComponent("trusted-python")
        try makeExecutable(at: externalPython)
        try fileManager.createSymbolicLink(at: python, withDestinationURL: externalPython)
        let resolver = makeResolver(
            bundleDirectory: temporaryDirectory.appendingPathComponent("bundle", isDirectory: true),
            environment: ["DAL_DEV_SERVER_ROOT": developmentRoot.path],
            buildMode: .debug
        )

        let resolved = try resolver.resolve(name: "sensevoice-server")

        XCTAssertEqual(resolved.source, .development)
        XCTAssertEqual(resolved.executableURL, python)
    }

    func testModelManagerAndServerManagerShareResolutionPolicy() throws {
        let developmentRoot = temporaryDirectory.appendingPathComponent("dev", isDirectory: true)
        _ = try makeDevelopmentServer(root: developmentRoot, name: "sensevoice-server")
        let resolver = makeResolver(
            bundleDirectory: temporaryDirectory.appendingPathComponent("bundle", isDirectory: true),
            environment: ["DAL_DEV_SERVER_ROOT": developmentRoot.path],
            buildMode: .debug
        )

        XCTAssertTrue(ModelManager.isSenseVoiceBundled(using: resolver))
        XCTAssertEqual(
            try SenseVoiceServerManager.resolveServerExecutable(
                name: "sensevoice-server",
                using: resolver
            ).source,
            .development
        )
    }

    func testSenseVoiceAndQwenUseSameExplicitDevelopmentRoot() throws {
        let developmentRoot = temporaryDirectory.appendingPathComponent("dev", isDirectory: true)
        _ = try makeDevelopmentServer(root: developmentRoot, name: "sensevoice-server")
        _ = try makeDevelopmentServer(root: developmentRoot, name: "qwen3-asr-server")
        let resolver = makeResolver(
            bundleDirectory: temporaryDirectory.appendingPathComponent("bundle", isDirectory: true),
            environment: ["DAL_DEV_SERVER_ROOT": developmentRoot.path],
            buildMode: .debug
        )

        XCTAssertEqual(
            try resolver.resolve(name: "sensevoice-server").source,
            .development
        )
        XCTAssertEqual(
            try resolver.resolve(name: "qwen3-asr-server").source,
            .development
        )
    }

    func testDevelopmentDirectoryMustBelongToCurrentUser() throws {
        let developmentRoot = temporaryDirectory.appendingPathComponent("dev", isDirectory: true)
        let server = try makeDevelopmentServer(root: developmentRoot, name: "sensevoice-server")
        let realServerPath = server.resolvingSymlinksInPath().standardizedFileURL.path
        let resolver = makeResolver(
            bundleDirectory: temporaryDirectory.appendingPathComponent("bundle", isDirectory: true),
            environment: ["DAL_DEV_SERVER_ROOT": developmentRoot.path],
            buildMode: .debug,
            ownerID: { url in
                url.resolvingSymlinksInPath().standardizedFileURL.path == realServerPath
                    ? UInt32(getuid()) &+ 1
                    : UInt32(getuid())
            }
        )

        XCTAssertThrowsError(try resolver.resolve(name: "sensevoice-server")) { error in
            XCTAssertEqual(error as? ServerExecutableResolutionError, .untrustedOwner)
        }
    }

    private func makeResolver(
        bundleDirectory: URL,
        environment: [String: String],
        buildMode: ServerExecutableBuildMode,
        ownerID: @escaping (URL) -> UInt32? = { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value
        }
    ) -> ServerExecutableResolver {
        ServerExecutableResolver(
            fileManager: fileManager,
            bundleExecutableDirectory: bundleDirectory,
            environment: environment,
            buildMode: buildMode,
            currentUserID: UInt32(getuid()),
            ownerID: ownerID
        )
    }

    @discardableResult
    private func makeDevelopmentServer(root: URL, name: String) throws -> URL {
        let server = root.appendingPathComponent(name, isDirectory: true)
        let pythonDirectory = server.appendingPathComponent(".venv/bin", isDirectory: true)
        try fileManager.createDirectory(at: pythonDirectory, withIntermediateDirectories: true)
        try Data("print('server')\n".utf8).write(to: server.appendingPathComponent("server.py"))
        try makeExecutable(at: pythonDirectory.appendingPathComponent("python"))
        return server
    }

    private func makeExecutable(at url: URL) throws {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }
}
