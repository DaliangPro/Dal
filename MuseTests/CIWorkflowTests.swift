import Foundation
import XCTest

final class CIWorkflowTests: XCTestCase {
    func testCIWorkflowIsValidYAMLAndRunsEveryCoreGate() throws {
        let source = try workflowSource("ci.yml")
        try assertValidYAML(at: workflowURL("ci.yml"))

        XCTAssertTrue(source.contains(#""on":"#), source)
        XCTAssertTrue(source.contains("push:"), source)
        XCTAssertTrue(source.contains("pull_request:"), source)
        XCTAssertTrue(source.contains("runs-on: macos-26"), source)
        XCTAssertTrue(source.contains("permissions:\n  contents: read"), source)
        XCTAssertTrue(source.contains("persist-credentials: false"), source)
        XCTAssertFalse(source.contains("continue-on-error"), source)

        for command in [
            "swift build",
            "swift build -c release",
            "swift test",
            "bash scripts/health-check.sh",
            "bash -n scripts/*.sh",
            "python3 -m py_compile sensevoice-server/server.py",
            "python3 -m py_compile qwen3-asr-server/server.py",
        ] {
            XCTAssertTrue(source.contains("run: \(command)"), "CI 缺少核心命令：\(command)\n\(source)")
        }
    }

    func testCIWorkflowPreparesOnlyTheMinimalPinnedPythonTestEnvironment() throws {
        let source = try workflowSource("ci.yml")

        for dependency in [
            "fastapi==0.136.3",
            "httpx==0.28.1",
            "numpy==2.4.6",
            "uvicorn==0.49.0",
        ] {
            XCTAssertTrue(source.contains(dependency), "缺少固定 CI 依赖：\(dependency)")
        }
        XCTAssertTrue(source.contains("python3 -m venv"), source)
        XCTAssertTrue(source.contains("GITHUB_PATH"), source)
        XCTAssertFalse(source.contains("requirements.txt"), "CI 不应安装完整模型依赖")
    }

    func testWorkflowsPinSwift62AndRejectUnexpectedToolchains() throws {
        for name in ["ci.yml", "release-verify.yml"] {
            let source = try workflowSource(name)

            XCTAssertTrue(
                source.contains("DEVELOPER_DIR: /Applications/Xcode_26.2.app/Contents/Developer"),
                "\(name) 必须固定 Xcode 26.2 / Swift 6.2"
            )
            XCTAssertTrue(
                source.contains("swift --version | grep -F 'Apple Swift version 6.2'"),
                "\(name) 必须在执行构建前硬校验 Swift 6.2"
            )
        }
    }

    func testSwiftLintUsesStrictScopedBaselineWithoutLenientBypass() throws {
        let ci = try workflowSource("ci.yml")
        let health = try source(at: "scripts/health-check.sh")
        let config = try source(at: ".swiftlint.yml")
        let baselineURL = repositoryRoot.appendingPathComponent(".swiftlint-baseline.json")

        XCTAssertTrue(config.contains("included:\n  - Muse\n  - MuseTests"), config)
        XCTAssertTrue(config.contains("baseline: .swiftlint-baseline.json"), config)
        XCTAssertTrue(config.contains("check_for_updates: false"), config)
        XCTAssertTrue(FileManager.default.fileExists(atPath: baselineURL.path))
        let baselineData = try Data(contentsOf: baselineURL)
        XCTAssertGreaterThan(baselineData.count, 2)
        let baselineSource = try XCTUnwrap(String(data: baselineData, encoding: .utf8))
        XCTAssertFalse(baselineSource.contains("file://"), "SwiftLint 基线不得绑定本机 URL")
        XCTAssertFalse(baselineSource.contains("/Users/"), "SwiftLint 基线不得绑定本机绝对路径")
        let baseline = try XCTUnwrap(
            JSONSerialization.jsonObject(with: baselineData) as? [[String: Any]]
        )
        for entry in baseline {
            let violation = try XCTUnwrap(entry["violation"] as? [String: Any])
            let location = try XCTUnwrap(violation["location"] as? [String: Any])
            let file = try XCTUnwrap(location["file"] as? String)
            XCTAssertTrue(
                file.hasPrefix("Muse/") || file.hasPrefix("MuseTests/"),
                "SwiftLint 基线路径必须相对仓库根目录：\(file)"
            )
        }

        for source in [ci, health] {
            XCTAssertTrue(
                source.contains("swiftlint lint --strict --config .swiftlint.yml"),
                source
            )
            XCTAssertFalse(source.contains("--lenient"), source)
            XCTAssertFalse(source.contains("|| true"), source)
        }
    }

    func testStaticToolsAreInstalledAndRequiredInCI() throws {
        let source = try workflowSource("ci.yml")

        XCTAssertTrue(source.contains("MUSE_REQUIRE_STATIC_TOOLS: \"1\""), source)
        XCTAssertTrue(source.contains("brew install shellcheck swiftlint"), source)
        XCTAssertTrue(source.contains("brew tap peripheryapp/periphery"), source)
        XCTAssertTrue(source.contains("shellcheck scripts/*.sh"), source)
        XCTAssertTrue(source.contains("swiftlint lint --strict --config .swiftlint.yml"), source)
        XCTAssertTrue(source.contains("periphery scan --disable-update-check"), source)
        XCTAssertTrue(source.contains("local-service-boundary:"), source)
        XCTAssertTrue(source.contains("python3 -m unittest discover -s local-service-shared"), source)
        XCTAssertFalse(source.contains("|| true"), source)
        XCTAssertFalse(source.contains("continue-on-error"), source)
    }

    func testWorkflowsPinAllActionsToImmutableCommitSHAs() throws {
        let allowedActions = [
            "actions/checkout",
            "actions/upload-artifact",
            "actions/download-artifact",
            "astral-sh/setup-uv",
        ]
        for name in ["ci.yml", "release-verify.yml"] {
            let source = try workflowSource(name)
            let actionLines = source.split(separator: "\n").filter { $0.contains("uses:") }
            XCTAssertFalse(actionLines.isEmpty, "\(name) 应使用官方 action")
            for line in actionLines {
                XCTAssertTrue(
                    allowedActions.contains { line.contains("uses: \($0)@") },
                    "Action 不在允许列表：\(line)"
                )
                XCTAssertNotNil(
                    line.range(
                        of: #"uses:\s+(?:actions/[A-Za-z0-9_-]+|astral-sh/setup-uv)@[0-9a-f]{40}(?:\s+#.*)?$"#,
                        options: .regularExpression
                    ),
                    "Action 必须固定到完整 commit SHA：\(line)"
                )
            }
        }
    }

    func testReleaseWorkflowBuildsAndRevalidatesBothProductsBeforePublishing() throws {
        let source = try workflowSource("release-verify.yml")
        try assertValidYAML(at: workflowURL("release-verify.yml"))

        XCTAssertTrue(source.contains("workflow_dispatch:"), source)
        XCTAssertTrue(source.contains("runs-on: macos-26"), source)
        XCTAssertTrue(source.contains("environment: release-signing"), source)
        XCTAssertTrue(source.contains("bash scripts/verify-release-environments.sh"), source)
        XCTAssertTrue(source.contains("bash scripts/verify-release-artifact.sh"), source)
        XCTAssertTrue(source.contains("bash scripts/verify-release-version.sh"), source)
        XCTAssertTrue(source.contains("uses: astral-sh/setup-uv@"), source)
        XCTAssertTrue(source.contains(#"version: "0.11.30""#), source)
        XCTAssertTrue(source.contains("bash scripts/build-sensevoice-server.sh"), source)
        XCTAssertTrue(source.contains("bash scripts/build-qwen3-asr-server.sh"), source)
        XCTAssertTrue(source.contains("bash scripts/run-signed-release-build.sh"), source)
        XCTAssertTrue(source.contains("APPLE_NOTARY_KEY_P8_BASE64"), source)
        XCTAssertTrue(source.contains("APPLE_NOTARY_KEY_ID"), source)
        XCTAssertTrue(source.contains("APPLE_NOTARY_ISSUER_ID"), source)
        XCTAssertTrue(source.contains("RELEASE_VERIFY_MODE: build"), source)
        XCTAssertTrue(source.contains("group: muse-release\n  queue: max\n  cancel-in-progress: false"), source)
        XCTAssertEqual(
            source.components(separatedBy: "bash scripts/verify-release-version.sh").count - 1,
            2,
            "发布前后必须各检查一次线上最高版本"
        )

        let qwenBuild = try XCTUnwrap(source.range(of: "bash scripts/build-qwen3-asr-server.sh"))
        let certificateImport = try XCTUnwrap(source.range(of: "bash scripts/run-signed-release-build.sh"))
        XCTAssertLessThan(qwenBuild.lowerBound, certificateImport.lowerBound)

        let upload = try XCTUnwrap(source.range(of: "actions/upload-artifact@"))
        let firstVerification = certificateImport
        XCTAssertLessThan(firstVerification.lowerBound, upload.lowerBound)
        XCTAssertTrue(source.contains("id: release_artifact"), source)
        XCTAssertTrue(source.contains("release_artifact_id:"), source)
        XCTAssertTrue(source.contains("release_artifact_digest:"), source)

        XCTAssertTrue(source.contains("needs: verify-release"), source)
        XCTAssertTrue(source.contains("environment: release"), source)
        XCTAssertTrue(source.contains("contents: write"), source)
        XCTAssertTrue(source.contains("RELEASE_VERIFY_MODE: verify"), source)
        XCTAssertTrue(source.contains("inputs.publish"), source)
        XCTAssertTrue(source.contains("inputs.manual_gate_confirmed"), source)

        let download = try XCTUnwrap(source.range(of: "actions/download-artifact@"))
        XCTAssertTrue(source.contains("artifact-ids:"), source)
        let secondVerification = try XCTUnwrap(
            source.range(of: "bash scripts/release-verify.sh", range: download.upperBound..<source.endIndex)
        )
        let release = try XCTUnwrap(source.range(of: "gh release create"))
        let finalVersionCheck = try XCTUnwrap(
            source.range(
                of: "bash scripts/verify-release-version.sh",
                range: secondVerification.upperBound..<source.endIndex
            )
        )
        XCTAssertLessThan(download.lowerBound, secondVerification.lowerBound)
        XCTAssertLessThan(secondVerification.lowerBound, finalVersionCheck.lowerBound)
        XCTAssertLessThan(finalVersionCheck.lowerBound, release.lowerBound)
        XCTAssertEqual(source.components(separatedBy: "gh release create").count - 1, 1)
        let remoteDownload = try XCTUnwrap(source.range(of: "gh release download"))
        let remoteVerification = try XCTUnwrap(
            source.range(of: "bash scripts/release-verify.sh", range: remoteDownload.upperBound..<source.endIndex)
        )
        let publication = try XCTUnwrap(source.range(of: "gh release edit"))
        XCTAssertLessThan(release.lowerBound, remoteDownload.lowerBound)
        XCTAssertLessThan(remoteDownload.lowerBound, remoteVerification.lowerBound)
        XCTAssertLessThan(remoteVerification.lowerBound, publication.lowerBound)
        XCTAssertTrue(source.contains("--draft"), source)
        XCTAssertTrue(source.contains("gh release delete"), source)
    }

    func testReleaseWorkflowUsesLeastPrivilegeAndKeepsManualDeviceGates() throws {
        let source = try workflowSource("release-verify.yml")

        XCTAssertTrue(source.contains("permissions:\n  contents: read"), source)
        XCTAssertEqual(source.components(separatedBy: "contents: write").count - 1, 1, source)
        XCTAssertFalse(source.contains("pull_request_target"), source)
        XCTAssertFalse(source.contains("continue-on-error"), source)
        XCTAssertTrue(source.contains("GITHUB_STEP_SUMMARY"), source)

        for gate in [
            "TextEdit AX",
            "微信 clipboard",
            "Electron",
            "nonactivatingPanel",
            "Apple Speech",
            "火山断网和重连",
            "SenseVoice 与 Qwen final",
            "Cloud 旧版更新",
            "Local 旧版更新",
            "更新失败回滚",
        ] {
            XCTAssertTrue(source.contains(gate), "缺少手动 gate：\(gate)")
        }
    }

    func testFrozenServiceBuildsUsePinnedDependenciesAndRecoverableCleanup() throws {
        for (scriptPath, lockPath) in [
            ("scripts/build-sensevoice-server.sh", "sensevoice-server/requirements.lock.txt"),
            ("scripts/build-qwen3-asr-server.sh", "qwen3-asr-server/requirements.lock.txt"),
        ] {
            let scriptSource = try source(at: scriptPath)
            let lock = try source(at: lockPath)

            XCTAssertTrue(
                scriptSource.contains(#"REQUIREMENTS_FILE="requirements.lock.txt""#),
                scriptSource
            )
            XCTAssertFalse(
                scriptSource.contains(#"REQUIREMENTS_FILE="requirements.txt""#),
                scriptSource
            )
            XCTAssertTrue(
                scriptSource.contains(#"uv pip install -q -r "$REQUIREMENTS_FILE""#),
                scriptSource
            )
            XCTAssertFalse(scriptSource.contains("rm -rf"), scriptSource)
            for dependency in [
                "altgraph==0.17.5",
                "macholib==1.16.4",
                "packaging==26.2",
                "pyinstaller==6.21.0",
                "pyinstaller-hooks-contrib==2026.6",
                "setuptools==81.0.0",
            ] {
                XCTAssertTrue(lock.contains(dependency), "\(lockPath) 缺少固定依赖：\(dependency)")
            }
        }
    }

    func testSigningKeyIsOpenedOnlyForOfflinePackagingAndAlwaysCleanedUp() throws {
        let wrapperSource = try source(at: "scripts/run-signed-release-build.sh")
        let workflow = try workflowSource("release-verify.yml")
        let packageSource = try source(at: "scripts/package-app.sh")
        let prebuildSource = try source(at: "scripts/prepare-release-binary.sh")

        XCTAssertTrue(wrapperSource.contains("trap cleanup_signing EXIT"), wrapperSource)
        XCTAssertTrue(wrapperSource.contains("trap 'exit 129' HUP"), wrapperSource)
        XCTAssertTrue(wrapperSource.contains("trap 'exit 130' INT"), wrapperSource)
        XCTAssertTrue(wrapperSource.contains("trap 'exit 143' TERM"), wrapperSource)
        XCTAssertTrue(wrapperSource.contains("security import"), wrapperSource)
        XCTAssertTrue(wrapperSource.contains("bash \"$SCRIPT_DIR/release-verify.sh\""), wrapperSource)
        XCTAssertTrue(wrapperSource.contains("security lock-keychain"), wrapperSource)
        XCTAssertTrue(wrapperSource.contains("trash_path \"$CERTIFICATE_PATH\""), wrapperSource)
        XCTAssertTrue(wrapperSource.contains("trash_path \"$KEYCHAIN_PATH\""), wrapperSource)
        XCTAssertTrue(wrapperSource.contains("MUSE_PACKAGE_REQUIRE_PREBUILT=1"), wrapperSource)
        XCTAssertTrue(wrapperSource.contains("MUSE_PACKAGE_PREBUILT_BINARY"), wrapperSource)
        XCTAssertTrue(wrapperSource.contains("MUSE_PACKAGE_PREBUILT_SHA256"), wrapperSource)
        XCTAssertTrue(wrapperSource.contains("APPLE_NOTARY_KEY_P8_BASE64"), wrapperSource)
        XCTAssertTrue(wrapperSource.contains("NOTARY_KEY_PATH"), wrapperSource)
        XCTAssertTrue(wrapperSource.contains("trash_path \"$NOTARY_KEY_PATH\""), wrapperSource)
        XCTAssertFalse(wrapperSource.contains("swift build"), wrapperSource)
        XCTAssertTrue(wrapperSource.contains("umask 022"), wrapperSource)

        let prebuild = try XCTUnwrap(workflow.range(of: "bash scripts/prepare-release-binary.sh"))
        let signedPackaging = try XCTUnwrap(workflow.range(of: "bash scripts/run-signed-release-build.sh"))
        XCTAssertLessThan(prebuild.lowerBound, signedPackaging.lowerBound)
        XCTAssertTrue(prebuildSource.contains("swift build"), prebuildSource)
        XCTAssertTrue(packageSource.contains("MUSE_PACKAGE_REQUIRE_PREBUILT"), packageSource)
        XCTAssertTrue(packageSource.contains("MUSE_PACKAGE_PREBUILT_SHA256"), packageSource)
        for networkCommand in ["brew ", "curl ", "uv ", "pip "] {
            XCTAssertFalse(wrapperSource.contains(networkCommand), "签名窗口禁止联网依赖命令：\(networkCommand)")
        }
    }

    func testHealthCheckEnforcesCIReleaseFilesAndDisabledUpdateChannel() throws {
        let health = try source(at: "scripts/health-check.sh")
        let updateChecker = try source(at: "Muse/Services/UpdateChecker.swift")

        XCTAssertTrue(health.contains("ci_release_policy"), health)
        XCTAssertTrue(health.contains(#"run_step "ci-release-policy" ci_release_policy"#), health)
        for path in [
            ".github/workflows/ci.yml",
            ".github/workflows/release-verify.yml",
            "scripts/release-verify.sh",
            "scripts/notarize-release-artifacts.sh",
            "scripts/prepare-release-binary.sh",
            "scripts/run-signed-release-build.sh",
            "scripts/verify-release-artifact.sh",
            "scripts/verify-release-environments.sh",
            "scripts/verify-release-version.sh",
            ".swiftlint.yml",
            ".swiftlint-baseline.json",
            "MuseTests/CIWorkflowTests.swift",
            "MuseTests/ReleaseVerifyScriptTests.swift",
        ] {
            XCTAssertTrue(health.contains(path), "健康检查未锁定：\(path)")
        }
        XCTAssertTrue(updateChecker.contains("static let updateChannelEnabled = false"))
        XCTAssertFalse(updateChecker.contains("static let updateChannelEnabled = true"))
    }

    func testHealthCheckValidatesVoicePolishQualityAssets() throws {
        let health = try source(at: "scripts/health-check.sh")
        let evaluator = try source(at: "scripts/evaluate-voice-polish-quality-report.py")

        for path in [
            "scripts/build-voice-polish-quality-test-set-v2.py",
            "scripts/validate-voice-polish-quality-test-set.py",
            "scripts/evaluate-voice-polish-quality-report.py",
        ] {
            XCTAssertTrue(health.contains(#"pathlib.Path("\#(path)")"#), health)
        }
        XCTAssertTrue(
            health.contains(
                #"run_step "voice-polish-quality-test-set" python3 scripts/validate-voice-polish-quality-test-set.py"#
            ),
            health
        )
        XCTAssertTrue(evaluator.contains("subprocess.Popen(["), evaluator)
        XCTAssertTrue(evaluator.contains("报告路径已存在，必须使用新的空路径"), evaluator)
        XCTAssertTrue(evaluator.contains(#"report.get("schema_version") != 4"#), evaluator)
        XCTAssertTrue(evaluator.contains(#"report.get("run_nonce") != expected_run_nonce"#), evaluator)
        XCTAssertTrue(evaluator.contains(#"report.get("process_id") != expected_process_id"#), evaluator)
        XCTAssertTrue(evaluator.contains("llm_call_count < 1"), evaluator)
        XCTAssertTrue(evaluator.contains("latency < 1"), evaluator)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func workflowURL(_ name: String) -> URL {
        repositoryRoot.appendingPathComponent(".github/workflows/\(name)")
    }

    private func workflowSource(_ name: String) throws -> String {
        try String(contentsOf: workflowURL(name), encoding: .utf8)
    }

    private func source(at relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func assertValidYAML(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [
            "-e",
            "require 'yaml'; YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)",
            url.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "\(url.lastPathComponent): \(output)")
    }
}
