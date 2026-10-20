import AppKit
import CommonCrypto
import Darwin
import os

// MARK: - App Updater

@Observable @MainActor
final class AppUpdater {

    enum State: Equatable {
        case idle
        case downloading(progress: Double)
        case verifying
        case readyToInstall
        case installing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var downloadedVersion: String?

    /// Detected once at init
    let isLocalInstallation: Bool

    private let logger = Logger(subsystem: "pro.daliang.muse", category: "AppUpdater")
    private var downloadSession: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var resumeData: Data?
    private var currentRelease: UpdateInfo?
    private var currentArtifact: ResolvedUpdateArtifact?

    // MARK: - Directories

    private var stagingDir: URL {
        AppPaths.support("Updates", isDirectory: true)
    }

    private var updateLogURL: URL { stagingDir.appendingPathComponent("update.log") }

    // MARK: - Init

    init() {
        let macosURL = Bundle.main.executableURL?.deletingLastPathComponent()
        isLocalInstallation = FileManager.default.fileExists(
            atPath: macosURL?.appendingPathComponent("sensevoice-server-dist").path ?? ""
        )
    }

    // MARK: - Public API

    func downloadUpdate(release: UpdateInfo) {
        switch state {
        case .idle, .failed: break
        default: return
        }

        let artifact: ResolvedUpdateArtifact
        do {
            artifact = try release.resolvedArtifact(isLocalInstallation: isLocalInstallation)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        currentRelease = release
        currentArtifact = artifact
        downloadedVersion = release.version

        // Ensure staging directory
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            state = .failed(L("无法创建更新目录: \(error.localizedDescription)",
                              "Failed to create update directory: \(error.localizedDescription)"))
            return
        }

        startDownload(artifact: artifact, release: release)
    }

