import Foundation
import XCTest
@testable import Dal

final class ReleaseVerifyScriptTests: XCTestCase {
    private let fileManager = FileManager.default

    func testReleaseVerifyScriptPassesBashSyntaxCheck() throws {
        for url in [scriptURL, notarizationScriptURL] {
            let result = try run("/bin/bash", arguments: ["-n", url.path])
            XCTAssertEqual(result.status, 0, "\(url.lastPathComponent): \(result.output)")
        }
    }

    func testReleaseCandidateDefaultsAndNotesTargetVersionTwoTwoZero() throws {
        let expectedDefaults = [
            ("scripts/package-app.sh", #"APP_VERSION="${APP_VERSION:-2.2.0}""#),
            ("scripts/build-dmg.sh", #"APP_VERSION="${APP_VERSION:-2.2.0}""#),
            ("scripts/test_app_bundle.sh", #"EXPECTED_VERSION="${APP_VERSION:-2.2.0}""#),
        ]

        for (path, expectedDefault) in expectedDefaults {
            let content = try String(
                contentsOf: repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            XCTAssertTrue(content.contains(expectedDefault), "\(path) 应默认构建 2.2.0")
        }

        let notesURL = repositoryRoot
            .appendingPathComponent("docs/2026-10-20-Dal-v2.2.0-发布说明.md")
        let notes = try String(contentsOf: notesURL, encoding: .utf8)
        XCTAssertTrue(notes.contains("# Dal 2.2.0"))
        XCTAssertTrue(notes.contains("自动更新仍保持关闭"))
    }

    func testBuildModeUsesBothActualDMGsAndGeneratesValidatedManifest() throws {
        let fixture = try makeFixture()
        defer { trash(fixture.rootURL) }

        let result = try runScript(fixture)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.cloudDMGURL.path), result.output)
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.localDMGURL.path), result.output)
        XCTAssertTrue(fileManager.fileExists(atPath: fixture.manifestURL.path), result.output)

        let object = try manifestObject(at: fixture.manifestURL)
        XCTAssertEqual(object["version"] as? String, fixture.version)
        let decoded = try JSONDecoder().decode(
            UpdateInfo.self,
            from: Data(contentsOf: fixture.manifestURL)
        )
        XCTAssertNoThrow(try decoded.resolvedArtifact(isLocalInstallation: false))
        XCTAssertNoThrow(try decoded.resolvedArtifact(isLocalInstallation: true))
        let artifacts = try XCTUnwrap(object["artifacts"] as? [String: Any])
        let cloud = try XCTUnwrap(artifacts["cloud"] as? [String: String])
        let local = try XCTUnwrap(artifacts["local"] as? [String: String])
        XCTAssertEqual(cloud["sha256"], try sha256(of: fixture.cloudDMGURL))
        XCTAssertEqual(local["sha256"], try sha256(of: fixture.localDMGURL))
        XCTAssertEqual(cloud["url"], "https://updates.example/releases/v\(fixture.version)/Dal-v\(fixture.version)-cloud.dmg")
        XCTAssertEqual(local["url"], "https://updates.example/releases/v\(fixture.version)/Dal-v\(fixture.version)-local.dmg")

        let log = try String(contentsOf: fixture.toolLogURL, encoding: .utf8)
        XCTAssertTrue(log.contains("build:cloud"), log)
        XCTAssertTrue(log.contains("build:local"), log)
        XCTAssertTrue(log.contains("bundle:0:"), log)
        XCTAssertTrue(log.contains("bundle:1:"), log)
        XCTAssertTrue(log.contains("hdiutil:attach:"), log)
        XCTAssertTrue(log.contains("hdiutil:detach:"), log)
        XCTAssertTrue(log.contains("notary:submit:"), log)
        let notaryRange = try XCTUnwrap(log.range(of: "notary:submit:"))
        let hashRange = try XCTUnwrap(log.range(of: "shasum:"))
        XCTAssertLessThan(notaryRange.lowerBound, hashRange.lowerBound)
    }

