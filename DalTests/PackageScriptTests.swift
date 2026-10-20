import Foundation
import XCTest
@testable import Dal

final class PackageScriptTests: XCTestCase {
    private let fileManager = FileManager.default

    func testPackagingScriptsPassBashSyntaxCheck() throws {
        for relativePath in [
            "scripts/package-app.sh",
            "scripts/prepare-release-binary.sh",
            "scripts/sign-app-bundle.sh",
            "scripts/test_app_bundle.sh",
            "scripts/health-check.sh",
            "scripts/build_and_run.sh",
        ] {
            let result = try run("/bin/bash", arguments: ["-n", repositoryRoot.appendingPathComponent(relativePath).path])
            XCTAssertEqual(result.status, 0, "\(relativePath): \(result.output)")
        }
    }

    func testBuildAndRunUsesVerifiedTransactionalInstaller() throws {
        let source = try source(at: "scripts/build_and_run.sh")
        XCTAssertTrue(source.contains("scripts/deploy.sh"))
        XCTAssertTrue(source.contains("verify_single_running_instance"))
        XCTAssertFalse(source.contains("killall"))
        XCTAssertFalse(source.contains("pkill"))
        let deploy = try self.source(at: "scripts/deploy.sh")
        let packageCall = try XCTUnwrap(deploy.range(of: "bash \"$SCRIPT_DIR/package-app.sh\""))
        let installCall = try XCTUnwrap(deploy.range(of: "python3 \"$SCRIPT_DIR/install-app.py\""))
        XCTAssertLessThan(packageCall.lowerBound, installCall.lowerBound)
    }