    func cancelDownload() {
        downloadTask?.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor [weak self] in
                self?.resumeData = data
            }
        })
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        downloadTask = nil
        state = .idle
    }

    func retryDownload() {
        guard let release = currentRelease, let artifact = currentArtifact else { return }
        state = .idle
        if resumeData != nil {
            startDownload(artifact: artifact, release: release)
        } else {
            downloadUpdate(release: release)
        }
    }

    func installAndRestart() {
        guard case .readyToInstall = state else { return }
        guard let version = downloadedVersion else { return }

        state = .installing
        guard let artifact = currentArtifact else {
            state = .failed(L("更新制品信息不存在", "Update artifact information is missing"))
            return
        }
        let dmgPath = dmgPath(for: version, kind: artifact.kind)

        guard FileManager.default.fileExists(atPath: dmgPath.path) else {
            state = .failed(L("下载文件不存在", "Downloaded file not found"))
            return
        }

        guard let trashDirectory = FileManager.default.urls(
            for: .trashDirectory,
            in: .userDomainMask
        ).first else {
            state = .failed(L("无法定位废纸篓，更新已取消", "Unable to locate Trash; update cancelled"))
            return
        }

        let scriptURL = stagingDir.appendingPathComponent("updater.sh")
        let updaterReadyURL = Self.makeUpdaterReadyURL(in: stagingDir)

        do {
            try Self.updaterScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
            )
        } catch {
            state = .failed(L("无法生成更新脚本: \(error.localizedDescription)",
                              "Failed to generate update script: \(error.localizedDescription)"))
            return
        }

        // Kill ASR servers before quitting
        SenseVoiceServerManager.killAllServerProcesses()

        // Launch updater script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.environment = [
            "APP_PID": "\(ProcessInfo.processInfo.processIdentifier)",
            "APP_PATH": Bundle.main.bundlePath,
            "ARTIFACT_KIND": artifact.kind.rawValue,
            "DMG_PATH": dmgPath.path,
            "EXPECTED_SHA256": artifact.sha256,
            "READY_PATH": updaterReadyURL.path,
            "STAGING_DIR": stagingDir.path,
            "TARGET_VERSION": version,
            "TRASH_DIR": trashDirectory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        process.qualityOfService = .utility

        var logHandle: FileHandle?
        do {
            if Self.isSymbolicLink(updaterReadyURL) {
                throw CocoaError(
                    .fileWriteInvalidFileName,
                    userInfo: [NSFilePathErrorKey: updaterReadyURL.path]
                )
            }
            if FileManager.default.fileExists(atPath: updaterReadyURL.path) {
                try FileManager.default.trashItem(at: updaterReadyURL, resultingItemURL: nil)
            }
            logHandle = try Self.configureUpdaterProcessLogging(
                process,
                logURL: updateLogURL
            )
            try process.run()
            try logHandle?.close()
            logHandle = nil
            logger.info("Updater script launched, PID=\(process.processIdentifier)")
        } catch {
            try? logHandle?.close()
            state = .failed(L("无法启动更新脚本: \(error.localizedDescription)",
                              "Failed to launch update script: \(error.localizedDescription)"))
            return
        }

        // 更新器完成当前 App、制品与事务路径预检后才允许父进程退出。
        // 若更新器在 ready 前失败，保留当前进程与诊断日志，避免用户陷入无 App 可用的状态。
        let readyURL = updaterReadyURL
        Task { @MainActor [weak self] in
            let ready = await Self.waitForUpdaterReady(
                process: process,
                readyURL: readyURL,
                attempts: 1_200,
                pollNanoseconds: 100_000_000
            )
            if ready {
                self?.logger.info("Updater preflight completed; terminating parent app")
                NSApplication.shared.terminate(nil)
                return
            }

            if process.isRunning {
                process.terminate()
            }
            guard let self else { return }
            let log = (try? String(contentsOf: self.updateLogURL, encoding: .utf8)) ?? ""
            self.state = .failed(Self.postUpdateFailureSummary(log))
            self.logger.error("Updater exited or timed out before ready; parent app remains running")
        }
    }

    nonisolated private static func configureUpdaterProcessLogging(
        _ process: Process,
        logURL: URL
    ) throws -> FileHandle {
        let fileManager = FileManager.default
        if isSymbolicLink(logURL) {
            throw CocoaError(
                .fileWriteInvalidFileName,
                userInfo: [NSFilePathErrorKey: logURL.path]
            )
        }
        if fileManager.fileExists(atPath: logURL.path) {
            try fileManager.trashItem(at: logURL, resultingItemURL: nil)
        }
        let descriptor = logURL.path.withCString { path in
            Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        process.standardOutput = handle
        process.standardError = handle
        return handle
    }

    nonisolated private static func isSymbolicLink(_ url: URL) -> Bool {
        var fileStatus = stat()
        guard url.path.withCString({ Darwin.lstat($0, &fileStatus) }) == 0 else {
            return false
        }
        return (fileStatus.st_mode & S_IFMT) == S_IFLNK
    }

    nonisolated private static func makeUpdaterReadyURL(in stagingURL: URL) -> URL {
        stagingURL.appendingPathComponent("updater-\(UUID().uuidString).ready", isDirectory: true)
    }

    nonisolated static func updaterReadyURLForTesting(in stagingURL: URL) -> URL {
        makeUpdaterReadyURL(in: stagingURL)
    }

    nonisolated static func configureUpdaterProcessLoggingForTesting(
        _ process: Process,
        logURL: URL
    ) throws -> FileHandle {
        try configureUpdaterProcessLogging(process, logURL: logURL)
    }

    private static func waitForUpdaterReady(
        process: Process,
        readyURL: URL,
        attempts: Int,
        pollNanoseconds: UInt64
    ) async -> Bool {
        for _ in 0..<attempts {
            if !process.isRunning {
                return false
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: readyURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue, !isSymbolicLink(readyURL) {
                return true
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return false
    }

    static func waitForUpdaterReadyForTesting(
        process: Process,
        readyURL: URL,
        attempts: Int,
        pollNanoseconds: UInt64
    ) async -> Bool {
        await waitForUpdaterReady(
            process: process,
            readyURL: readyURL,
            attempts: attempts,
            pollNanoseconds: pollNanoseconds
        )
    }

    /// Check post-update status on launch (called from AppDelegate).
    func checkPostUpdateStatus() {
        guard FileManager.default.fileExists(atPath: updateLogURL.path) else { return }
        guard let log = try? String(contentsOf: updateLogURL, encoding: .utf8) else { return }
        if Self.postUpdateTerminalStatus(log) == "SUCCESS" {
            logger.info("Post-update check: update succeeded")
            cleanupStaging()
        } else {
            let summary = Self.postUpdateFailureSummary(log)
            state = .failed(summary)
            logger.error("Post-update check: update failed or incomplete; log retained")

            let rollbackSucceeded = log
                .split(separator: "\n", omittingEmptySubsequences: true)
                .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "ROLLBACK_OK" }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = rollbackSucceeded
                ? L("Dal 更新失败，原版本已保留或恢复", "Dal update failed; the previous version was kept or restored")
                : L("Dal 更新未完成，需要手动检查", "Dal update did not complete and needs manual review")
            alert.informativeText = L(
                "\(summary)\n\n诊断日志已保留在 Updates/update.log。",
                "\(summary)\n\nThe diagnostic log remains at Updates/update.log."
            )
            alert.addButton(withTitle: L("好", "OK"))
            alert.runModal()
        }
    }

    nonisolated private static func postUpdateTerminalStatus(_ log: String) -> String? {
        log.split(separator: "\n", omittingEmptySubsequences: true)
            .reversed()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0 == "SUCCESS" || $0 == "FAILED" }
    }

    nonisolated private static func postUpdateFailureSummary(_ log: String) -> String {
        let errorLine = log
            .split(separator: "\n", omittingEmptySubsequences: true)
            .reversed()
            .first { $0.contains("ERROR:") }
            .map(String.init)
        let raw = errorLine?
            .replacingOccurrences(of: "ERROR:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "更新事务未完成，请查看诊断日志确认当前安装状态。"
        let summary = raw.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        return String(summary.prefix(240))
    }

    nonisolated static func postUpdateFailureSummaryForTesting(_ log: String) -> String {
        postUpdateFailureSummary(log)
    }

    nonisolated static func postUpdateTerminalStatusForTesting(_ log: String) -> String? {
        postUpdateTerminalStatus(log)
    }

    func reset() {
        state = .idle
        downloadedVersion = nil
        currentRelease = nil
        currentArtifact = nil
        resumeData = nil
    }

    // MARK: - Download

    private func dmgPath(for version: String, kind: UpdateArtifactKind) -> URL {
        stagingDir.appendingPathComponent("Dal-v\(version)-\(kind.rawValue).dmg")
    }

    private func startDownload(artifact: ResolvedUpdateArtifact, release: UpdateInfo) {
        state = .downloading(progress: 0)

        let delegate = UpdateDownloadDelegate(
            onProgress: { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.state = .downloading(progress: fraction)
                }
            },
            onComplete: { [weak self] fileURL, _, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // REPAIR_PLAN J9：下载生命周期终点统一回收会话——URLSession 强持
                    // delegate 直到 invalidate，此前成功路径从不回收，每次下载泄漏一对
                    // session+delegate（用户主动取消由 cancelDownload 的 invalidateAndCancel 负责，
                    // 届时 downloadSession 已为 nil，这里的空调用无害）。
                    self.downloadSession?.finishTasksAndInvalidate()
                    self.downloadSession = nil
                    self.downloadTask = nil
                    if let error {
                        self.handleDownloadError(error)
                        return
                    }
                    guard let fileURL else {
                        self.state = .failed(L("下载失败", "Download failed"))
                        return
                    }
                    self.finalizeDownload(tempURL: fileURL, release: release, artifact: artifact)
                }
            }
        )

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.downloadSession = session

        if let resumeData {
            self.resumeData = nil
            downloadTask = session.downloadTask(withResumeData: resumeData)
        } else {
            downloadTask = session.downloadTask(with: artifact.url)
        }
        downloadTask?.resume()
    }

    private func handleDownloadError(_ error: Error) {
        let nsError = error as NSError
        // Capture resume data for retry
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            resumeData = data
        }
        // Also check underlying error
        if resumeData == nil,
           let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           let data = underlying.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            resumeData = data
        }

        if nsError.code == NSURLErrorCancelled { return } // User cancelled
        let hasResume = resumeData != nil
        let msg = hasResume
            ? L("下载中断，可以继续", "Download interrupted, can resume")
            : L("下载失败: \(error.localizedDescription)", "Download failed: \(error.localizedDescription)")
        state = .failed(msg)
    }

    private func finalizeDownload(
        tempURL: URL,
        release: UpdateInfo,
        artifact: ResolvedUpdateArtifact
    ) {
        let destination = dmgPath(for: release.version, kind: artifact.kind)

        // Move downloaded file to staging
        if FileManager.default.fileExists(atPath: destination.path) {
            do {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            } catch {
                state = .failed(L("无法回收旧下载文件: \(error.localizedDescription)",
                                  "Failed to move the previous download to Trash: \(error.localizedDescription)"))
                return
            }
        }
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            state = .failed(L("无法保存下载文件: \(error.localizedDescription)",
                              "Failed to save download: \(error.localizedDescription)"))
            return
        }

        // SHA256 verification（REPAIR_PLAN A2：缺校验值一律拒绝安装，不允许静默跳过）
        state = .verifying
        guard Self.isChecksumAcceptable(
            expected: artifact.sha256,
            actual: sha256(fileAt: destination)
        ) else {
            try? FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            state = .failed(L("文件校验失败，请重新下载", "File verification failed, please retry"))
            return
        }

        resumeData = nil
        state = .readyToInstall
    }

    /// 校验闸门：期望值缺失、实际值缺失或不匹配，一律不通过（REPAIR_PLAN A2）
    nonisolated static func isChecksumAcceptable(expected: String?, actual: String?) -> Bool {
        guard let expected, !expected.isEmpty,
              let actual, !actual.isEmpty else { return false }
        return expected.lowercased() == actual.lowercased()
    }

    // MARK: - SHA256

    private func sha256(fileAt url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                CC_SHA256_Update(&context, buffer, CC_LONG(read))
            }
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Updater Script

    /// 纯常量脚本：下载制品保持不可变，只通过同目录临时 App 和 rename 事务安装。
    private nonisolated static let updaterScript = """
        #!/bin/bash
        set -euo pipefail

        die() {
            echo "ERROR: $*" >&2
            exit 1
        }

        require_env() {
            local name="$1"
            local value="${!name:-}"
            [ -n "$value" ] || die "$name is required"
        }

        require_absolute_path() {
            local name="$1"
            local value="$2"
            case "$value" in
                /*) ;;
                *) die "$name must be an absolute path: $value" ;;
            esac
        }

        reject_dangerous_root() {
            local name="$1"
            local value="$2"
            case "$value" in
                "/"|"/Applications"|"/Users"|"${HOME:-__dal_no_home__}"|"/tmp"|"/private/tmp")
                    die "$name points at an unsafe root: $value"
                    ;;
            esac
        }

        require_env APP_PID
        require_env APP_PATH
        require_env DMG_PATH
        require_env STAGING_DIR
        require_env EXPECTED_SHA256
        require_env READY_PATH
        require_env TARGET_VERSION
        require_env ARTIFACT_KIND
        require_env TRASH_DIR

        require_absolute_path STAGING_DIR "$STAGING_DIR"
        require_absolute_path APP_PATH "$APP_PATH"
        require_absolute_path DMG_PATH "$DMG_PATH"
        require_absolute_path READY_PATH "$READY_PATH"
        require_absolute_path TRASH_DIR "$TRASH_DIR"
        reject_dangerous_root STAGING_DIR "$STAGING_DIR"
        reject_dangerous_root APP_PATH "$APP_PATH"
        reject_dangerous_root DMG_PATH "$DMG_PATH"
        reject_dangerous_root READY_PATH "$READY_PATH"
        reject_dangerous_root TRASH_DIR "$TRASH_DIR"

        case "$APP_PID" in
            ''|*[!0-9]*) die "APP_PID must be numeric: $APP_PID" ;;
        esac
        case "$APP_PATH" in
            *.app) ;;
            *) die "APP_PATH must point to an .app bundle: $APP_PATH" ;;
        esac
        [ -d "$APP_PATH/Contents" ] || die "APP_PATH is not an app bundle: $APP_PATH"
        [ ! -L "$APP_PATH" ] || die "APP_PATH must not be a symbolic link"
        [ -d "$STAGING_DIR" ] || die "STAGING_DIR does not exist: $STAGING_DIR"
        [ ! -L "$STAGING_DIR" ] || die "STAGING_DIR must not be a symbolic link"
        [ -f "$DMG_PATH" ] || die "DMG_PATH is not a regular file: $DMG_PATH"
        [ ! -L "$DMG_PATH" ] || die "DMG_PATH must not be a symbolic link"
        [ -d "$TRASH_DIR" ] || die "TRASH_DIR does not exist: $TRASH_DIR"
        [ ! -L "$TRASH_DIR" ] || die "TRASH_DIR must not be a symbolic link"

        APP_BASENAME="$(/usr/bin/basename "$APP_PATH")"
        APP_PARENT="$(cd "$(/usr/bin/dirname "$APP_PATH")" && /bin/pwd -P)"
        [ "$APP_PATH" = "$APP_PARENT/$APP_BASENAME" ] || die "APP_PATH must be canonical"
        STAGING_REAL="$(cd "$STAGING_DIR" && /bin/pwd -P)"
        [ "$STAGING_DIR" = "$STAGING_REAL" ] || die "STAGING_DIR must be canonical"
        TRASH_REAL="$(cd "$TRASH_DIR" && /bin/pwd -P)"
        [ "$TRASH_DIR" = "$TRASH_REAL" ] || die "TRASH_DIR must be canonical"
        DMG_PARENT="$(cd "$(/usr/bin/dirname "$DMG_PATH")" && /bin/pwd -P)"
        [ "$DMG_PARENT" = "$STAGING_REAL" ] || die "DMG_PATH must be a direct child of STAGING_DIR"
        READY_PARENT="$(cd "$(/usr/bin/dirname "$READY_PATH")" && /bin/pwd -P)"
        [ "$READY_PARENT" = "$STAGING_REAL" ] \
            || die "READY_PATH must be a direct child of STAGING_DIR"
        READY_NAME="$(/usr/bin/basename "$READY_PATH")"
        case "$READY_PATH" in
            "$STAGING_REAL"/updater-*.ready) ;;
            *) die "READY_PATH must be a randomized updater marker inside STAGING_DIR" ;;
        esac
        READY_TOKEN="${READY_NAME#updater-}"
        READY_TOKEN="${READY_TOKEN%.ready}"
        [ "${#READY_TOKEN}" -eq 36 ] \
            || die "READY_PATH token must be a UUID"
        case "$READY_TOKEN" in
            *[!0-9A-Fa-f-]*) die "READY_PATH token must be a UUID" ;;
        esac
        [ ! -e "$READY_PATH" ] && [ ! -L "$READY_PATH" ] \
            || die "READY_PATH already exists: $READY_PATH"
        case "$DMG_PATH" in
            "$STAGING_REAL"/*.dmg) ;;
            *) die "DMG_PATH must be a .dmg inside STAGING_DIR: $DMG_PATH" ;;
        esac
        case "$ARTIFACT_KIND" in
            cloud|local) ;;
            *) die "ARTIFACT_KIND must be cloud or local: $ARTIFACT_KIND" ;;
        esac
        case "$TARGET_VERSION" in
            ''|.*|*.|*..*|*[!0-9.]*) die "TARGET_VERSION must be numeric dot-separated: $TARGET_VERSION" ;;
        esac
        if [ "${#EXPECTED_SHA256}" -ne 64 ]; then
            die "EXPECTED_SHA256 must contain 64 hexadecimal characters"
        fi
        case "$EXPECTED_SHA256" in
            *[!0-9A-Fa-f]*) die "EXPECTED_SHA256 must contain 64 hexadecimal characters" ;;
        esac

        HDIUTIL_BIN="/usr/bin/hdiutil"
        CODESIGN_BIN="/usr/bin/codesign"
        OPEN_BIN="/usr/bin/open"
        DITTO_BIN="/usr/bin/ditto"
        MV_BIN="/bin/mv"
        if [ "${DAL_UPDATER_TEST_MODE:-0}" = "1" ]; then
            HDIUTIL_BIN="${DAL_UPDATER_HDIUTIL_BIN:-$HDIUTIL_BIN}"
            CODESIGN_BIN="${DAL_UPDATER_CODESIGN_BIN:-$CODESIGN_BIN}"
            OPEN_BIN="${DAL_UPDATER_OPEN_BIN:-$OPEN_BIN}"
            DITTO_BIN="${DAL_UPDATER_DITTO_BIN:-$DITTO_BIN}"
            MV_BIN="${DAL_UPDATER_MV_BIN:-$MV_BIN}"
            [ -x "$HDIUTIL_BIN" ] || die "test hdiutil shim is not executable"
            [ -x "$CODESIGN_BIN" ] || die "test codesign shim is not executable"
            [ -x "$OPEN_BIN" ] || die "test open shim is not executable"
            [ -x "$DITTO_BIN" ] || die "test ditto shim is not executable"
            [ -x "$MV_BIN" ] || die "test mv shim is not executable"
        fi

        if [ "${DAL_UPDATER_DRY_RUN:-0}" = "1" ]; then
            echo "DRY_RUN: updater environment validated"
            exit 0
        fi

        echo "Dal updater started at $(/bin/date)"

        TX_ID="${APP_PID}-$(/usr/bin/uuidgen)"
        TEMP_APP="$APP_PARENT/.Dal-update-$TX_ID.app"
        BACKUP_PATH="$APP_PARENT/.Dal-backup-$TX_ID.app"
        FAILED_SIBLING="$APP_PARENT/.Dal-failed-$TX_ID.app"
        FAILED_DIR="$STAGING_REAL/failed-$TX_ID"
        FAILED_APP="$FAILED_DIR/candidate-bundle"
        TRASHED_BACKUP="$TRASH_REAL/Dal-backup-$TX_ID.app.disabled"
        TRASHED_DMG="$TRASH_REAL/Dal-update-$TX_ID.dmg"
        [ ! -e "$TEMP_APP" ] && [ ! -L "$TEMP_APP" ] \
            || die "temporary app path already exists: $TEMP_APP"
        [ ! -e "$BACKUP_PATH" ] && [ ! -L "$BACKUP_PATH" ] \
            || die "backup app path already exists: $BACKUP_PATH"
        [ ! -e "$FAILED_SIBLING" ] && [ ! -L "$FAILED_SIBLING" ] \
            || die "failed app sibling already exists: $FAILED_SIBLING"
        [ ! -e "$FAILED_DIR" ] && [ ! -L "$FAILED_DIR" ] \
            || die "failed app path already exists: $FAILED_DIR"
        [ ! -e "$TRASHED_BACKUP" ] && [ ! -L "$TRASHED_BACKUP" ] \
            || die "trash backup path already exists: $TRASHED_BACKUP"
        [ ! -e "$TRASHED_DMG" ] && [ ! -L "$TRASHED_DMG" ] \
            || die "trash DMG path already exists: $TRASHED_DMG"

        is_numeric_version() {
            case "$1" in
                ''|.*|*.|*..*|*[!0-9.]*) return 1 ;;
                *) return 0 ;;
            esac
        }

        version_is_greater() {
            local candidate="$1"
            local current="$2"
            local old_ifs="$IFS"
            local i candidate_part current_part count
            local -a candidate_parts current_parts
            IFS='.' read -r -a candidate_parts <<< "$candidate"
            IFS='.' read -r -a current_parts <<< "$current"
            IFS="$old_ifs"
            count="${#candidate_parts[@]}"
            if [ "${#current_parts[@]}" -gt "$count" ]; then
                count="${#current_parts[@]}"
            fi
            i=0
            while [ "$i" -lt "$count" ]; do
                candidate_part="${candidate_parts[$i]:-0}"
                current_part="${current_parts[$i]:-0}"
                if [ "$candidate_part" -gt "$current_part" ]; then
                    return 0
                fi
                if [ "$candidate_part" -lt "$current_part" ]; then
                    return 1
                fi
                i=$((i + 1))
            done
            return 1
        }

        plist_value() {
            local app="$1"
            local key="$2"
            /usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist" 2>/dev/null
        }

        team_identifier() {
            local app="$1"
            local details
            details="$("$CODESIGN_BIN" -dvvv "$app" 2>&1)" || return 1
            echo "$details" | /usr/bin/awk -F= '/^TeamIdentifier=/ {print $2; exit}'
        }

        validate_artifact_shape() {
            local app="$1"
            if [ "$ARTIFACT_KIND" = "local" ]; then
                [ -d "$app/Contents/MacOS/sensevoice-server-dist" ] || die "Local artifact is missing sensevoice-server-dist"
                [ -d "$app/Contents/MacOS/qwen3-asr-server-dist" ] || die "Local artifact is missing qwen3-asr-server-dist"
            else
                [ ! -e "$app/Contents/MacOS/sensevoice-server-dist" ] || die "Cloud artifact contains sensevoice-server-dist"
                [ ! -e "$app/Contents/MacOS/qwen3-asr-server-dist" ] || die "Cloud artifact contains qwen3-asr-server-dist"
            fi
        }

        validate_candidate() {
            local app="$1"
            local phase="$2"
            local candidate_bundle candidate_version candidate_team
            [ -d "$app/Contents" ] || die "$phase is not an app bundle"
            [ ! -L "$app" ] || die "$phase must not be a symbolic link"
            "$CODESIGN_BIN" --verify --deep --strict --verbose=4 "$app" \
                || die "$phase strict signature verification failed"
            candidate_bundle="$(plist_value "$app" CFBundleIdentifier)"
            candidate_version="$(plist_value "$app" CFBundleShortVersionString)"
            candidate_team="$(team_identifier "$app")" || die "unable to read $phase TeamIdentifier"
            [ "$candidate_bundle" = "$CURRENT_BUNDLE_ID" ] \
                || die "bundle id mismatch: current=$CURRENT_BUNDLE_ID candidate=$candidate_bundle"
            if [ -z "$candidate_team" ] || [ "$candidate_team" = "not set" ]; then
                die "$phase has no TeamIdentifier"
            fi
            [ "$candidate_team" = "$CURRENT_TEAM" ] \
                || die "signing team mismatch: current=$CURRENT_TEAM candidate=$candidate_team"
            [ "$candidate_version" = "$TARGET_VERSION" ] \
                || die "$phase version does not match manifest: expected=$TARGET_VERSION actual=$candidate_version"
            version_is_greater "$candidate_version" "$CURRENT_VERSION" \
                || die "new version must be greater than current version: current=$CURRENT_VERSION new=$candidate_version"
            [ "$(plist_value "$app" CFBundleName)" = "Dal" ] \
                || die "$phase product name must be Dal"
            [ "$(plist_value "$app" CFBundleExecutable)" = "Dal" ] \
                || die "$phase executable must be Dal"
            validate_artifact_shape "$app"
        }

        # 在安装回滚 trap 前拒绝其他应用，失败时不得重启或移动它们。
        PREFLIGHT_BUNDLE_ID="$(plist_value "$APP_PATH" CFBundleIdentifier)" \
            || die "unable to read current Bundle ID"
        [ "$PREFLIGHT_BUNDLE_ID" = "pro.daliang.muse" ] \
            || die "current app does not belong to Dal"
        [ "$(/usr/bin/basename "$APP_PATH")" = "Dal.app" ] \
            || die "current app path must be Dal.app"

        MOUNT_POINT=""
        MOUNT_ATTACHED=0
        COMMITTED=0
        OLD_MOVE_STARTED=0
        OLD_MOVED=0

        cleanup_mount() {
            if [ "$MOUNT_ATTACHED" -eq 1 ] && [ -n "$MOUNT_POINT" ]; then
                "$HDIUTIL_BIN" detach "$MOUNT_POINT" >/dev/null 2>&1 \
                    || echo "WARNING: failed to detach $MOUNT_POINT"
                MOUNT_ATTACHED=0
            fi
        }

        finish_transaction() {
            local status="$?"
            local rollback_ok=0
            local quarantine_ready=0
            local backup_source=""
            trap - EXIT HUP INT TERM
            set +e
            if [ "$status" -ne 0 ] && [ "$COMMITTED" -ne 1 ]; then
                echo "Update failed; checking rollback state..."
                if /bin/mkdir -p "$FAILED_DIR"; then
                    quarantine_ready=1
                else
                    echo "ERROR: unable to create failed-candidate quarantine at $FAILED_DIR"
                fi

                if [ -e "$BACKUP_PATH" ] || [ -L "$BACKUP_PATH" ]; then
                    backup_source="$BACKUP_PATH"
                elif [ -e "$TRASHED_BACKUP" ] || [ -L "$TRASHED_BACKUP" ]; then
                    backup_source="$TRASHED_BACKUP"
                fi

                if [ -n "$backup_source" ]; then
                    if [ -e "$APP_PATH" ] || [ -L "$APP_PATH" ]; then
                        if ! "$MV_BIN" "$APP_PATH" "$FAILED_SIBLING"; then
                            echo "ERROR: unable to isolate failed installed app at $FAILED_SIBLING"
                        fi
                    fi
                    if [ ! -e "$APP_PATH" ] && [ ! -L "$APP_PATH" ]; then
                        if "$MV_BIN" "$backup_source" "$APP_PATH"; then
                            if "$CODESIGN_BIN" --verify --deep --strict --verbose=4 "$APP_PATH"; then
                                rollback_ok=1
                            else
                                echo "ERROR: restored app signature verification failed"
                            fi
                        else
                            echo "ERROR: unable to restore backup from $backup_source"
                        fi
                    fi
                elif [ "$OLD_MOVED" -eq 0 ] && [ -d "$APP_PATH" ] && [ ! -L "$APP_PATH" ]; then
                    if "$CODESIGN_BIN" --verify --deep --strict --verbose=4 "$APP_PATH"; then
                        rollback_ok=1
                    else
                        echo "ERROR: unchanged current app failed strict signature verification"
                    fi
                else
                    echo "ERROR: backup unavailable; automatic rollback could not be proven"
                fi

                if [ "$quarantine_ready" -eq 1 ]; then
                    if [ -e "$FAILED_SIBLING" ] || [ -L "$FAILED_SIBLING" ]; then
                        "$MV_BIN" "$FAILED_SIBLING" "$FAILED_APP" \
                            || echo "WARNING: failed candidate remains at $FAILED_SIBLING"
                    elif [ -e "$TEMP_APP" ] || [ -L "$TEMP_APP" ]; then
                        "$MV_BIN" "$TEMP_APP" "$FAILED_APP" \
                            || echo "WARNING: temporary candidate remains at $TEMP_APP"
                    fi
                fi

                if [ "$rollback_ok" -eq 1 ]; then
                    echo "ROLLBACK_OK"
                    echo "FAILED"
                    if [ -e "$READY_PATH" ] && [ ! -L "$READY_PATH" ]; then
                        while kill -0 "$APP_PID" 2>/dev/null; do /bin/sleep 0.2; done
                        "$OPEN_BIN" "$APP_PATH" >/dev/null 2>&1 \
                            || echo "WARNING: restored app could not be reopened automatically"
                    fi
                else
                    echo "ROLLBACK_FAILED"
                    echo "FAILED"
                fi
            fi
            cleanup_mount
            exit "$status"
        }
        handle_termination_signal() {
            local signal_name="$1"
            echo "ERROR: updater interrupted by $signal_name" >&2
            exit 1
        }
        trap 'handle_termination_signal HUP' HUP
        trap 'handle_termination_signal INT' INT
        trap 'handle_termination_signal TERM' TERM
        trap finish_transaction EXIT

        "$CODESIGN_BIN" --verify --deep --strict --verbose=4 "$APP_PATH" \
            || die "current app strict signature verification failed"
        CURRENT_BUNDLE_ID="$(plist_value "$APP_PATH" CFBundleIdentifier)" \
            || die "unable to read current Bundle ID"
        [ -n "$CURRENT_BUNDLE_ID" ] || die "current Bundle ID is empty"
        CURRENT_VERSION="$(plist_value "$APP_PATH" CFBundleShortVersionString)" \
            || die "unable to read current version"
        is_numeric_version "$CURRENT_VERSION" || die "current version is invalid: $CURRENT_VERSION"
        CURRENT_TEAM="$(team_identifier "$APP_PATH")" || die "unable to read current TeamIdentifier"
        if [ -z "$CURRENT_TEAM" ] || [ "$CURRENT_TEAM" = "not set" ]; then
            die "current install has no TeamIdentifier; automatic update refused"
        fi

        EXPECTED_SHA256="$(echo "$EXPECTED_SHA256" | /usr/bin/tr '[:upper:]' '[:lower:]')"
        ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')"
        ACTUAL_SHA256="$(echo "$ACTUAL_SHA256" | /usr/bin/tr '[:upper:]' '[:lower:]')"
        [ "$ACTUAL_SHA256" = "$EXPECTED_SHA256" ] \
            || die "DMG SHA256 mismatch"

        /bin/mkdir -m 0700 "$READY_PATH" \
            || die "unable to create updater ready marker"

        # Wait for app to exit
        while kill -0 "$APP_PID" 2>/dev/null; do /bin/sleep 0.2; done
        echo "App exited."

        "$CODESIGN_BIN" --verify --deep --strict --verbose=4 "$APP_PATH" \
            || die "current app changed or its signature became invalid before replacement"
        CURRENT_BUNDLE_ID_NOW="$(plist_value "$APP_PATH" CFBundleIdentifier)" \
            || die "unable to re-read current Bundle ID"
        CURRENT_VERSION_NOW="$(plist_value "$APP_PATH" CFBundleShortVersionString)" \
            || die "unable to re-read current version"
        CURRENT_TEAM_NOW="$(team_identifier "$APP_PATH")" \
            || die "unable to re-read current TeamIdentifier"
        [ "$CURRENT_BUNDLE_ID_NOW" = "$CURRENT_BUNDLE_ID" ] \
            || die "current Bundle ID changed before replacement"
        [ "$CURRENT_VERSION_NOW" = "$CURRENT_VERSION" ] \
            || die "current version changed before replacement"
        [ -n "$CURRENT_TEAM_NOW" ] && [ "$CURRENT_TEAM_NOW" = "$CURRENT_TEAM" ] \
            || die "current TeamIdentifier changed before replacement"

        ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')"
        ACTUAL_SHA256="$(echo "$ACTUAL_SHA256" | /usr/bin/tr '[:upper:]' '[:lower:]')"
        [ "$ACTUAL_SHA256" = "$EXPECTED_SHA256" ] \
            || die "DMG SHA256 changed before mount"

        echo "Mounting DMG read-only..."
        if [ "${DAL_UPDATER_TEST_MODE:-0}" = "1" ]; then
            MOUNT_POINT="${DAL_TEST_MOUNT_POINT:-}"
            [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ] && [ ! -L "$MOUNT_POINT" ] \
                || die "test mount point is invalid"
        else
            MOUNT_POINT="$STAGING_REAL/mount-$TX_ID"
            [ ! -e "$MOUNT_POINT" ] && [ ! -L "$MOUNT_POINT" ] \
                || die "mount point already exists: $MOUNT_POINT"
            /bin/mkdir -m 0700 "$MOUNT_POINT"
        fi
        if "$HDIUTIL_BIN" attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG_PATH"; then
            MOUNT_ATTACHED=1
        else
            die "failed to mount DMG read-only"
        fi
        NEW_APP="$MOUNT_POINT/Dal.app"
        [ -d "$NEW_APP" ] && [ ! -L "$NEW_APP" ] || die "exact Dal.app not found in DMG"

        validate_candidate "$NEW_APP" "mounted Dal.app"

        echo "Copying immutable app to same-volume temporary path..."
        "$DITTO_BIN" "$NEW_APP" "$TEMP_APP"
        validate_candidate "$TEMP_APP" "copied temporary app"

        echo "Replacing app with same-volume renames..."
        OLD_MOVE_STARTED=1
        if "$MV_BIN" "$APP_PATH" "$BACKUP_PATH"; then
            OLD_MOVED=1
        else
            die "failed to rename current app to backup"
        fi
        "$MV_BIN" "$TEMP_APP" "$APP_PATH" || die "failed to rename temporary app into place"
        validate_candidate "$APP_PATH" "installed app"

        cleanup_mount
        "$MV_BIN" "$BACKUP_PATH" "$TRASHED_BACKUP" \
            || die "failed to move verified backup to Trash"
        "$MV_BIN" "$DMG_PATH" "$TRASHED_DMG" \
            || die "failed to move installed DMG to Trash"
        COMMITTED=1

        echo "Update completed successfully at $(/bin/date)"
        echo "SUCCESS"
        "$OPEN_BIN" "$APP_PATH" >/dev/null 2>&1 \
            || echo "WARNING: updated app could not be reopened automatically"
        """

    nonisolated static var updaterScriptForTesting: String { updaterScript }

    // MARK: - Cleanup

    private func cleanupStaging() {
        try? FileManager.default.trashItem(at: stagingDir, resultingItemURL: nil)
    }
}

// MARK: - Download Delegate

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    let onComplete: @Sendable (URL?, URLResponse?, Error?) -> Void
    private var completedURL: URL?

    init(
        onProgress: @escaping @Sendable (Double) -> Void,
        onComplete: @escaping @Sendable (URL?, URLResponse?, Error?) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".dmg")
        try? FileManager.default.copyItem(at: location, to: temp)
        completedURL = temp
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            onComplete(nil, nil, error)
        } else {
            onComplete(completedURL, task.response, nil)
        }
    }
}