    func testMissingLocalDMGPreventsManifestPublication() throws {
        let fixture = try makeFixture()
        defer { trash(fixture.rootURL) }
        var environment = fixture.environment
        environment["DAL_TEST_SKIP_ARTIFACT_KIND"] = "local"

        let result = try run("/bin/bash", arguments: [fixture.scriptURL.path], environment: environment)

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertFalse(fileManager.fileExists(atPath: fixture.manifestURL.path), result.output)
    }

    func testStrictVerificationFailurePreventsManifestPublication() throws {
        let fixture = try makeFixture()
        defer { trash(fixture.rootURL) }
        var environment = fixture.environment
        environment["DAL_TEST_FAIL_VERIFY_KIND"] = "local"

        let result = try run("/bin/bash", arguments: [fixture.scriptURL.path], environment: environment)

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertFalse(fileManager.fileExists(atPath: fixture.manifestURL.path), result.output)
    }

    func testNotarizationFailurePreventsHashAndManifestPublication() throws {
        let fixture = try makeFixture()
        defer { trash(fixture.rootURL) }
        var environment = fixture.environment
        environment["DAL_TEST_FAIL_NOTARIZATION"] = "1"

        let result = try run(
            "/bin/bash",
            arguments: [fixture.scriptURL.path],
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertFalse(fileManager.fileExists(atPath: fixture.manifestURL.path), result.output)
        let log = try String(contentsOf: fixture.toolLogURL, encoding: .utf8)
        XCTAssertTrue(log.contains("notary:submit:"), log)
        XCTAssertFalse(log.contains("shasum:"), log)
    }

    func testVerifyModeRejectsArtifactTamperingAfterTransfer() throws {
        let fixture = try makeFixture()
        defer { trash(fixture.rootURL) }
        let build = try runScript(fixture)
        XCTAssertEqual(build.status, 0, build.output)
        let originalManifest = try Data(contentsOf: fixture.manifestURL)

        let handle = try FileHandle(forWritingTo: fixture.cloudDMGURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tampered".utf8))
        try handle.close()
        var environment = fixture.environment
        environment["RELEASE_VERIFY_MODE"] = "verify"

        let verification = try run(
            "/bin/bash",
            arguments: [fixture.scriptURL.path],
            environment: environment
        )

        XCTAssertNotEqual(verification.status, 0, verification.output)
        XCTAssertEqual(try Data(contentsOf: fixture.manifestURL), originalManifest)
    }

    func testUnsafeReleaseInputsFailBeforeAnyBuild() throws {
        let fixture = try makeFixture()
        defer { trash(fixture.rootURL) }
        let invalidOverrides = [
            ["APP_VERSION": "../2.0.0"],
            [
                "APP_VERSION": "2.3",
                "RELEASE_BASE_URL": "https://updates.example/releases/v2.3",
            ],
            [
                "APP_VERSION": "2.3.4.5",
                "RELEASE_BASE_URL": "https://updates.example/releases/v2.3.4.5",
            ],
            [
                "APP_VERSION": "9999999999999999999.0.0",
                "RELEASE_BASE_URL": "https://updates.example/releases/v9999999999999999999.0.0",
            ],
            ["RELEASE_BASE_URL": "http://updates.example/releases/v2.0.0"],
            ["RELEASE_BASE_URL": "https://updates.example/releases/v9.9.9"],
            ["CODESIGN_IDENTITY": "-"],
            ["EXPECTED_TEAM_ID": "bad/team"],
            ["APP_VERSION": "1.7.4"],
        ]

        for overrides in invalidOverrides {
            try Data().write(to: fixture.toolLogURL, options: .atomic)
            let environment = fixture.environment.merging(overrides) { _, new in new }
            let result = try run(
                "/bin/bash",
                arguments: [fixture.scriptURL.path],
                environment: environment
            )
            XCTAssertNotEqual(result.status, 0, "\(overrides): \(result.output)")
            let log = try String(contentsOf: fixture.toolLogURL, encoding: .utf8)
            XCTAssertFalse(log.contains("build:"), "\(overrides): \(log)")
        }
    }

    func testReleaseEnvironmentPolicyAcceptsOnlyProtectedMainReviewGates() throws {
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("dal-release-environments-\(UUID().uuidString)", isDirectory: true)
        defer { trash(rootURL) }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try writeValidEnvironmentFixtures(to: rootURL)
        let environment = releaseEnvironmentTestEnvironment(fixtureURL: rootURL)

        let valid = try run(
            "/bin/bash",
            arguments: [environmentPolicyScriptURL.path],
            environment: environment
        )
        XCTAssertEqual(valid.status, 0, valid.output)

        var bypassable = validEnvironment(named: "release")
        bypassable["can_admins_bypass"] = true
        try writeJSON(bypassable, to: rootURL.appendingPathComponent("release.environment.json"))
        let bypassResult = try run(
            "/bin/bash",
            arguments: [environmentPolicyScriptURL.path],
            environment: environment
        )
        XCTAssertNotEqual(bypassResult.status, 0, bypassResult.output)

        try writeValidEnvironmentFixtures(to: rootURL)
        let wrongBranchPolicy: [String: Any] = [
            "total_count": 1,
            "branch_policies": [["name": "release/*", "type": "branch"]],
        ]
        try writeJSON(
            wrongBranchPolicy,
            to: rootURL.appendingPathComponent("release-signing.branches.json")
        )
        let branchResult = try run(
            "/bin/bash",
            arguments: [environmentPolicyScriptURL.path],
            environment: environment
        )
        XCTAssertNotEqual(branchResult.status, 0, branchResult.output)

        try writeValidEnvironmentFixtures(to: rootURL)
        var wrongRepository = environment
        wrongRepository["GITHUB_REPOSITORY"] = "attacker/fork"
        let repositoryResult = try run(
            "/bin/bash",
            arguments: [environmentPolicyScriptURL.path],
            environment: wrongRepository
        )
        XCTAssertNotEqual(repositoryResult.status, 0, repositoryResult.output)
    }

    func testReleaseArtifactPolicyMapsBareUploadDigestToRESTDigest() throws {
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("dal-release-artifact-\(UUID().uuidString)", isDirectory: true)
        defer { trash(rootURL) }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let digest = String(repeating: "a", count: 64)
        let metadata: [String: Any] = [
            "id": 123,
            "expired": false,
            "digest": "sha256:\(digest)",
            "workflow_run": ["id": 456],
        ]
        let metadataURL = rootURL.appendingPathComponent("artifact.json")
        try writeJSON(metadata, to: metadataURL)
        let environment = [
            "EXPECTED_ARTIFACT_DIGEST": digest,
            "EXPECTED_ARTIFACT_ID": "123",
            "GH_TOKEN": "fixture-token",
            "GITHUB_REPOSITORY": "DaliangPro/Dal",
            "GITHUB_RUN_ID": "456",
            "DAL_RELEASE_ARTIFACT_FIXTURE": metadataURL.path,
            "DAL_RELEASE_ARTIFACT_TEST_MODE": "1",
        ]

        let valid = try run(
            "/bin/bash",
            arguments: [artifactPolicyScriptURL.path],
            environment: environment
        )
        XCTAssertEqual(valid.status, 0, valid.output)

        var prefixedDigest = environment
        prefixedDigest["EXPECTED_ARTIFACT_DIGEST"] = "sha256:\(digest)"
        let prefixed = try run(
            "/bin/bash",
            arguments: [artifactPolicyScriptURL.path],
            environment: prefixedDigest
        )
        XCTAssertNotEqual(prefixed.status, 0, prefixed.output)

        var wrongRun = environment
        wrongRun["GITHUB_RUN_ID"] = "999"
        let wrongRunResult = try run(
            "/bin/bash",
            arguments: [artifactPolicyScriptURL.path],
            environment: wrongRun
        )
        XCTAssertNotEqual(wrongRunResult.status, 0, wrongRunResult.output)
    }

    func testReleaseVersionPolicyMatchesManifestToHighestPublishedRelease() throws {
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("dal-release-version-\(UUID().uuidString)", isDirectory: true)
        defer { trash(rootURL) }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let updatesURL = rootURL.appendingPathComponent("updates.json")
        let releasesURL = rootURL.appendingPathComponent("releases.json")
        try writeJSON(["latest": "1.7.4", "releases": []], to: updatesURL)
        let releases: [[String: Any]] = [
            ["tag_name": "v1.7.4", "draft": false, "prerelease": false],
            ["tag_name": "v1.7.3", "draft": false, "prerelease": false],
            ["tag_name": "v9.0.0-beta.1", "draft": false, "prerelease": true],
            ["tag_name": "nightly", "draft": false, "prerelease": true],
        ]
        try writeJSONArray(releases, to: releasesURL)
        let environment = [
            "APP_VERSION": "2.0.0",
            "GH_TOKEN": "fixture-token",
            "GITHUB_REPOSITORY": "DaliangPro/Dal",
            "DAL_RELEASE_RELEASES_FIXTURE": releasesURL.path,
            "DAL_RELEASE_UPDATES_FIXTURE": updatesURL.path,
            "DAL_RELEASE_VERSION_TEST_MODE": "1",
        ]

        let valid = try run(
            "/bin/bash",
            arguments: [versionPolicyScriptURL.path],
            environment: environment
        )
        XCTAssertEqual(valid.status, 0, valid.output)

        try writeJSON(["latest": "1.7.3", "releases": []], to: updatesURL)
        let staleManifest = try run(
            "/bin/bash",
            arguments: [versionPolicyScriptURL.path],
            environment: environment
        )
        XCTAssertNotEqual(staleManifest.status, 0, staleManifest.output)

        try writeJSON(["latest": "1.7.4", "releases": []], to: updatesURL)
        var downgrade = environment
        downgrade["APP_VERSION"] = "1.7.4"
        let downgradeResult = try run(
            "/bin/bash",
            arguments: [versionPolicyScriptURL.path],
            environment: downgrade
        )
        XCTAssertNotEqual(downgradeResult.status, 0, downgradeResult.output)

        var occupiedTarget = releases
        occupiedTarget.append(["tag_name": "v2.0.0", "draft": false, "prerelease": true])
        try writeJSONArray(occupiedTarget, to: releasesURL)
        let occupiedResult = try run(
            "/bin/bash",
            arguments: [versionPolicyScriptURL.path],
            environment: environment
        )
        XCTAssertNotEqual(occupiedResult.status, 0, occupiedResult.output)
    }

    func testNotarizationSubmitsStaplesAndRevalidatesBothDMGs() throws {
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("dal-notarization-\(UUID().uuidString)", isDirectory: true)
        defer { trash(rootURL) }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let cloudURL = rootURL.appendingPathComponent("cloud.dmg")
        let localURL = rootURL.appendingPathComponent("local.dmg")
        let keyURL = rootURL.appendingPathComponent("AuthKey_ABCDEF1234.p8")
        let logURL = rootURL.appendingPathComponent("tools.log")
        try Data("cloud".utf8).write(to: cloudURL)
        try Data("local".utf8).write(to: localURL)
        try Data("private-key".utf8).write(to: keyURL)
        try Data().write(to: logURL)

        let xcrunURL = rootURL.appendingPathComponent("xcrun")
        let spctlURL = rootURL.appendingPathComponent("spctl")
        try writeExecutable(Self.notaryXcrunShim, to: xcrunURL)
        try writeExecutable(Self.notarySpctlShim, to: spctlURL)
        let environment = [
            "CLOUD_DMG": cloudURL.path,
            "LOCAL_DMG": localURL.path,
            "DAL_NOTARIZATION_MODE": "submit",
            "DAL_NOTARIZATION_SPCTL_BIN": spctlURL.path,
            "DAL_NOTARIZATION_TEST_MODE": "1",
            "DAL_NOTARIZATION_XCRUN_BIN": xcrunURL.path,
            "DAL_TEST_TOOL_LOG": logURL.path,
            "NOTARY_ISSUER_ID": "12345678-1234-1234-1234-1234567890ab",
            "NOTARY_KEY_ID": "ABCDEF1234",
            "NOTARY_KEY_PATH": keyURL.path
        ]

        let submit = try run(
            "/bin/bash",
            arguments: [notarizationScriptURL.path],
            environment: environment
        )
        XCTAssertEqual(submit.status, 0, submit.output)
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "notarytool submit").count - 1, 2, log)
        XCTAssertEqual(log.components(separatedBy: "stapler staple").count - 1, 2, log)
        XCTAssertEqual(log.components(separatedBy: "stapler validate").count - 1, 2, log)
        XCTAssertEqual(log.components(separatedBy: "spctl:").count - 1, 2, log)

        try assertVerifyNotarizationMode(environment: environment, logURL: logURL)
    }