    func testPackagingScriptRequiresStrictFinalSealPolicy() throws {
        let packageSource = try source(at: "scripts/package-app.sh")
        let signingSource = try source(at: "scripts/sign-app-bundle.sh")

        XCTAssertFalse(packageSource.contains("SERVER_TEMP="))
        XCTAssertFalse(packageSource.range(of: #"codesign[^\n]*--sign[^\n]*\|\|\s*true"#, options: .regularExpression) != nil)
        XCTAssertTrue(packageSource.contains("sign-app-bundle.sh"))
        XCTAssertTrue(packageSource.contains("test_app_bundle.sh"))
        XCTAssertTrue(packageSource.contains(#"/usr/bin/find "$APP_PATH" -type d"#))
        XCTAssertTrue(packageSource.contains(#"/bin/chmod 644"#))
        XCTAssertTrue(packageSource.contains(#"/bin/chmod 755"#))
        XCTAssertTrue(signingSource.contains(#"/usr/bin/file"#))
        XCTAssertTrue(signingSource.contains(#"MetalLib\ executable"#))
        XCTAssertTrue(signingSource.contains("--options runtime"), signingSource)
        XCTAssertTrue(signingSource.contains("--timestamp"), signingSource)
        XCTAssertTrue(signingSource.contains("DAL_DEFER_GATEKEEPER_ASSESSMENT"), signingSource)
        XCTAssertTrue(
            packageSource.contains("Refusing to package a tracked dirty worktree"),
            packageSource
        )
        XCTAssertTrue(
            packageSource.contains("DAL_SOURCE_COMMIT cannot override provenance"),
            packageSource
        )
        XCTAssertTrue(
            packageSource.contains(#"git -C "$PROJECT_DIR" diff --quiet"#),
            packageSource
        )
        XCTAssertTrue(
            packageSource.contains(#"git -C "$PROJECT_DIR" diff --cached --quiet"#),
            packageSource
        )
        XCTAssertTrue(
            packageSource.contains(#"git -C "$PROJECT_DIR" ls-files --others --exclude-standard"#),
            packageSource
        )
        XCTAssertTrue(
            packageSource.contains("Refusing to package untracked build inputs"),
            packageSource
        )
        XCTAssertTrue(
            packageSource.contains(
                #"QUALITY_DATASET_PATH="$PROJECT_DIR/docs/2026-08-17-Dal-Voice-Polish-Quality-Test-Set.json""#
            ),
            packageSource
        )
        XCTAssertTrue(
            packageSource.contains(
                "DAL_QUALITY_DATASET_PATH cannot override the frozen production dataset"
            ),
            packageSource
        )

        let outerSign = #"/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" "$APP_PATH""#
        let strictVerify = #"/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_PATH""#
        let outerRange = try XCTUnwrap(signingSource.range(of: outerSign))
        let verifyRange = try XCTUnwrap(signingSource.range(of: strictVerify))
        XCTAssertLessThan(outerRange.lowerBound, verifyRange.lowerBound)

        let postSealSource = signingSource[outerRange.upperBound...]
        let forbiddenMutation = #"(?m)^\s*(?:/[A-Za-z0-9_./-]+/)?(?:cp|mv|mkdir|chmod|xattr|ditto|install|tee|touch|ln|trash_path|trash_paths)\b"#
        XCTAssertNil(postSealSource.range(of: forbiddenMutation, options: .regularExpression))
        XCTAssertNil(postSealSource.range(of: #"(?m)^.*(?:>|>>).*[\"']?\$APP_PATH"#, options: .regularExpression))

        let signingCall = #"/bin/bash "$SCRIPT_DIR/sign-app-bundle.sh" "$APP_PATH""#
        let signingCallRange = try XCTUnwrap(packageSource.range(of: signingCall))
        let postSigningCallSource = packageSource[signingCallRange.upperBound...]
        XCTAssertNil(postSigningCallSource.range(of: forbiddenMutation, options: .regularExpression))
        XCTAssertNil(postSigningCallSource.range(of: #"(?m)^.*(?:>|>>).*[\"']?\$APP_PATH"#, options: .regularExpression))
    }

    func testNestedSignFailureAbortsBeforeOuterSignature() throws {
        let fixture = try makeBundleFixture(includesLocalServices: true)
        defer { try? fileManager.trashItem(at: fixture.root, resultingItemURL: nil) }
        let shim = fixture.root.appendingPathComponent("failing-codesign")
        try "#!/bin/bash\nexit 42\n".write(to: shim, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)

        let result = try runSigningPhase(
            for: fixture.app,
            extraEnvironment: [
                "DAL_PACKAGE_SIGNING_TEST_MODE": "1",
                "DAL_NESTED_CODESIGN_BIN": shim.path,
            ]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Nested code signing failed"), result.output)
        XCTAssertFalse(result.output.contains("Signing outer app bundle last"), result.output)
        let verification = try strictVerification(of: fixture.app)
        XCTAssertNotEqual(verification.status, 0, verification.output)
    }

    func testMetalLibrarySignFailureAbortsBeforeOuterSignature() throws {
        let fixture = try makeBundleFixture(includesLocalServices: false)
        defer { try? fileManager.trashItem(at: fixture.root, resultingItemURL: nil) }
        let metalLibrary = fixture.app
            .appendingPathComponent("Contents/Resources/mlx.metallib")
        try Data([
            0x4d, 0x54, 0x4c, 0x42, 0x01, 0x80, 0x02, 0x00,
            0x09, 0x00, 0x00, 0x81, 0x1a, 0x00, 0x00, 0x00,
        ]).write(to: metalLibrary)
        let classification = try run("/usr/bin/file", arguments: ["-b", metalLibrary.path])
        XCTAssertEqual(classification.status, 0, classification.output)
        XCTAssertTrue(classification.output.contains("MetalLib executable"), classification.output)

        let shim = fixture.root.appendingPathComponent("failing-codesign")
        try "#!/bin/bash\nexit 42\n".write(to: shim, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        let result = try runSigningPhase(
            for: fixture.app,
            extraEnvironment: [
                "DAL_PACKAGE_SIGNING_TEST_MODE": "1",
                "DAL_NESTED_CODESIGN_BIN": shim.path,
            ]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Contents/Resources/mlx.metallib"), result.output)
        XCTAssertTrue(result.output.contains("Nested code signing failed"), result.output)
        XCTAssertFalse(result.output.contains("Signing outer app bundle last"), result.output)
    }

    func testInteractiveBundleKeepsItsOwnNameAndURLScheme() throws {
        let fixture = try makePackagingFixture()
        defer { try? fileManager.trashItem(at: fixture.root, resultingItemURL: nil) }
        let packaging = try runPackage(fixture, includesLocalServices: false, extraEnvironment: [
            "APP_NAME": "Dal 交互测试",
            "APP_BUNDLE_ID": "pro.daliang.muse.interactive-test",
        ])
        XCTAssertEqual(packaging.status, 0, packaging.output)
        let data = try Data(contentsOf: fixture.app.appendingPathComponent("Contents/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleName"] as? String, "Dal 交互测试")
        let urlTypes = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        XCTAssertEqual(urlTypes.first?["CFBundleURLSchemes"] as? [String], ["dal-interactive-test"])
    }

    func testCloudBundlePassesStrictVerification() throws {
        let fixture = try makePackagingFixture()
        defer { try? fileManager.trashItem(at: fixture.root, resultingItemURL: nil) }

        let packaging = try runPackage(fixture, includesLocalServices: false)
        XCTAssertEqual(packaging.status, 0, packaging.output)
        XCTAssertFalse(fileManager.fileExists(atPath: fixture.app.appendingPathComponent("Contents/MacOS/sensevoice-server-dist").path))

        let validation = try runBundleValidation(for: fixture.app, expectsLocalServices: false)
        XCTAssertEqual(validation.status, 0, validation.output)
    }

    func testPackagingFreezesExternalQualityManifestAfterFinalSignature() throws {
        let fixture = try makePackagingFixture()
        defer { try? fileManager.trashItem(at: fixture.root, resultingItemURL: nil) }
        let manifest = fixture.root.appendingPathComponent("quality-build-manifest.json")
        let dataset = fixture.root.appendingPathComponent("quality-dataset.json")
        let datasetData = Data("quality-dataset-fixture".utf8)
        try datasetData.write(to: dataset)
        let commit = String(repeating: "1", count: 40)
        let tree = String(repeating: "2", count: 40)

        let packaging = try runPackage(
            fixture,
            includesLocalServices: false,
            extraEnvironment: [
                "DAL_QUALITY_BUILD_MANIFEST_PATH": manifest.path,
                "DAL_QUALITY_DATASET_PATH": dataset.path,
                "DAL_SOURCE_COMMIT": commit,
                "DAL_SOURCE_TREE": tree,
            ]
        )

        XCTAssertEqual(packaging.status, 0, packaging.output)
        XCTAssertTrue(packaging.output.contains("Quality build manifest ready"), packaging.output)
        let data = try Data(contentsOf: manifest)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(document["schema_version"] as? Int, 1)
        XCTAssertEqual(
            document["artifact_kind"] as? String,
            "dal_voice_polish_quality_candidate"
        )
        XCTAssertEqual(document["package_mode"] as? String, "test")
        XCTAssertEqual(document["source_commit"] as? String, commit)
        XCTAssertEqual(document["source_tree"] as? String, tree)
        let datasetHash = VoicePolishProviderAudit.sha256Hex(datasetData)
        XCTAssertEqual(document["dataset_sha256"] as? String, datasetHash)
        let executable = fixture.app.appendingPathComponent("Contents/MacOS/Dal")
        let executableHash = try run(
            "/usr/bin/shasum",
            arguments: ["-a", "256", executable.path]
        ).output.split(separator: " ").first.map(String.init)
        XCTAssertEqual(document["executable_sha256"] as? String, executableHash)
        let requirement = try XCTUnwrap(document["designated_requirement"] as? String)
        XCTAssertFalse(requirement.isEmpty)
        XCTAssertEqual(
            document["designated_requirement_sha256"] as? String,
            VoicePolishProviderAudit.sha256Hex(Data(requirement.utf8))
        )
        let manifestHash = VoicePolishProviderAudit.sha256Hex(data)
        XCTAssertTrue(
            packaging.output.contains("DAL_QUALITY_EXPECTED_MANIFEST_SHA256=\(manifestHash)"),
            packaging.output
        )
        XCTAssertTrue(
            packaging.output.contains("DAL_QUALITY_EXPECTED_DATASET_SHA256=\(datasetHash)"),
            packaging.output
        )
        let attributes = try fileManager.attributesOfItem(atPath: manifest.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o444)
    }

    func testQualityManifestTestModeRejectsRelativeAndSymlinkDataset() throws {
        let fixture = try makePackagingFixture()
        defer { try? fileManager.trashItem(at: fixture.root, resultingItemURL: nil) }
        let manifest = fixture.root.appendingPathComponent("quality-build-manifest.json")
        let provenance = [
            "DAL_QUALITY_BUILD_MANIFEST_PATH": manifest.path,
            "DAL_SOURCE_COMMIT": String(repeating: "1", count: 40),
            "DAL_SOURCE_TREE": String(repeating: "2", count: 40),
        ]

        let relative = try runPackage(
            fixture,
            includesLocalServices: false,
            extraEnvironment: provenance.merging([
                "DAL_QUALITY_DATASET_PATH": "relative-quality-dataset.json",
            ]) { _, new in new }
        )
        XCTAssertNotEqual(relative.status, 0, relative.output)
        XCTAssertTrue(relative.output.contains("dataset path must be absolute"), relative.output)

        let dataset = fixture.root.appendingPathComponent("quality-dataset.json")
        try Data("fixture".utf8).write(to: dataset)
        let symlink = fixture.root.appendingPathComponent("quality-dataset-link.json")
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: dataset)
        let linked = try runPackage(
            fixture,
            includesLocalServices: false,
            extraEnvironment: provenance.merging([
                "DAL_QUALITY_DATASET_PATH": symlink.path,
            ]) { _, new in new }
        )
        XCTAssertNotEqual(linked.status, 0, linked.output)
        XCTAssertTrue(linked.output.contains("regular non-symlink file"), linked.output)
    }

    func testSigningWindowRequiresHashLockedPrebuiltBinary() throws {
        let fixture = try makePackagingFixture()
        defer { try? fileManager.trashItem(at: fixture.root, resultingItemURL: nil) }

        let missing = try runPackage(
            fixture,
            includesLocalServices: false,
            extraEnvironment: ["DAL_PACKAGE_REQUIRE_PREBUILT": "1"]
        )
        XCTAssertNotEqual(missing.status, 0, missing.output)

        let wrongHash = try runPackage(
            fixture,
            includesLocalServices: false,
            extraEnvironment: [
                "DAL_PACKAGE_PREBUILT_BINARY": fixture.binary.path,
                "DAL_PACKAGE_PREBUILT_SHA256": String(repeating: "0", count: 64),
                "DAL_PACKAGE_REQUIRE_PREBUILT": "1"
            ]
        )
        XCTAssertNotEqual(wrongHash.status, 0, wrongHash.output)

        let seed = try runPackage(fixture, includesLocalServices: false)
        XCTAssertEqual(seed.status, 0, seed.output)
        try fileManager.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.binary.path
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.app.path)
        let hash = try run(
            "/usr/bin/shasum",
            arguments: ["-a", "256", fixture.binary.path]
        ).output.split(separator: " ").first.map(String.init)
        let valid = try runPackage(
            fixture,
            includesLocalServices: false,
            extraEnvironment: [
                "DAL_PACKAGE_PREBUILT_BINARY": fixture.binary.path,
                "DAL_PACKAGE_PREBUILT_SHA256": try XCTUnwrap(hash),
                "DAL_PACKAGE_REQUIRE_PREBUILT": "1"
            ]
        )
        XCTAssertEqual(valid.status, 0, valid.output)
        let executable = fixture.app.appendingPathComponent("Contents/MacOS/Dal")
        let attributes = try fileManager.attributesOfItem(atPath: executable.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o755)
        let appAttributes = try fileManager.attributesOfItem(atPath: fixture.app.path)
        XCTAssertEqual(appAttributes[.posixPermissions] as? Int, 0o755)
        let plist = fixture.app.appendingPathComponent("Contents/Info.plist")
        let plistAttributes = try fileManager.attributesOfItem(atPath: plist.path)
        XCTAssertEqual(plistAttributes[.posixPermissions] as? Int, 0o644)
    }

    func testLocalBundleMissingDistributionFailsBeforeReplacingExistingContents() throws {
        let fixture = try makePackagingFixture(omittingService: "qwen3-asr-server")
        defer { try? fileManager.trashItem(at: fixture.root, resultingItemURL: nil) }
        let seed = try runPackage(fixture, includesLocalServices: false)
        XCTAssertEqual(seed.status, 0, seed.output)
        let existingResources = fixture.app
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        try fileManager.createDirectory(at: existingResources, withIntermediateDirectories: true)
        let sentinel = existingResources.appendingPathComponent("existing-install.txt")
        try Data("preserve".utf8).write(to: sentinel)
        let reseal = try runSigningPhase(for: fixture.app)
        XCTAssertEqual(reseal.status, 0, reseal.output)

        let packaging = try runPackage(fixture, includesLocalServices: true)

        XCTAssertNotEqual(packaging.status, 0, packaging.output)
        XCTAssertTrue(packaging.output.contains("both frozen service distributions are required"), packaging.output)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
    }

    func testLocalBundleMissingLauncherFailsBeforeReplacingExistingContents() throws {
        let fixture = try makePackagingFixture(omittingService: "qwen3-asr-server")
        defer { try? fileManager.trashItem(at: fixture.root, resultingItemURL: nil) }
        let incompleteDistribution = fixture.project
            .appendingPathComponent("qwen3-asr-server/dist/qwen3-asr-server", isDirectory: true)
        try fileManager.createDirectory(at: incompleteDistribution, withIntermediateDirectories: true)
        let seed = try runPackage(fixture, includesLocalServices: false)
        XCTAssertEqual(seed.status, 0, seed.output)
        let existingResources = fixture.app
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        try fileManager.createDirectory(at: existingResources, withIntermediateDirectories: true)
        let sentinel = existingResources.appendingPathComponent("existing-install.txt")
        try Data("preserve".utf8).write(to: sentinel)
        let reseal = try runSigningPhase(for: fixture.app)
        XCTAssertEqual(reseal.status, 0, reseal.output)

        let packaging = try runPackage(fixture, includesLocalServices: true)

        XCTAssertNotEqual(packaging.status, 0, packaging.output)
        XCTAssertTrue(packaging.output.contains("both frozen service launchers are required"), packaging.output)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
    }

    func testLocalBundleWithServicesPassesStrictVerification() throws {
        let fixture = try makePackagingFixture()
        defer { try? fileManager.trashItem(at: fixture.root, resultingItemURL: nil) }

        let packaging = try runPackage(fixture, includesLocalServices: true)
        XCTAssertEqual(packaging.status, 0, packaging.output)
        XCTAssertTrue(packaging.output.contains("Signing nested Mach-O: Contents/MacOS/sensevoice-server-dist/nested-code.data"), packaging.output)
        let outerMarker = try XCTUnwrap(packaging.output.range(of: "Signing outer app bundle last"))
        let nestedMarker = try XCTUnwrap(packaging.output.range(of: "Signing nested Mach-O:"))
        XCTAssertLessThan(nestedMarker.lowerBound, outerMarker.lowerBound)

        let validation = try runBundleValidation(for: fixture.app, expectsLocalServices: true)
        XCTAssertEqual(validation.status, 0, validation.output)
        for nestedExecutable in fixture.nestedExecutables {
            let nestedVerification = try run(
                "/usr/bin/codesign",
                arguments: ["--verify", "--strict", "--verbose=4", nestedExecutable.path]
            )
            XCTAssertEqual(nestedVerification.status, 0, nestedVerification.output)
        }
    }

    func testModifyingSignedBundleMakesStrictVerificationFail() throws {
        let fixture = try makeBundleFixture(includesLocalServices: false)
        defer { try? fileManager.trashItem(at: fixture.root, resultingItemURL: nil) }
        let signing = try runSigningPhase(for: fixture.app)
        XCTAssertEqual(signing.status, 0, signing.output)

        try Data("tampered".utf8).write(
            to: fixture.app.appendingPathComponent("Contents/Resources/payload.txt"),
            options: .atomic
        )

        let validation = try runBundleValidation(for: fixture.app, expectsLocalServices: false)
        XCTAssertNotEqual(validation.status, 0, validation.output)
    }

    func testBundleValidationScriptAlwaysUsesStrictVerification() throws {
        let source = try source(at: "scripts/test_app_bundle.sh")
        XCTAssertTrue(source.contains(#"/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_PATH""#))
        XCTAssertTrue(source.contains(#"/usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH""#))
    }

    private struct BundleFixture {
        let root: URL
        let app: URL
        let nestedExecutables: [URL]
    }

    private struct PackagingFixture {
        let root: URL
        let project: URL
        let home: URL
        let binary: URL
        let app: URL
        let nestedExecutables: [URL]
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(at relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func makeBundleFixture(includesLocalServices: Bool) throws -> BundleFixture {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("dal-package-signing-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Dal.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

        let mainExecutable = macOS.appendingPathComponent("Dal")
        try copyExecutable(from: URL(fileURLWithPath: "/usr/bin/true"), to: mainExecutable)
        try Data("fixture".utf8).write(to: resources.appendingPathComponent("AppIcon.icns"))
        try Data("logo".utf8).write(to: resources.appendingPathComponent("BrandLogo.png"))
        try Data("original".utf8).write(to: resources.appendingPathComponent("payload.txt"))
        try infoPlist.write(
            to: contents.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        var nestedExecutables: [URL] = []
        if includesLocalServices {
            for service in ["sensevoice-server", "qwen3-asr-server"] {
                let dist = macOS.appendingPathComponent("\(service)-dist", isDirectory: true)
                try fileManager.createDirectory(at: dist, withIntermediateDirectories: true)
                let nested = dist.appendingPathComponent(service)
                try copyExecutable(from: URL(fileURLWithPath: "/usr/bin/true"), to: nested)
                nestedExecutables.append(nested)

                try fileManager.createSymbolicLink(
                    atPath: macOS.appendingPathComponent(service).path,
                    withDestinationPath: "\(service)-dist/\(service)"
                )
                let wrapperDirectory = resources.appendingPathComponent("LocalServices", isDirectory: true)
                try fileManager.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
                try "#!/bin/bash\nexit 0\n".write(
                    to: wrapperDirectory.appendingPathComponent("\(service)-wrapper.sh"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
        return BundleFixture(root: root, app: app, nestedExecutables: nestedExecutables)
    }

    private func copyExecutable(from source: URL, to destination: URL) throws {
        try fileManager.copyItem(at: source, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    private func makePackagingFixture(omittingService: String? = nil) throws -> PackagingFixture {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("dal-package-project-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let resources = project.appendingPathComponent("Dal/Resources", isDirectory: true)
        let sounds = resources.appendingPathComponent("Sounds", isDirectory: true)
        let binary = root.appendingPathComponent("Dal-fixture")
        let app = root.appendingPathComponent("output/Dal.app", isDirectory: true)

        try fileManager.createDirectory(at: sounds, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        try Data("icon".utf8).write(to: resources.appendingPathComponent("AppIcon.icns"))
        try Data("logo".utf8).write(to: resources.appendingPathComponent("BrandLogo.png"))
        try Data("sound".utf8).write(to: sounds.appendingPathComponent("start.wav"))
        try copyExecutable(from: URL(fileURLWithPath: "/usr/bin/true"), to: binary)

        var nestedExecutables: [URL] = []
        for service in ["sensevoice-server", "qwen3-asr-server"] {
            if service == omittingService {
                continue
            }
            let dist = project.appendingPathComponent("\(service)/dist/\(service)", isDirectory: true)
            try fileManager.createDirectory(at: dist, withIntermediateDirectories: true)

            for (name, permissions) in [(service, 0o755), ("nested-code.data", 0o644)] {
                let sourceFixture = dist.appendingPathComponent(name)
                try copyUnsignedMachO(to: sourceFixture, permissions: permissions)
                nestedExecutables.append(
                    app.appendingPathComponent("Contents/MacOS/\(service)-dist/\(name)")
                )
            }
        }

        return PackagingFixture(
            root: root,
            project: project,
            home: home,
            binary: binary,
            app: app,
            nestedExecutables: nestedExecutables
        )
    }

    private func copyUnsignedMachO(to destination: URL, permissions: Int) throws {
        try copyExecutable(from: URL(fileURLWithPath: "/usr/bin/true"), to: destination)
        let removal = try run(
            "/usr/bin/codesign",
            arguments: ["--remove-signature", destination.path]
        )
        guard removal.status == 0 else {
            throw NSError(
                domain: "PackageScriptTests",
                code: Int(removal.status),
                userInfo: [NSLocalizedDescriptionKey: removal.output]
            )
        }
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
    }

    private func runPackage(
        _ fixture: PackagingFixture,
        includesLocalServices: Bool,
        extraEnvironment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        var environment = [
            "APP_PATH": fixture.app.path,
            "BUNDLE_LOCAL_ASR": includesLocalServices ? "1" : "0",
            "CODESIGN_IDENTITY": "-",
            "HOME": fixture.home.path,
            "DAL_PACKAGE_BINARY": fixture.binary.path,
            "DAL_PACKAGE_PROJECT_DIR": fixture.project.path,
            "DAL_PACKAGE_TEST_MODE": "1"
        ]
        environment.merge(extraEnvironment) { _, new in new }
        return try run(
            "/bin/bash",
            arguments: [repositoryRoot.appendingPathComponent("scripts/package-app.sh").path],
            environment: environment
        )
    }

    private func runSigningPhase(
        for app: URL,
        extraEnvironment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        var environment = [
            "APP_BUNDLE_ID": "pro.daliang.muse",
            "APP_PATH": app.path,
            "SIGNING_IDENTITY": "-",
        ]
        environment.merge(extraEnvironment) { _, new in new }
        return try run(
            "/bin/bash",
            arguments: [repositoryRoot.appendingPathComponent("scripts/sign-app-bundle.sh").path, app.path],
            environment: environment
        )
    }

    private func runBundleValidation(
        for app: URL,
        expectsLocalServices: Bool
    ) throws -> (status: Int32, output: String) {
        try run(
            "/bin/bash",
            arguments: [repositoryRoot.appendingPathComponent("scripts/test_app_bundle.sh").path, app.path],
            environment: ["EXPECT_LOCAL_BUNDLE": expectsLocalServices ? "1" : "0"]
        )
    }

    private func strictVerification(of app: URL) throws -> (status: Int32, output: String) {
        try run(
            "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", "--verbose=4", app.path]
        )
    }

    private func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        var mergedEnvironment = ProcessInfo.processInfo.environment
        mergedEnvironment.merge(environment) { _, new in new }
        process.environment = mergedEnvironment

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

    private var infoPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDisplayName</key><string>Dal</string>
            <key>CFBundleExecutable</key><string>Dal</string>
            <key>CFBundleIconFile</key><string>AppIcon</string>
            <key>CFBundleIdentifier</key><string>pro.daliang.muse</string>
            <key>CFBundleName</key><string>Dal</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleShortVersionString</key><string>1.7.4</string>
            <key>CFBundleVersion</key><string>1</string>
            <key>LSMinimumSystemVersion</key><string>14.0</string>
            <key>NSMicrophoneUsageDescription</key><string>fixture</string>
            <key>NSAppleEventsUsageDescription</key><string>fixture</string>
            <key>LSUIElement</key><true/>
        </dict>
        </plist>
        """
    }
}
