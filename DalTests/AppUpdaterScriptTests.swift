import CryptoKit
import Foundation
import XCTest
@testable import Dal

/// DAL-180：更新器只能安装已签名的不可变双制品，并以同卷事务替换 App。
///
/// 所有安装场景均限制在 XCTest 临时目录。`ditto` shim 会记录参数后委托系统实现；
/// 不能在单元测试中安全执行的 hdiutil、codesign、open 通过显式测试模式注入 shim。
final class AppUpdaterScriptTests: XCTestCase {

    func testUpdaterScriptPassesBashSyntaxCheck() throws {
        let fixture = try makeFixture()
        defer { trashFixture(fixture) }

        let result = try runBash(arguments: ["-n", fixture.scriptURL.path])

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testUpdaterScriptUsesImmutableSignedArtifactTransaction() {
        let script = AppUpdater.updaterScriptForTesting

        XCTAssertFalse(script.contains("SIGNING_IDENTITY"), "更新器不得接收用户机器签名身份")
        XCTAssertFalse(script.contains("xattr"), "更新器不得修改新 App 的扩展属性")
        XCTAssertFalse(script.contains("TEMP_LOCAL"), "更新器不得保留旧 App 内 Local 组件")
        XCTAssertFalse(script.contains("SERVER_TEMP"), "更新器不得搬出或写回旧 App 内组件")
        XCTAssertFalse(script.localizedCaseInsensitiveContains("preserving local"))
        XCTAssertFalse(script.localizedCaseInsensitiveContains("restoring local"))

        for line in script.split(separator: "\n").map(String.init)
            where line.localizedCaseInsensitiveContains("codesign") || line.contains("$CODESIGN") {
            XCTAssertFalse(
                containsCodeSigningWriteFlag(line),
                "更新脚本不得执行 codesign 写操作：\(line)"
            )
        }

        XCTAssertTrue(script.contains("EXPECTED_SHA256"), "安装前必须重新校验 DMG SHA256")
        XCTAssertTrue(script.contains("TARGET_VERSION"), "安装前必须校验目标版本")
        XCTAssertTrue(script.contains("ARTIFACT_KIND"), "安装脚本必须绑定 Cloud/Local 制品类型")
        XCTAssertTrue(script.contains("DAL_UPDATER_TEST_MODE"), "工具注入必须受显式测试模式保护")
        XCTAssertTrue(script.contains("HDIUTIL"), "hdiutil 测试 shim 必须显式注入")
        XCTAssertTrue(script.contains("CODESIGN"), "codesign 测试 shim 必须显式注入")
        XCTAssertTrue(script.contains("OPEN"), "open 测试 shim 必须显式注入")
        XCTAssertTrue(script.contains("DAL_UPDATER_MV_BIN"), "mv 故障注入必须受显式测试模式保护")
        XCTAssertTrue(script.contains("READY_PATH"), "父 App 必须等更新器预检就绪后再退出")
        XCTAssertTrue(script.contains("updater-*.ready"), "ready marker 必须由父进程随机命名")
        XCTAssertFalse(script.contains("$STAGING_REAL/updater.ready"), "不得使用可预测的固定 ready marker")
        XCTAssertFalse(script.contains("exec >> \"$LOG\""), "Shell 不得按路径重新打开父进程已安全创建的日志")
        XCTAssertTrue(script.contains("ditto"), "新 App 必须先复制到同目录临时路径")
        XCTAssertTrue(
            script.contains("--verify --deep --strict"),
            "挂载、复制及正式路径均必须执行 strict 深度验签"
        )
        XCTAssertFalse(script.contains(#"-name "*.app""#), "不得选择 DMG 中第一个任意 .app")
        XCTAssertFalse(script.contains(#"-name '*.app'"#), "不得选择 DMG 中第一个任意 .app")
        XCTAssertTrue(script.contains("Dal.app"), "DMG 中只允许精确的 Dal.app")
    }

    func testDryRunMakesZeroFilesystemChanges() throws {
        let fixture = try makeFixture()
        defer { trashFixture(fixture) }
        let before = try filesystemSnapshot(at: fixture.root)

        let result = try runUpdater(fixture, dryRun: true)

        let after = try filesystemSnapshot(at: fixture.root)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("DRY_RUN"), result.output)
        XCTAssertEqual(after, before, "dry run 不得创建日志、备份、临时 App 或修改任何 fixture 文件")
    }

    func testUnsafeAppPathIsRejectedBeforeAnyFilesystemWrite() throws {
        let fixture = try makeFixture()
        defer { trashFixture(fixture) }
        let before = try filesystemSnapshot(at: fixture.root)

        let result = try runUpdater(fixture, appPath: "/", dryRun: true)

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.localizedCaseInsensitiveContains("unsafe"), result.output)
        XCTAssertEqual(try filesystemSnapshot(at: fixture.root), before)
    }

    func testBundleIdentifierMismatchLeavesCurrentAppAndDMGUntouched() throws {
        let fixture = try makeFixture()
        defer { trashFixture(fixture) }
        try writeInfoPlist(
            at: fixture.sourceAppURL,
            bundleIdentifier: "example.invalid.impostor",
            version: fixture.targetVersion
        )

        let result = try runUpdater(fixture)

        XCTAssertNotEqual(result.status, 0, result.output)
        try assertCurrentAppIsOriginal(fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dmgURL.path))
        XCTAssertTrue(result.output.localizedCaseInsensitiveContains("bundle"), result.output)
    }

    func testMetaCurrentAppIsRejectedWithoutOpeningOrModifyingIt() throws {
        for identifier in ["com.meta.endo", "com.facebook.hatch"] {
            let fixture = try makeFixture()
            defer { trashFixture(fixture) }
            try writeInfoPlist(at: fixture.currentAppURL, bundleIdentifier: identifier,
                               version: fixture.currentVersion)
            let before = try filesystemSnapshot(at: fixture.root)
            let result = try runUpdater(fixture)
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("does not belong to Dal"), result.output)
            XCTAssertEqual(try filesystemSnapshot(at: fixture.root), before)
        }
    }

    func testCandidateCannotRestoreOldBrandName() throws {
        let fixture = try makeFixture()
        defer { trashFixture(fixture) }
        let plistURL = fixture.sourceAppURL.appendingPathComponent("Contents/Info.plist")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        plist["CFBundleName"] = "Muse"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: plistURL)
        let result = try runUpdater(fixture)
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("product name must be Dal"), result.output)
        try assertCurrentAppIsOriginal(fixture)
    }

    func testSigningTeamMismatchLeavesCurrentAppAndDMGUntouched() throws {
        let fixture = try makeFixture()
        defer { trashFixture(fixture) }
        try writeTeam("DIFFERENT99", to: fixture.sourceAppURL)

        let result = try runUpdater(fixture)

        XCTAssertNotEqual(result.status, 0, result.output)
        try assertCurrentAppIsOriginal(fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dmgURL.path))
        XCTAssertTrue(result.output.localizedCaseInsensitiveContains("team"), result.output)
    }

    func testMountedSourceSignatureFailureLeavesCurrentAppUntouched() throws {
        let fixture = try makeFixture()
        defer { trashFixture(fixture) }

        let result = try runUpdater(fixture, failVerifyScope: "source")

        XCTAssertNotEqual(result.status, 0, result.output)
        try assertCurrentAppIsOriginal(fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dmgURL.path))
        XCTAssertTrue(result.output.split(separator: "\n").contains("ROLLBACK_OK"), result.output)
        XCTAssertTrue(result.output.split(separator: "\n").contains("FAILED"), result.output)
        let log = try toolLog(fixture)
        XCTAssertTrue(log.contains("scope=source"), log)
        XCTAssertFalse(log.contains("scope=copy"), log)
        XCTAssertTrue(log.contains("open:"), log)
    }

    func testEmptyCurrentSigningTeamIsRejected() throws {
        let fixture = try makeFixture()
        defer { trashFixture(fixture) }
        try writeTeam("", to: fixture.currentAppURL)

        let result = try runUpdater(fixture)

        XCTAssertNotEqual(result.status, 0, result.output)
        try assertCurrentAppIsOriginal(fixture)
        XCTAssertTrue(result.output.localizedCaseInsensitiveContains("team"), result.output)
        XCTAssertTrue(result.output.split(separator: "\n").contains("FAILED"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.readyURL.path), result.output)
        XCTAssertFalse(try toolLog(fixture).contains("open:"), result.output)
    }

    func testInvalidCurrentSignatureIsRejectedBeforeMount() throws {
        let fixture = try makeFixture()
        defer { trashFixture(fixture) }

        let result = try runUpdater(fixture, failVerifyScope: "current")

        XCTAssertNotEqual(result.status, 0, result.output)
        try assertCurrentAppIsOriginal(fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dmgURL.path))
        XCTAssertFalse(try toolLog(fixture).contains("hdiutil:attach"), result.output)
        XCTAssertTrue(result.output.split(separator: "\n").contains("ROLLBACK_FAILED"), result.output)
        XCTAssertTrue(result.output.split(separator: "\n").contains("FAILED"), result.output)
        XCTAssertFalse(try toolLog(fixture).contains("open:"), result.output)
    }

    func testEmptyNewSigningTeamIsRejected() throws {
        let fixture = try makeFixture()
        defer { trashFixture(fixture) }
        try writeTeam("", to: fixture.sourceAppURL)

        let result = try runUpdater(fixture)

        XCTAssertNotEqual(result.status, 0, result.output)
        try assertCurrentAppIsOriginal(fixture)
        XCTAssertTrue(result.output.localizedCaseInsensitiveContains("team"), result.output)
    }

    func testEqualOrLowerNewVersionIsRejected() throws {
        for targetVersion in ["2.0.0", "1.9.9"] {
            let fixture = try makeFixture(currentVersion: "2.0.0", targetVersion: targetVersion)
            defer { trashFixture(fixture) }

            let result = try runUpdater(fixture)

            XCTAssertNotEqual(result.status, 0, "target=\(targetVersion)\n\(result.output)")
            try assertCurrentAppIsOriginal(fixture, expectedVersion: "2.0.0")
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dmgURL.path))
            XCTAssertTrue(result.output.localizedCaseInsensitiveContains("version"), result.output)
        }
    }

    func testMultipleAppsInDMGInstallsOnlyExactDalApp() throws {
        let fixture = try makeFixture(decoyBeforeDal: true)
        defer { trashFixture(fixture) }

        let result = try runUpdater(fixture)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(try payload(in: fixture.currentAppURL), fixture.sourcePayload)
        XCTAssertNotEqual(try payload(in: fixture.currentAppURL), "decoy-payload")
    }

    func testDMGSHA256IsReverifiedBeforeMountOrInstall() throws {
        let fixture = try makeFixture()
        defer { trashFixture(fixture) }
        let expectedBeforeTampering = fixture.expectedSHA256
        try Data("tampered-after-download".utf8).write(to: fixture.dmgURL, options: .atomic)

        let result = try runUpdater(fixture, expectedSHA256: expectedBeforeTampering)

        XCTAssertNotEqual(result.status, 0, result.output)
        try assertCurrentAppIsOriginal(fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dmgURL.path))
        XCTAssertFalse(try toolLog(fixture).contains("hdiutil:attach"), "SHA 不匹配必须在挂载 DMG 前拒绝")
        XCTAssertTrue(result.output.localizedCaseInsensitiveContains("sha"), result.output)
        XCTAssertTrue(result.output.split(separator: "\n").contains("FAILED"), result.output)
    }

    func testDMGChangedAfterInitialHashIsRejectedBeforeAttach() throws {
        let fixture = try makeFixture()
        defer { trashFixture(fixture) }

        let result = try runUpdater(fixture, tamperDMGAfterInitialHash: true)

        XCTAssertNotEqual(result.status, 0, result.output)
        try assertCurrentAppIsOriginal(fixture)
        XCTAssertFalse(try toolLog(fixture).contains("hdiutil:attach"), result.output)
        XCTAssertTrue(result.output.contains("changed before mount"), result.output)
        XCTAssertTrue(result.output.split(separator: "\n").contains("FAILED"), result.output)
    }

    func testPostCopySignatureFailureLeavesOldAppAtOriginalPath() throws {
        let fixture = try makeFixture()
        defer { trashFixture(fixture) }

        let result = try runUpdater(fixture, failVerifyScope: "copy")

        XCTAssertNotEqual(result.status, 0, result.output)
        try assertCurrentAppIsOriginal(fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dmgURL.path))
        try assertNoTransactionAppsRemain(fixture)
        let log = try toolLog(fixture)
        XCTAssertTrue(log.contains("scope=copy"), log)
        XCTAssertTrue(result.output.split(separator: "\n").contains("ROLLBACK_OK"), result.output)
        XCTAssertTrue(result.output.split(separator: "\n").contains("FAILED"), result.output)
        XCTAssertTrue(log.contains("open:"), log)
        XCTAssertTrue(
            (try FileManager.default.contentsOfDirectory(atPath: fixture.stagingURL.path))
                .contains { $0.hasPrefix("failed-") },
            result.output
        )
    }

    func testFinalPathSignatureFailureRollsBackOriginalApp() throws {
        let fixture = try makeFixture()
        defer { trashFixture(fixture) }

        let result = try runUpdater(fixture, failVerifyScope: "formal")

        XCTAssertNotEqual(result.status, 0, result.output)
        try assertCurrentAppIsOriginal(fixture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dmgURL.path))
        try assertNoTransactionAppsRemain(fixture)
        let log = try toolLog(fixture)
        XCTAssertTrue(log.contains("scope=formal"), log)
        XCTAssertTrue(result.output.localizedCaseInsensitiveContains("rollback") ||
                      result.output.localizedCaseInsensitiveContains("rolled back"), result.output)
    }

    func testRollbackVerificationFailureIsReportedAndDoesNotReopenApp() throws {
        let fixture = try makeFixture()
        defer { trashFixture(fixture) }

        let result = try runUpdater(
            fixture,
            failVerifyScope: "formal",
            failRollbackVerify: true
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        try assertCurrentAppIsOriginal(fixture)
        XCTAssertTrue(result.output.split(separator: "\n").contains("ROLLBACK_FAILED"), result.output)
        XCTAssertTrue(result.output.split(separator: "\n").contains("FAILED"), result.output)
        let log = try toolLog(fixture)
        XCTAssertFalse(log.contains("open:"), log)
    }

    func testRenameAndCleanupPhaseFailuresRestoreOriginalApp() throws {
        for phase in ["old_to_backup", "temp_to_formal", "backup_to_trash", "dmg_to_trash"] {
            let fixture = try makeFixture()
            defer { trashFixture(fixture) }

            let result = try runUpdater(fixture, failMovePhase: phase)

            XCTAssertNotEqual(result.status, 0, "phase=\(phase)\n\(result.output)")
            try assertCurrentAppIsOriginal(fixture)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dmgURL.path), phase)
            XCTAssertTrue(result.output.split(separator: "\n").contains("ROLLBACK_OK"), result.output)
            XCTAssertTrue(result.output.split(separator: "\n").contains("FAILED"), result.output)
            try assertNoTransactionAppsRemain(fixture)
            let log = try toolLog(fixture)
            XCTAssertTrue(log.contains("mv:failed phase=\(phase)"), log)
            XCTAssertTrue(log.contains("open:"), log)
        }
    }

    func testTerminationSignalsTriggerRollbackAfterDestructiveMoves() throws {
        for phase in ["old_to_backup", "temp_to_formal"] {
            let fixture = try makeFixture()
            defer { trashFixture(fixture) }

            let result = try runUpdater(fixture, signalAfterMovePhase: phase)

            XCTAssertNotEqual(result.status, 0, "phase=\(phase)\n\(result.output)")
            try assertCurrentAppIsOriginal(fixture)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dmgURL.path), phase)
            XCTAssertTrue(result.output.split(separator: "\n").contains("ROLLBACK_OK"), result.output)
            XCTAssertTrue(result.output.split(separator: "\n").contains("FAILED"), result.output)
            XCTAssertTrue(try toolLog(fixture).contains("mv:signal phase=\(phase)"), result.output)
            try assertNoTransactionAppsRemain(fixture)
        }
    }

    func testSuccessfulCloudAndLocalUpdatesRemoveBackupAndOriginalDMG() throws {
        for kind in ArtifactKind.allCases {
            let fixture = try makeFixture(kind: kind)
            defer { trashFixture(fixture) }

            let sourceSnapshot = try filesystemSnapshot(at: fixture.sourceAppURL)
            let result = try runUpdater(fixture)

            XCTAssertEqual(result.status, 0, "kind=\(kind.rawValue)\n\(result.output)")
            XCTAssertEqual(try version(in: fixture.currentAppURL), fixture.targetVersion)
            XCTAssertEqual(try payload(in: fixture.currentAppURL), fixture.sourcePayload)
            XCTAssertEqual(
                try filesystemSnapshot(at: fixture.sourceAppURL),
                sourceSnapshot,
                "挂载卷中的签名制品不得被更新器修改"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.dmgURL.path))
            try assertNoTransactionAppsRemain(fixture)
            try assertInstalledArtifactMatchesKind(fixture)

            let stagingPaths = try FileManager.default.subpathsOfDirectory(
                atPath: fixture.stagingURL.path
            )
            XCTAssertFalse(stagingPaths.contains { $0.hasSuffix(".dmg") }, stagingPaths.description)
            XCTAssertFalse(stagingPaths.contains { $0.hasSuffix(".app") }, stagingPaths.description)

            let trashURL = fixture.homeURL.appendingPathComponent(".Trash", isDirectory: true)
            let trashPaths = try FileManager.default.subpathsOfDirectory(atPath: trashURL.path)
            XCTAssertTrue(trashPaths.contains { $0.hasSuffix(".dmg") }, trashPaths.description)
            XCTAssertTrue(trashPaths.contains { $0.hasSuffix(".app.disabled") }, trashPaths.description)
            let trashedItems = try FileManager.default.contentsOfDirectory(
                at: trashURL,
                includingPropertiesForKeys: nil
            )
            let trashedApp = try XCTUnwrap(trashedItems.first { $0.lastPathComponent.hasSuffix(".app.disabled") })
            let trashedDMG = try XCTUnwrap(trashedItems.first { $0.pathExtension == "dmg" })
            XCTAssertEqual(try version(in: trashedApp), fixture.currentVersion)
            XCTAssertEqual(try payload(in: trashedApp), "original-install")
            XCTAssertEqual(try sha256(of: trashedDMG), fixture.expectedSHA256)

            let log = try toolLog(fixture)
            let currentVerifyCount = log.split(separator: "\n").filter {
                $0.contains("codesign:verify scope=current")
            }.count
            XCTAssertEqual(currentVerifyCount, 2, log)
            XCTAssertTrue(log.contains("scope=source"), log)
            XCTAssertTrue(log.contains("scope=copy"), log)
            XCTAssertTrue(log.contains("scope=formal"), log)
            let dittoLines = log.split(separator: "\n").filter { $0.hasPrefix("ditto:") }
            XCTAssertEqual(dittoLines.count, 1, log)
            XCTAssertTrue(
                dittoLines[0].contains("source=\(fixture.sourceAppURL.path)"),
                log
            )
            XCTAssertTrue(
                dittoLines[0].contains("destination=\(fixture.applicationsURL.path)/.Dal-update-"),
                log
            )
            XCTAssertTrue(
                verifiedCopiedAppInInstalledVolume(log: log, fixture: fixture),
                "复制后验签必须发生在 APP_PATH 的同一目录/卷内：\n\(log)"
            )
        }
    }

    // MARK: - Fixture

    private enum ArtifactKind: String, CaseIterable {
        case cloud
        case local
    }

    private struct Fixture {
        let root: URL
        let applicationsURL: URL
        let stagingURL: URL
        let mountURL: URL
        let currentAppURL: URL
        let sourceAppURL: URL
        let dmgURL: URL
        let scriptURL: URL
        let readyURL: URL
        let hdiutilURL: URL
        let codesignURL: URL
        let dittoURL: URL
        let mvURL: URL
        let openURL: URL
        let toolLogURL: URL
        let homeURL: URL
        let tempURL: URL
        let kind: ArtifactKind
        let currentVersion: String
        let targetVersion: String
        let expectedSHA256: String
        let sourcePayload: String
    }

    private func makeFixture(
        kind: ArtifactKind = .cloud,
        currentVersion: String = "1.0.0",
        targetVersion: String = "2.0.0",
        decoyBeforeDal: Bool = false
    ) throws -> Fixture {
        let fm = FileManager.default
        // /var 在 macOS 上通常是 /private/var 的符号链接；生产脚本正确拒绝非 canonical
        // APP_PATH，因此 fixture 也必须从解析后的临时目录构造。
        let temporaryPath = fm.temporaryDirectory.path
        let canonicalTemporaryPath: String
        if temporaryPath.hasPrefix("/var/") {
            canonicalTemporaryPath = "/private\(temporaryPath)"
        } else if temporaryPath.hasPrefix("/tmp/") {
            canonicalTemporaryPath = "/private\(temporaryPath)"
        } else {
            canonicalTemporaryPath = temporaryPath
        }
        let root = URL(fileURLWithPath: canonicalTemporaryPath, isDirectory: true)
            .appendingPathComponent("dal-updater-\(UUID().uuidString)")
        let applicationsURL = root.appendingPathComponent("Installed Apps", isDirectory: true)
        let stagingURL = root.appendingPathComponent("Update Staging", isDirectory: true)
        let mountURL = root.appendingPathComponent("Mounted Volume", isDirectory: true)
        let toolsURL = root.appendingPathComponent("Test Tools", isDirectory: true)
        let homeURL = root.appendingPathComponent("Test Home", isDirectory: true)
        let tempURL = root.appendingPathComponent("Test Temp", isDirectory: true)
        let currentAppURL = applicationsURL.appendingPathComponent("Dal.app", isDirectory: true)
        let sourceAppURL = mountURL.appendingPathComponent("Dal.app", isDirectory: true)
        let dmgURL = stagingURL.appendingPathComponent("Dal-v\(targetVersion)-\(kind.rawValue).dmg")
        let scriptURL = root.appendingPathComponent("updater.sh")
        let readyURL = stagingURL
            .appendingPathComponent("updater-00000000-0000-4000-8000-000000000001.ready")
        let toolLogURL = root.appendingPathComponent("tool-invocations.log")
        let sourcePayload = "signed-\(kind.rawValue)-artifact"

        let trashURL = homeURL.appendingPathComponent(".Trash", isDirectory: true)
        for directory in [applicationsURL, stagingURL, mountURL, toolsURL, homeURL, trashURL, tempURL] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try createApp(
            at: currentAppURL,
            bundleIdentifier: Self.bundleIdentifier,
            version: currentVersion,
            team: Self.teamIdentifier,
            payload: "original-install",
            kind: kind,
            includeOldLocalComponents: kind == .local
        )

        if decoyBeforeDal {
            try createApp(
                at: mountURL.appendingPathComponent("000-Decoy.app", isDirectory: true),
                bundleIdentifier: Self.bundleIdentifier,
                version: targetVersion,
                team: Self.teamIdentifier,
                payload: "decoy-payload",
                kind: kind
            )
        }

        try createApp(
            at: sourceAppURL,
            bundleIdentifier: Self.bundleIdentifier,
            version: targetVersion,
            team: Self.teamIdentifier,
            payload: sourcePayload,
            kind: kind,
            includeNewLocalComponents: kind == .local
        )

        try Data("immutable-dmg-\(kind.rawValue)-\(targetVersion)".utf8)
            .write(to: dmgURL, options: .atomic)
        let expectedSHA256 = try sha256(of: dmgURL)

        try AppUpdater.updaterScriptForTesting.write(to: scriptURL, atomically: true, encoding: .utf8)
        try Data().write(to: toolLogURL)

        let hdiutilURL = toolsURL.appendingPathComponent("hdiutil")
        let codesignURL = toolsURL.appendingPathComponent("codesign")
        let dittoURL = toolsURL.appendingPathComponent("ditto")
        let mvURL = toolsURL.appendingPathComponent("mv")
        let openURL = toolsURL.appendingPathComponent("open")
        try writeExecutable(Self.hdiutilShim, to: hdiutilURL)
        try writeExecutable(Self.codesignShim, to: codesignURL)
        try writeExecutable(Self.dittoShim, to: dittoURL)
        try writeExecutable(Self.mvShim, to: mvURL)
        try writeExecutable(Self.openShim, to: openURL)

        return Fixture(
            root: root,
            applicationsURL: applicationsURL,
            stagingURL: stagingURL,
            mountURL: mountURL,
            currentAppURL: currentAppURL,
            sourceAppURL: sourceAppURL,
            dmgURL: dmgURL,
            scriptURL: scriptURL,
            readyURL: readyURL,
            hdiutilURL: hdiutilURL,
            codesignURL: codesignURL,
            dittoURL: dittoURL,
            mvURL: mvURL,
            openURL: openURL,
            toolLogURL: toolLogURL,
            homeURL: homeURL,
            tempURL: tempURL,
            kind: kind,
            currentVersion: currentVersion,
            targetVersion: targetVersion,
            expectedSHA256: expectedSHA256,
            sourcePayload: sourcePayload
        )
    }

    private func createApp(
        at appURL: URL,
        bundleIdentifier: String,
        version: String,
        team: String,
        payload: String,
        kind: ArtifactKind,
        includeOldLocalComponents: Bool = false,
        includeNewLocalComponents: Bool = false
    ) throws {
        let fm = FileManager.default
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try writeInfoPlist(at: appURL, bundleIdentifier: bundleIdentifier, version: version)
        try writeTeam(team, to: appURL)
        try payload.write(
            to: resourcesURL.appendingPathComponent("payload.txt"),
            atomically: true,
            encoding: .utf8
        )
        try kind.rawValue.write(
            to: resourcesURL.appendingPathComponent("artifact-kind.txt"),
            atomically: true,
            encoding: .utf8
        )

        if includeOldLocalComponents {
            let oldDist = macOSURL.appendingPathComponent("sensevoice-server-dist", isDirectory: true)
            let oldQwenDist = macOSURL.appendingPathComponent("qwen3-asr-server-dist", isDirectory: true)
            try fm.createDirectory(at: oldDist, withIntermediateDirectories: true)
            try fm.createDirectory(at: oldQwenDist, withIntermediateDirectories: true)
            try "must-not-survive".write(
                to: oldDist.appendingPathComponent("old-component.txt"),
                atomically: true,
                encoding: .utf8
            )
            try "must-not-survive".write(
                to: oldQwenDist.appendingPathComponent("old-component.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        if includeNewLocalComponents {
            let newDist = macOSURL.appendingPathComponent("sensevoice-server-dist", isDirectory: true)
            let newQwenDist = macOSURL.appendingPathComponent("qwen3-asr-server-dist", isDirectory: true)
            try fm.createDirectory(at: newDist, withIntermediateDirectories: true)
            try fm.createDirectory(at: newQwenDist, withIntermediateDirectories: true)
            try "from-new-artifact".write(
                to: newDist.appendingPathComponent("new-component.txt"),
                atomically: true,
                encoding: .utf8
            )
            try "from-new-artifact".write(
                to: newQwenDist.appendingPathComponent("new-component.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func writeInfoPlist(
        at appURL: URL,
        bundleIdentifier: String,
        version: String
    ) throws {
        let plist: [String: Any] = [
            "CFBundleExecutable": "Dal",
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "Dal",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(
            to: appURL.appendingPathComponent("Contents/Info.plist"),
            options: .atomic
        )
    }

    private func writeTeam(_ team: String, to appURL: URL) throws {
        try team.write(
            to: appURL.appendingPathComponent("Contents/.test-team-id"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeExecutable(_ source: String, to url: URL) throws {
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Script execution

    private func runUpdater(
        _ fixture: Fixture,
        appPath: String? = nil,
        expectedSHA256: String? = nil,
        dryRun: Bool = false,
        failVerifyScope: String = "",
        failRollbackVerify: Bool = false,
        tamperDMGAfterInitialHash: Bool = false,
        failMovePhase: String = "",
        signalAfterMovePhase: String = ""
    ) throws -> (status: Int32, output: String) {
        var environment: [String: String] = [
            "APP_PID": "2147483647",
            "APP_PATH": appPath ?? fixture.currentAppURL.path,
            "ARTIFACT_KIND": fixture.kind.rawValue,
            "CODESIGN": fixture.codesignURL.path,
            "DMG_PATH": fixture.dmgURL.path,
            "EXPECTED_SHA256": expectedSHA256 ?? fixture.expectedSHA256,
            "HDIUTIL": fixture.hdiutilURL.path,
            "HOME": fixture.homeURL.path,
            "IS_LOCAL": fixture.kind == .local ? "1" : "0",
            "LC_ALL": "C",
            "DAL_TEST_FAIL_VERIFY_SCOPE": failVerifyScope,
            "DAL_TEST_FAIL_MOVE_PHASE": failMovePhase,
            "DAL_TEST_SIGNAL_AFTER_MOVE_PHASE": signalAfterMovePhase,
            "DAL_TEST_FAIL_ROLLBACK_VERIFY": failRollbackVerify ? "1" : "0",
            "DAL_TEST_TAMPER_DMG_AFTER_INITIAL_HASH": tamperDMGAfterInitialHash ? "1" : "0",
            "DAL_TEST_MOUNT_POINT": fixture.mountURL.path,
            "DAL_TEST_TOOL_LOG": fixture.toolLogURL.path,
            "DAL_UPDATER_CODESIGN_BIN": fixture.codesignURL.path,
            "DAL_UPDATER_DITTO_BIN": fixture.dittoURL.path,
            "DAL_UPDATER_HDIUTIL_BIN": fixture.hdiutilURL.path,
            "DAL_UPDATER_MV_BIN": failMovePhase.isEmpty && signalAfterMovePhase.isEmpty
                ? "/bin/mv"
                : fixture.mvURL.path,
            "DAL_UPDATER_OPEN_BIN": fixture.openURL.path,
            "DAL_UPDATER_TEST_MODE": "1",
            "OPEN": fixture.openURL.path,
            "PATH": "\(fixture.hdiutilURL.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin",
            "SIGNING_IDENTITY": "-",
            "STAGING_DIR": fixture.stagingURL.path,
            "TARGET_VERSION": fixture.targetVersion,
            "READY_PATH": fixture.readyURL.path,
            "TRASH_DIR": fixture.homeURL.appendingPathComponent(".Trash", isDirectory: true).path,
            "TMPDIR": fixture.tempURL.path,
        ]
        if dryRun {
            environment["DAL_UPDATER_DRY_RUN"] = "1"
        }

        let processResult = try runBash(arguments: [fixture.scriptURL.path], environment: environment)
        let updateLogURL = fixture.stagingURL.appendingPathComponent("update.log")
        let updateLog = (try? String(contentsOf: updateLogURL, encoding: .utf8)) ?? ""
        return (processResult.status, processResult.output + updateLog)
    }

    private func runBash(
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        if let environment {
            process.environment = environment
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

    // MARK: - Assertions

    private func assertCurrentAppIsOriginal(
        _ fixture: Fixture,
        expectedVersion: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.currentAppURL.path),
            file: file,
            line: line
        )
        XCTAssertEqual(
            try version(in: fixture.currentAppURL),
            expectedVersion ?? fixture.currentVersion,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try payload(in: fixture.currentAppURL),
            "original-install",
            file: file,
            line: line
        )
    }

    private func assertNoTransactionAppsRemain(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let installedChildren = try FileManager.default.contentsOfDirectory(
            at: fixture.applicationsURL,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        XCTAssertEqual(installedChildren, ["Dal.app"], file: file, line: line)

        let stagingApps = try FileManager.default.contentsOfDirectory(
            at: fixture.stagingURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "app" || $0.lastPathComponent.localizedCaseInsensitiveContains("backup") }
        XCTAssertTrue(stagingApps.isEmpty, "残留事务 App：\(stagingApps)", file: file, line: line)
    }

    private func assertInstalledArtifactMatchesKind(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let resources = fixture.currentAppURL.appendingPathComponent("Contents/Resources")
        let installedKind = try String(
            contentsOf: resources.appendingPathComponent("artifact-kind.txt"),
            encoding: .utf8
        )
        XCTAssertEqual(installedKind, fixture.kind.rawValue, file: file, line: line)

        let macOS = fixture.currentAppURL.appendingPathComponent("Contents/MacOS")
        let oldComponent = macOS.appendingPathComponent("sensevoice-server-dist/old-component.txt")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldComponent.path),
            "旧 App 内组件不得写回新制品",
            file: file,
            line: line
        )

        let newComponent = macOS.appendingPathComponent("sensevoice-server-dist/new-component.txt")
        XCTAssertEqual(
            FileManager.default.fileExists(atPath: newComponent.path),
            fixture.kind == .local,
            file: file,
            line: line
        )
    }

    private func verifiedCopiedAppInInstalledVolume(log: String, fixture: Fixture) -> Bool {
        log.split(separator: "\n").contains { rawLine in
            let line = String(rawLine)
            return line.contains("codesign:verify") &&
                line.contains("scope=copy") &&
                line.contains(fixture.applicationsURL.path)
        }
    }

    private func containsCodeSigningWriteFlag(_ line: String) -> Bool {
        let tokens = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
        return tokens.contains("--sign") || tokens.contains("--force") || tokens.contains { token in
            guard token.hasPrefix("-"), !token.hasPrefix("--") else { return false }
            let shortFlags = token.dropFirst()
            return shortFlags.contains("s") || shortFlags.contains("f")
        }
    }

    // MARK: - Fixture inspection

    private func version(in appURL: URL) throws -> String {
        let data = try Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        return try XCTUnwrap(plist["CFBundleShortVersionString"] as? String)
    }

    private func payload(in appURL: URL) throws -> String {
        try String(
            contentsOf: appURL.appendingPathComponent("Contents/Resources/payload.txt"),
            encoding: .utf8
        )
    }

    private func toolLog(_ fixture: Fixture) throws -> String {
        try String(contentsOf: fixture.toolLogURL, encoding: .utf8)
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func filesystemSnapshot(at root: URL) throws -> [String: String] {
        let fm = FileManager.default
        let relativePaths = try fm.subpathsOfDirectory(atPath: root.path).sorted()
        return try Dictionary(uniqueKeysWithValues: relativePaths.map { relativePath in
            let url = root.appendingPathComponent(relativePath)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let value: String
            switch type {
            case .typeDirectory:
                value = "directory|\(permissions)"
            case .typeSymbolicLink:
                value = "symlink|\(permissions)|\(try fm.destinationOfSymbolicLink(atPath: url.path))"
            default:
                value = "file|\(permissions)|\(try Data(contentsOf: url).base64EncodedString())"
            }
            return (relativePath, value)
        })
    }

    private func trashFixture(_ fixture: Fixture) {
        try? FileManager.default.trashItem(at: fixture.root, resultingItemURL: nil)
    }

    // MARK: - Tool shims

    private static let bundleIdentifier = "pro.daliang.muse"
    private static let teamIdentifier = "TEAM123456"

    private static let hdiutilShim = #"""
        #!/bin/bash
        set -euo pipefail
        printf 'hdiutil:%s\n' "$*" >> "$DAL_TEST_TOOL_LOG"
        case "${1:-}" in
            attach)
                printf '/dev/disk99\tApple_HFS\t%s\n' "$DAL_TEST_MOUNT_POINT"
                ;;
            detach)
                exit 0
                ;;
            *)
                echo "unsupported hdiutil invocation: $*" >&2
                exit 64
                ;;
        esac
        """#

    private static let codesignShim = #"""
        #!/bin/bash
        set -euo pipefail

        verify=0
        display=0
        deep=0
        strict=0
        for argument in "$@"; do
            case "$argument" in
                --verify) verify=1 ;;
                --deep) deep=1 ;;
                --strict) strict=1 ;;
                -d|-dv|-dvv|-dvvv|--display) display=1 ;;
                --sign|-s|--force|-f)
                    echo "codesign write operation is forbidden" >&2
                    exit 86
                    ;;
            esac
        done

        subject="${!#}"
        if [ "$verify" = "1" ]; then
            if [ "$deep" != "1" ] || [ "$strict" != "1" ]; then
                echo "strict deep signature verification is required" >&2
                exit 87
            fi
            scope="copy"
            case "$subject" in
                "$DAL_TEST_MOUNT_POINT"/*)
                    scope="source"
                    ;;
                "$APP_PATH")
                    installed_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$subject/Contents/Info.plist" 2>/dev/null || true)
                    if [ "$installed_version" = "$TARGET_VERSION" ]; then
                        scope="formal"
                    else
                        scope="current"
                    fi
                    ;;
            esac
            printf 'codesign:verify scope=%s path=%s\n' "$scope" "$subject" >> "$DAL_TEST_TOOL_LOG"
            if [ "$scope" = "current" ]; then
                current_verify_count=$(grep -c 'codesign:verify scope=current' "$DAL_TEST_TOOL_LOG" || true)
                if [ "${DAL_TEST_TAMPER_DMG_AFTER_INITIAL_HASH:-0}" = "1" ] &&
                   [ "$current_verify_count" -eq 2 ]; then
                    printf 'tampered-between-hashes' >> "$DMG_PATH"
                fi
                if [ "${DAL_TEST_FAIL_ROLLBACK_VERIFY:-0}" = "1" ] &&
                   [ "$current_verify_count" -ge 3 ]; then
                    echo "test restored signature verification failed" >&2
                    exit 91
                fi
            fi
            if [ -e "$subject/Contents/.test-signature-invalid" ] ||
               [ "${DAL_TEST_FAIL_VERIFY_SCOPE:-}" = "$scope" ]; then
                echo "test signature verification failed: scope=$scope" >&2
                exit 90
            fi
            exit 0
        fi

        if [ "$display" = "1" ]; then
            printf 'codesign:display path=%s\n' "$subject" >> "$DAL_TEST_TOOL_LOG"
            team_file="$subject/Contents/.test-team-id"
            if [ -f "$team_file" ]; then
                team=$(tr -d '\r\n' < "$team_file")
                if [ -n "$team" ]; then
                    printf 'TeamIdentifier=%s\n' "$team" >&2
                fi
            fi
            identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$subject/Contents/Info.plist" 2>/dev/null || true)
            if [ -n "$identifier" ]; then
                printf 'Identifier=%s\n' "$identifier" >&2
            fi
            exit 0
        fi

        echo "unsupported codesign invocation: $*" >&2
        exit 64
        """#

    private static let openShim = #"""
        #!/bin/bash
        set -euo pipefail
        printf 'open:%s\n' "$*" >> "$DAL_TEST_TOOL_LOG"
        exit 0
        """#

    private static let dittoShim = #"""
        #!/bin/bash
        set -euo pipefail
        [ "$#" -eq 2 ] || {
            echo "ditto requires exact source and destination arguments" >&2
            exit 93
        }
        printf 'ditto:source=%s destination=%s\n' "$1" "$2" >> "$DAL_TEST_TOOL_LOG"
        exec /usr/bin/ditto "$@"
        """#

    private static let mvShim = #"""
        #!/bin/bash
        set -euo pipefail
        source_path="${1:-}"
        destination_path="${2:-}"
        app_parent=$(/usr/bin/dirname "$APP_PATH")
        phase="other"
        case "$source_path|$destination_path" in
            "$APP_PATH|$app_parent"/.Dal-backup-*.app)
                phase="old_to_backup"
                ;;
            "$app_parent"/.Dal-update-*.app"|$APP_PATH")
                phase="temp_to_formal"
                ;;
            "$app_parent"/.Dal-backup-*.app"|$TRASH_DIR"/*)
                phase="backup_to_trash"
                ;;
            "$DMG_PATH|$TRASH_DIR"/*)
                phase="dmg_to_trash"
                ;;
        esac
        printf 'mv:phase=%s source=%s destination=%s\n' "$phase" "$source_path" "$destination_path" >> "$DAL_TEST_TOOL_LOG"
        if [ "${DAL_TEST_FAIL_MOVE_PHASE:-}" = "$phase" ]; then
            printf 'mv:failed phase=%s\n' "$phase" >> "$DAL_TEST_TOOL_LOG"
            exit 92
        fi
        /bin/mv "$@"
        if [ "${DAL_TEST_SIGNAL_AFTER_MOVE_PHASE:-}" = "$phase" ]; then
            printf 'mv:signal phase=%s\n' "$phase" >> "$DAL_TEST_TOOL_LOG"
            /bin/kill -TERM "$PPID"
            /bin/sleep 0.1
        fi
        """#
}
