import Foundation
import XCTest

final class DMGScriptTests: XCTestCase {
    func testBuildDMGScriptPassesBashSyntaxCheck() throws {
        let result = try run("/bin/bash", arguments: ["-n", scriptURL.path])
        XCTAssertEqual(result.status, 0, result.output)
    }

    func testBuildDMGScriptRequiresExplicitCloudOrLocalArtifact() throws {
        let source = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(source.contains(#"ARTIFACT_KIND="${ARTIFACT_KIND:-}""#))
        XCTAssertTrue(source.contains(#"cloud) BUNDLE_LOCAL_ASR=0"#))
        XCTAssertTrue(source.contains(#"local) BUNDLE_LOCAL_ASR=1"#))
        XCTAssertTrue(source.contains(#"Muse-v${APP_VERSION}-${ARTIFACT_KIND}.dmg"#))
        XCTAssertTrue(source.contains(#"EXPECT_LOCAL_BUNDLE="$BUNDLE_LOCAL_ASR""#))
        XCTAssertTrue(source.contains(#"CODESIGN_BIN="/usr/bin/codesign""#))
        XCTAssertTrue(source.contains(#""$CODESIGN_BIN" --verify --deep --strict --verbose=4"#))
        XCTAssertTrue(source.contains(#"HDIUTIL_BIN="/usr/bin/hdiutil""#))
        XCTAssertTrue(source.contains(#""$HDIUTIL_BIN" verify"#))
        XCTAssertTrue(source.contains(#"SHASUM_BIN="/usr/bin/shasum""#))
        XCTAssertTrue(source.contains(#""$SHASUM_BIN" -a 256"#))
        XCTAssertTrue(source.contains(#"MUSE_DMG_TEST_MODE"#))
        XCTAssertTrue(source.contains(#"ALLOW_ADHOC_DMG"#))
        XCTAssertTrue(source.contains(#"ALLOW_LOCAL_SIGNING"#))
        XCTAssertTrue(source.contains(#"Muse Local"#))
        XCTAssertTrue(source.contains(#"Developer ID Application"#))
        XCTAssertTrue(source.contains(#"TeamIdentifier"#))
        XCTAssertTrue(source.contains(#"PARTIAL_DMG"#))
        XCTAssertTrue(source.contains(#"UPDATE_READY"#))
        XCTAssertTrue(source.contains(#"/bin/chmod 755 "$STAGING_DIR""#))
        XCTAssertTrue(source.contains(#"APP_VERSION must be numeric dot-separated"#))
        XCTAssertTrue(source.contains(#"DMG_NAME must be a .dmg basename"#))
        XCTAssertTrue(source.contains(#""$PARTIAL_DMG""#), "hdiutil 必须先写入临时 DMG")
    }

    func testReleaseDMGRejectsMissingSigningIdentityBeforePackaging() throws {
        let result = try run(
            "/bin/bash",
            arguments: [scriptURL.path],
            environment: [
                "ARTIFACT_KIND": "cloud",
                "ALLOW_ADHOC_DMG": "0",
                "CODESIGN_IDENTITY": "",
            ]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("CODESIGN_IDENTITY"), result.output)
        XCTAssertFalse(result.output.contains("Creating verified DMG"), result.output)
    }

    func testDMGPathInputsFailClosedBeforePackaging() throws {
        for environment in [
            ["ARTIFACT_KIND": "cloud", "APP_VERSION": "../2.0.0", "ALLOW_ADHOC_DMG": "1"],
            ["ARTIFACT_KIND": "cloud", "DMG_NAME": "../Muse.dmg", "ALLOW_ADHOC_DMG": "1"],
        ] {
            let result = try run(
                "/bin/bash",
                arguments: [scriptURL.path],
                environment: environment
            )
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertFalse(result.output.contains("Creating verified DMG"), result.output)
        }
    }

    func testReleaseDMGSignsVerifiesHashesThenPublishes() throws {
        let fixture = try makeDynamicFixture()
        defer { trashDynamicFixture(fixture) }

        let result = try run(
            "/bin/bash",
            arguments: [fixture.scriptURL.path],
            environment: fixture.environment
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dmgURL.path), result.output)
        let lines = try String(contentsOf: fixture.toolLogURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let create = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("hdiutil:create ") })
        let sign = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("codesign:dmg-sign ") })
        let signatureVerify = try XCTUnwrap(
            lines.firstIndex { $0.hasPrefix("codesign:dmg-verify ") }
        )
        let imageVerify = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("hdiutil:verify ") })
        let checksum = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("shasum:") })
        let publish = try XCTUnwrap(lines.firstIndex {
            $0.hasPrefix("mv:") && $0.contains("destination=\(fixture.dmgURL.path)")
        }, lines.description)

        XCTAssertLessThan(create, sign, lines.description)
        XCTAssertLessThan(sign, signatureVerify, lines.description)
        XCTAssertLessThan(signatureVerify, imageVerify, lines.description)
        XCTAssertLessThan(imageVerify, checksum, lines.description)
        XCTAssertLessThan(checksum, publish, lines.description)
    }

    func testReleaseDMGVerificationFailureDoesNotPublishPartialArtifact() throws {
        let fixture = try makeDynamicFixture()
        defer { trashDynamicFixture(fixture) }
        var environment = fixture.environment
        environment["MUSE_TEST_FAIL_DMG_VERIFY"] = "1"

        let result = try run(
            "/bin/bash",
            arguments: [fixture.scriptURL.path],
            environment: environment
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.dmgURL.path), result.output)
        let log = try String(contentsOf: fixture.toolLogURL, encoding: .utf8)
        XCTAssertTrue(log.contains("hdiutil:verify"), log)
        XCTAssertFalse(log.contains("shasum:"), log)
        XCTAssertFalse(log.contains("destination=\(fixture.dmgURL.path)"), log)
    }

    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/build-dmg.sh")
    }

    private struct DynamicFixture {
        let rootURL: URL
        let scriptURL: URL
        let distURL: URL
        let dmgURL: URL
        let toolLogURL: URL
        let environment: [String: String]
    }

    private func makeDynamicFixture() throws -> DynamicFixture {
        let fileManager = FileManager.default
        let temporaryPath = fileManager.temporaryDirectory.path
        let canonicalTemporaryPath: String
        if temporaryPath.hasPrefix("/var/") || temporaryPath.hasPrefix("/tmp/") {
            canonicalTemporaryPath = "/private\(temporaryPath)"
        } else {
            canonicalTemporaryPath = temporaryPath
        }
        let rootURL = URL(fileURLWithPath: canonicalTemporaryPath, isDirectory: true)
            .appendingPathComponent("muse-dmg-script-\(UUID().uuidString)", isDirectory: true)
        let scriptsURL = rootURL.appendingPathComponent("scripts", isDirectory: true)
        let toolsURL = rootURL.appendingPathComponent("tools", isDirectory: true)
        let distURL = rootURL.appendingPathComponent("dist", isDirectory: true)
        let homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        let tempURL = rootURL.appendingPathComponent("temp", isDirectory: true)
        for directory in [
            scriptsURL,
            toolsURL,
            distURL,
            homeURL.appendingPathComponent(".Trash", isDirectory: true),
            tempURL,
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let canonicalDistURL = distURL

        let copiedScriptURL = scriptsURL.appendingPathComponent("build-dmg.sh")
        try String(contentsOf: scriptURL, encoding: .utf8)
            .write(to: copiedScriptURL, atomically: true, encoding: .utf8)
        try writeExecutable(Self.packageAppShim, to: scriptsURL.appendingPathComponent("package-app.sh"))
        try writeExecutable(
            Self.bundleTestShim,
            to: scriptsURL.appendingPathComponent("test_app_bundle.sh")
        )

        let codesignURL = toolsURL.appendingPathComponent("codesign")
        let hdiutilURL = toolsURL.appendingPathComponent("hdiutil")
        let shasumURL = toolsURL.appendingPathComponent("shasum")
        let mvURL = toolsURL.appendingPathComponent("mv")
        try writeExecutable(Self.codesignShim, to: codesignURL)
        try writeExecutable(Self.hdiutilShim, to: hdiutilURL)
        try writeExecutable(Self.shasumShim, to: shasumURL)
        try writeExecutable(Self.mvShim, to: mvURL)

        let toolLogURL = rootURL.appendingPathComponent("tool-order.log")
        try Data().write(to: toolLogURL)
        let version = "9.9.9"
        let dmgURL = canonicalDistURL.appendingPathComponent("Muse-v\(version)-cloud.dmg")
        let environment = [
            "ALLOW_ADHOC_DMG": "0",
            "APP_VERSION": version,
            "ARTIFACT_KIND": "cloud",
            "CODESIGN_IDENTITY": "Developer ID Application: Fixture (TEAM123456)",
            "DIST_DIR": canonicalDistURL.path,
            "HOME": homeURL.path,
            "MUSE_DMG_CODESIGN_BIN": codesignURL.path,
            "MUSE_DMG_HDIUTIL_BIN": hdiutilURL.path,
            "MUSE_DMG_MV_BIN": mvURL.path,
            "MUSE_DMG_SHASUM_BIN": shasumURL.path,
            "MUSE_DMG_TEST_MODE": "1",
            "MUSE_TEST_TOOL_LOG": toolLogURL.path,
            "TMPDIR": tempURL.path,
        ]
        return DynamicFixture(
            rootURL: rootURL,
            scriptURL: copiedScriptURL,
            distURL: distURL,
            dmgURL: dmgURL,
            toolLogURL: toolLogURL,
            environment: environment
        )
    }

    private func writeExecutable(_ source: String, to url: URL) throws {
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func trashDynamicFixture(_ fixture: DynamicFixture) {
        try? FileManager.default.trashItem(at: fixture.rootURL, resultingItemURL: nil)
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

    private static let packageAppShim = #"""
        #!/bin/bash
        set -euo pipefail
        /bin/mkdir -p "$APP_PATH/Contents"
        printf 'fixture app' > "$APP_PATH/Contents/payload.txt"
        """#

    private static let bundleTestShim = #"""
        #!/bin/bash
        set -euo pipefail
        [ -d "${1:-}/Contents" ]
        """#

    private static let codesignShim = #"""
        #!/bin/bash
        set -euo pipefail
        subject="${!#}"
        case " $* " in
            *" --force "*" --sign "*)
                printf 'codesign:dmg-sign %s\n' "$subject" >> "$MUSE_TEST_TOOL_LOG"
                ;;
            *" --verify "*)
                case "$subject" in
                    *.dmg) printf 'codesign:dmg-verify %s\n' "$subject" >> "$MUSE_TEST_TOOL_LOG" ;;
                    *) printf 'codesign:app-verify %s\n' "$subject" >> "$MUSE_TEST_TOOL_LOG" ;;
                esac
                ;;
            *" -dvvv "*)
                printf 'codesign:app-display %s\n' "$subject" >> "$MUSE_TEST_TOOL_LOG"
                printf 'Authority=Developer ID Application: Fixture\n' >&2
                printf 'flags=0x10000(runtime)\n' >&2
                printf 'TeamIdentifier=TEAM123456\n' >&2
                ;;
            *)
                echo "unexpected codesign invocation: $*" >&2
                exit 95
                ;;
        esac
        """#

    private static let hdiutilShim = #"""
        #!/bin/bash
        set -euo pipefail
        subject="${!#}"
        case "${1:-}" in
            create)
                printf 'hdiutil:create %s\n' "$subject" >> "$MUSE_TEST_TOOL_LOG"
                printf 'fixture dmg' > "$subject"
                ;;
            verify)
                printf 'hdiutil:verify %s\n' "$subject" >> "$MUSE_TEST_TOOL_LOG"
                [ "${MUSE_TEST_FAIL_DMG_VERIFY:-0}" != "1" ] || exit 96
                ;;
            *)
                echo "unexpected hdiutil invocation: $*" >&2
                exit 95
                ;;
        esac
        """#

    private static let shasumShim = #"""
        #!/bin/bash
        set -euo pipefail
        printf 'shasum:%s\n' "$*" >> "$MUSE_TEST_TOOL_LOG"
        exec /usr/bin/shasum "$@"
        """#

    private static let mvShim = #"""
        #!/bin/bash
        set -euo pipefail
        printf 'mv:source=%s destination=%s\n' "${1:-}" "${2:-}" >> "$MUSE_TEST_TOOL_LOG"
        exec /bin/mv "$@"
        """#
}