    func testScriptContainsNoManualHashInputOrLegacySingleArtifactFallback() throws {
        let source = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(source.contains(#"SHASUM_BIN="/usr/bin/shasum""#), source)
        XCTAssertTrue(source.contains(#""$SHASUM_BIN" -a 256"#), source)
        XCTAssertTrue(source.contains("manifest-fragment.json"), source)
        XCTAssertTrue(source.contains("cloud"), source)
        XCTAssertTrue(source.contains("local"), source)
        XCTAssertFalse(source.contains("CLOUD_SHA256="), source)
        XCTAssertFalse(source.contains("LOCAL_SHA256="), source)
        XCTAssertFalse(source.contains("ALLOW_ADHOC"), source)

        let manifestValidation = try XCTUnwrap(
            source.range(
                of: #"\n\s*"\$JQ_BIN"\s+-e\s+\\\n\s+--arg version"#,
                options: .regularExpression
            )
        )
        let manifestPublication = try XCTUnwrap(
            source.range(of: #"/bin/mv "$MANIFEST_TEMP" "$MANIFEST_PATH""#)
        )
        XCTAssertLessThan(
            manifestValidation.lowerBound,
            manifestPublication.lowerBound,
            "manifest 必须先完整回读验证，最后才能原子发布"
        )
    }

    private struct Fixture {
        let rootURL: URL
        let scriptURL: URL
        let outputURL: URL
        let cloudDMGURL: URL
        let localDMGURL: URL
        let manifestURL: URL
        let toolLogURL: URL
        let version: String
        let environment: [String: String]
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var scriptURL: URL {
        repositoryRoot.appendingPathComponent("scripts/release-verify.sh")
    }

    private var environmentPolicyScriptURL: URL {
        repositoryRoot.appendingPathComponent("scripts/verify-release-environments.sh")
    }

    private var notarizationScriptURL: URL {
        repositoryRoot.appendingPathComponent("scripts/notarize-release-artifacts.sh")
    }

    private var artifactPolicyScriptURL: URL {
        repositoryRoot.appendingPathComponent("scripts/verify-release-artifact.sh")
    }

    private var versionPolicyScriptURL: URL {
        repositoryRoot.appendingPathComponent("scripts/verify-release-version.sh")
    }

    private func validEnvironment(named name: String) -> [String: Any] {
        [
            "name": name,
            "can_admins_bypass": false,
            "protection_rules": [[
                "type": "required_reviewers",
                "prevent_self_review": true,
                "reviewers": [[
                    "type": "User",
                    "reviewer": ["login": "release-reviewer"],
                ]],
            ]],
            "deployment_branch_policy": [
                "protected_branches": false,
                "custom_branch_policies": true,
            ],
        ]
    }

    private func writeValidEnvironmentFixtures(to rootURL: URL) throws {
        let branchPolicy: [String: Any] = [
            "total_count": 1,
            "branch_policies": [["name": "main", "type": "branch"]],
        ]
        for name in ["release-signing", "release"] {
            try writeJSON(
                validEnvironment(named: name),
                to: rootURL.appendingPathComponent("\(name).environment.json")
            )
            try writeJSON(
                branchPolicy,
                to: rootURL.appendingPathComponent("\(name).branches.json")
            )
        }
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    private func writeJSONArray(_ object: [[String: Any]], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    private func releaseEnvironmentTestEnvironment(fixtureURL: URL) -> [String: String] {
        [
            "DEFAULT_BRANCH": "main",
            "GITHUB_REF_NAME": "main",
            "GITHUB_REPOSITORY": "DaliangPro/Dal",
            "DAL_RELEASE_ENVIRONMENT_FIXTURE_DIR": fixtureURL.path,
            "DAL_RELEASE_ENVIRONMENT_TEST_MODE": "1",
        ]
    }

    private func makeFixture() throws -> Fixture {
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("dal-release-verify-\(UUID().uuidString)", isDirectory: true)
        let scriptsURL = rootURL.appendingPathComponent("scripts", isDirectory: true)
        let toolsURL = rootURL.appendingPathComponent("tools", isDirectory: true)
        let outputURL = rootURL.appendingPathComponent("release-output", isDirectory: true)
        let homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        let tempURL = rootURL.appendingPathComponent("temp", isDirectory: true)
        for directory in [
            scriptsURL,
            toolsURL,
            outputURL,
            homeURL.appendingPathComponent(".Trash", isDirectory: true),
            tempURL,
            rootURL.appendingPathComponent("sensevoice-server/dist/sensevoice-server", isDirectory: true),
            rootURL.appendingPathComponent("qwen3-asr-server/dist/qwen3-asr-server", isDirectory: true),
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let copiedScriptURL = scriptsURL.appendingPathComponent("release-verify.sh")
        try String(contentsOf: scriptURL, encoding: .utf8)
            .write(to: copiedScriptURL, atomically: true, encoding: .utf8)
        let buildDMGURL = toolsURL.appendingPathComponent("build-dmg")
        let bundleTestURL = toolsURL.appendingPathComponent("test-app-bundle")
        let codesignURL = toolsURL.appendingPathComponent("codesign")
        let hdiutilURL = toolsURL.appendingPathComponent("hdiutil")
        let notarizeURL = toolsURL.appendingPathComponent("notarize")
        let shasumURL = toolsURL.appendingPathComponent("shasum")
        try writeExecutable(Self.buildDMGShim, to: buildDMGURL)
        try writeExecutable(Self.bundleTestShim, to: bundleTestURL)
        try writeExecutable(Self.codesignShim, to: codesignURL)
        try writeExecutable(Self.hdiutilShim, to: hdiutilURL)
        try writeExecutable(Self.notarizeShim, to: notarizeURL)
        try writeExecutable(Self.shasumShim, to: shasumURL)

        for launcher in [
            rootURL.appendingPathComponent("sensevoice-server/dist/sensevoice-server/sensevoice-server"),
            rootURL.appendingPathComponent("qwen3-asr-server/dist/qwen3-asr-server/qwen3-asr-server"),
        ] {
            try writeExecutable("#!/bin/bash\nexit 0\n", to: launcher)
        }

        let toolLogURL = rootURL.appendingPathComponent("tool.log")
        try Data().write(to: toolLogURL)
        try Data(#"{"latest":"1.7.4","releases":[]}"#.utf8)
            .write(to: rootURL.appendingPathComponent("updates.json"))
        let version = "2.3.4"
        let cloudDMGURL = outputURL.appendingPathComponent("Dal-v\(version)-cloud.dmg")
        let localDMGURL = outputURL.appendingPathComponent("Dal-v\(version)-local.dmg")
        let manifestURL = outputURL.appendingPathComponent("manifest-fragment.json")
        let environment = [
            "APP_BUILD": "7",
            "APP_VERSION": version,
            "CODESIGN_IDENTITY": "Developer ID Application: Fixture (TEAM123456)",
            "EXPECTED_TEAM_ID": "TEAM123456",
            "HOME": homeURL.path,
            "DAL_RELEASE_BUILD_DMG_SCRIPT": buildDMGURL.path,
            "DAL_RELEASE_CODESIGN_BIN": codesignURL.path,
            "DAL_RELEASE_HDIUTIL_BIN": hdiutilURL.path,
            "DAL_RELEASE_NOTARIZE_SCRIPT": notarizeURL.path,
            "DAL_RELEASE_SHASUM_BIN": shasumURL.path,
            "DAL_RELEASE_TEST_APP_BUNDLE_SCRIPT": bundleTestURL.path,
            "DAL_RELEASE_VERIFY_TEST_MODE": "1",
            "DAL_TEST_TOOL_LOG": toolLogURL.path,
            "RELEASE_BASE_URL": "https://updates.example/releases/v\(version)",
            "RELEASE_DATE": "2026-07-21",
            "RELEASE_NOTES": "fixture release",
            "RELEASE_OUTPUT_DIR": outputURL.path,
            "RELEASE_VERIFY_MODE": "build",
            "TMPDIR": tempURL.path,
        ]
        return Fixture(
            rootURL: rootURL,
            scriptURL: copiedScriptURL,
            outputURL: outputURL,
            cloudDMGURL: cloudDMGURL,
            localDMGURL: localDMGURL,
            manifestURL: manifestURL,
            toolLogURL: toolLogURL,
            version: version,
            environment: environment
        )
    }

    private func runScript(_ fixture: Fixture) throws -> (status: Int32, output: String) {
        try run("/bin/bash", arguments: [fixture.scriptURL.path], environment: fixture.environment)
    }

    private func assertVerifyNotarizationMode(
        environment: [String: String],
        logURL: URL
    ) throws {
        try Data().write(to: logURL, options: .atomic)
        var verifyEnvironment = environment
        verifyEnvironment["DAL_NOTARIZATION_MODE"] = "verify"
        verifyEnvironment.removeValue(forKey: "NOTARY_ISSUER_ID")
        verifyEnvironment.removeValue(forKey: "NOTARY_KEY_ID")
        verifyEnvironment.removeValue(forKey: "NOTARY_KEY_PATH")
        let verify = try run(
            "/bin/bash",
            arguments: [notarizationScriptURL.path],
            environment: verifyEnvironment
        )
        XCTAssertEqual(verify.status, 0, verify.output)
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(log.contains("notarytool submit"), log)
        XCTAssertFalse(log.contains("stapler staple"), log)
        XCTAssertEqual(log.components(separatedBy: "stapler validate").count - 1, 2, log)
        XCTAssertEqual(log.components(separatedBy: "spctl:").count - 1, 2, log)
    }

    private func manifestObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func sha256(of url: URL) throws -> String {
        let result = try run("/usr/bin/shasum", arguments: ["-a", "256", url.path])
        XCTAssertEqual(result.status, 0, result.output)
        return String(result.output.split(separator: " ").first ?? "")
    }

    private func writeExecutable(_ source: String, to url: URL) throws {
        try source.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func trash(_ url: URL) {
        try? fileManager.trashItem(at: url, resultingItemURL: nil)
    }

    private func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (process.terminationStatus, output)
    }

    private static let buildDMGShim = #"""
        #!/bin/bash
        set -euo pipefail
        printf 'build:%s\n' "$ARTIFACT_KIND" >> "$DAL_TEST_TOOL_LOG"
        [ "${DAL_TEST_SKIP_ARTIFACT_KIND:-}" != "$ARTIFACT_KIND" ] || exit 0
        /bin/mkdir -p "$DIST_DIR"
        printf 'fixture-%s-%s' "$ARTIFACT_KIND" "$APP_VERSION" \
            > "$DIST_DIR/Dal-v${APP_VERSION}-${ARTIFACT_KIND}.dmg"
        """#

    private static let bundleTestShim = #"""
        #!/bin/bash
        set -euo pipefail
        [ -d "${1:-}" ]
        printf 'bundle:%s:%s\n' "$EXPECT_LOCAL_BUNDLE" "$1" >> "$DAL_TEST_TOOL_LOG"
        """#

    private static let codesignShim = #"""
        #!/bin/bash
        set -euo pipefail
        subject="${!#}"
        case " $* " in
            *" --verify "*)
                printf 'codesign:verify:%s\n' "$subject" >> "$DAL_TEST_TOOL_LOG"
                case "$subject" in
                    *"-${DAL_TEST_FAIL_VERIFY_KIND:-__none__}.dmg"|*"/${DAL_TEST_FAIL_VERIFY_KIND:-__none__}/Dal.app") exit 91 ;;
                esac
                ;;
            *" -dvvv "*)
                printf 'codesign:display:%s\n' "$subject" >> "$DAL_TEST_TOOL_LOG"
                printf 'Authority=Developer ID Application: Fixture\n' >&2
                printf 'flags=0x10000(runtime)\n' >&2
                printf 'TeamIdentifier=TEAM123456\n' >&2
                ;;
            *)
                echo "unexpected codesign invocation: $*" >&2
                exit 92
                ;;
        esac
        """#

    private static let hdiutilShim = #"""
        #!/bin/bash
        set -euo pipefail
        command_name="${1:-}"
        shift || true
        case "$command_name" in
            verify)
                printf 'hdiutil:verify:%s\n' "${1:-}" >> "$DAL_TEST_TOOL_LOG"
                ;;
            attach)
                mount_point=""
                previous=""
                for argument in "$@"; do
                    if [ "$previous" = "-mountpoint" ]; then mount_point="$argument"; fi
                    previous="$argument"
                done
                [ -n "$mount_point" ]
                /bin/mkdir -p "$mount_point/Dal.app/Contents"
                printf 'mounted' > "$mount_point/Dal.app/Contents/payload"
                printf 'hdiutil:attach:%s\n' "$mount_point" >> "$DAL_TEST_TOOL_LOG"
                ;;
            detach)
                printf 'hdiutil:detach:%s\n' "${1:-}" >> "$DAL_TEST_TOOL_LOG"
                ;;
            *) exit 93 ;;
        esac
        """#

    private static let shasumShim = #"""
        #!/bin/bash
        set -euo pipefail
        printf 'shasum:%s\n' "$*" >> "$DAL_TEST_TOOL_LOG"
        exec /usr/bin/shasum "$@"
        """#

    private static let notarizeShim = #"""
        #!/bin/bash
        set -euo pipefail
        [ -f "$CLOUD_DMG" ]
        [ -f "$LOCAL_DMG" ]
        printf 'notary:%s:%s:%s\n' "$DAL_NOTARIZATION_MODE" "$CLOUD_DMG" "$LOCAL_DMG" \
            >> "$DAL_TEST_TOOL_LOG"
        [ "${DAL_TEST_FAIL_NOTARIZATION:-0}" != "1" ] || exit 98
        if [ "$DAL_NOTARIZATION_MODE" = "submit" ]; then
            printf '%s' '-stapled' >> "$CLOUD_DMG"
            printf '%s' '-stapled' >> "$LOCAL_DMG"
        fi
        """#

    private static let notaryXcrunShim = #"""
        #!/bin/bash
        set -euo pipefail
        printf 'xcrun:%s\n' "$*" >> "$DAL_TEST_TOOL_LOG"
        case "${1:-}:${2:-}" in
            notarytool:submit|stapler:staple|stapler:validate) ;;
            *) exit 97 ;;
        esac
        """#

    private static let notarySpctlShim = #"""
        #!/bin/bash
        set -euo pipefail
        printf 'spctl:%s\n' "$*" >> "$DAL_TEST_TOOL_LOG"
        """#
}
