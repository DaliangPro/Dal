import Foundation
import os

/// 两个本地引擎进程的实测驻留内存快照（SenseVoice 独立进程；Qwen3-ASR 与本地千问 LLM 共用 qwen3Process）
struct ServerMemoryUsage: Sendable {
    let senseVoiceMB: Int?
    let qwen3MB: Int?
}

/// Manages the local ASR Python server process.
/// On Apple Silicon: starts Qwen3-ASR server (MLX/Metal).
/// On Intel: starts SenseVoice server (ONNX/CPU).
actor SenseVoiceServerManager {
    static let shared = SenseVoiceServerManager()

    private static let senseVoiceKind = "sensevoice-server"
    private static let qwen3Kind = "qwen3-asr-server"
    private static let knownKinds = Set([senseVoiceKind, qwen3Kind])

    /// Synchronous kill of all server processes. Safe to call from applicationWillTerminate.
    /// 只向身份仍匹配的记录发信号；总等待时间有界，未确认退出的记录继续保留。
    nonisolated static func killAllServerProcesses() {
        var pending: [ServerProcessIdentity] = []
        var preserved: [ServerProcessIdentity] = []
        for identity in loadRecordedIdentities() {
            guard knownKinds.contains(identity.kind) else {
                securityLog("拒绝清理未知 kind 的 PID 身份：\(identity.kind)")
                preserved.append(identity)
                continue
            }
            switch ServerProcessController.validate(identity, expectedKind: identity.kind) {
            case .matching:
                pending.append(identity)
                if !ServerProcessController.sendSignal(
                    SIGTERM,
                    identity: identity,
                    expectedKind: identity.kind,
                    log: { message in securityLog(message) }
                ) {
                    securityLog("SIGTERM 发送失败，保留 PID 身份：\(identity.pid)")
                }
            case .notRunning, .mismatchedPath, .mismatchedStartTime, .mismatchedKind:
                // 原记录对应的进程已经退出或 PID 已复用，不向当前进程发信号。
                continue
            case .unreadable:
                securityLog("无法确认 PID 身份，保留记录且不发信号：\(identity.pid)")
                preserved.append(identity)
            }
        }

        waitSynchronouslyForExit(&pending, timeout: 3)
        for identity in pending {
            guard ServerProcessController.validate(
                identity,
                expectedKind: identity.kind
            ) == .matching else { continue }
            if !ServerProcessController.sendSignal(
                SIGKILL,
                identity: identity,
                expectedKind: identity.kind,
                log: { message in securityLog(message) }
            ) {
                securityLog("SIGKILL 发送失败，保留 PID 身份：\(identity.pid)")
            }
        }
        waitSynchronouslyForExit(&pending, timeout: 1)
        writeRecordedIdentities(preserved + pending)
        currentPort = nil
        currentQwen3Port = nil
    }

    /// Write effective hotwords (builtin + user) to hotwords.txt for Python servers.
    /// Called from non-actor context (HotwordStorage.save, etc).
    nonisolated static func syncHotwordsFile() {
        let words = HotwordStorage.loadEffectiveForASR().words
        let dir = AppPaths.ensureSupportDir()
        let path = dir.appendingPathComponent("hotwords.txt")
        let content = words.joined(separator: "\n")
        guard !SecureFilePermissions.isSymbolicLink(at: path) else {
            DebugFileLogger.log("拒绝写入符号链接热词文件: \(path.path)")
            return
        }
        do {
            try content.write(to: path, atomically: true, encoding: .utf8)
            _ = SecureFilePermissions.setOwnerOnlyPermissions(at: path, permissions: 0o600)
        } catch {
            DebugFileLogger.log("写入热词文件失败: \(error.localizedDescription)")
        }
        DebugFileLogger.log("Synced \(words.count) hotwords to hotwords.txt")
    }

    /// Sync hotwords and restart running servers to pick up changes.
    nonisolated static func syncHotwordsAndRestart() {
        syncHotwordsFile()
        Task {
            let mgr = shared
            let svWasRunning = await mgr.isRunning
            let q3WasRunning = await mgr.qwen3Port != nil
            if svWasRunning || q3WasRunning {
                await mgr.stop()
                try? await mgr.start()
                DebugFileLogger.log("Servers restarted for hotword update")
            }
        }
    }

    /// Whether this Mac has Apple Silicon (ARM64).
    private static let isAppleSilicon: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    /// Port of the running SenseVoice server (primary, streaming).
    /// Set by actor-isolated `start()`, read by sync callers like KeychainService.
    // REPAIR_PLAN J11：actor 内启动/停止写、killAllServerProcesses（nonisolated）写、
    // UI 与客户端多处跨线程读——裸静态量是 UB，收进 unfair lock，对外语法不变
    private static let _currentPort = OSAllocatedUnfairLock<Int?>(initialState: nil)
    private(set) static var currentPort: Int? {
        get { _currentPort.withLock { $0 } }
        set { _currentPort.withLock { $0 = newValue } }
    }

    /// Port of the running Qwen3-ASR server (secondary, speculative final).
    /// Only set on Apple Silicon where both servers run.
    private static let _currentQwen3Port = OSAllocatedUnfairLock<Int?>(initialState: nil)
    private(set) static var currentQwen3Port: Int? {
        get { _currentQwen3Port.withLock { $0 } }
        set { _currentQwen3Port.withLock { $0 = newValue } }
    }

    private let logger = Logger(subsystem: "pro.daliang.muse.sensevoice", category: "ServerManager")

    private var process: Process?
    private var processIdentity: ServerProcessIdentity?
    private var processExitLatch: ServerProcessExitLatch?
    private(set) var port: Int?
    private var stdoutPipe: Pipe?

    private var qwen3Process: Process?
    private var qwen3Identity: ServerProcessIdentity?
    private var qwen3ExitLatch: ServerProcessExitLatch?
    private(set) var qwen3Port: Int?
    private var qwen3StdoutPipe: Pipe?
    private var stoppingProcessIDs: Set<Int32> = []

    var isRunning: Bool { process?.isRunning ?? false }

    /// 两个引擎进程的实测驻留内存。SenseVoice 独立进程可单独测；Qwen3-ASR 与本地千问 LLM
    /// 共用 qwen3Process，只能给合计（2026-06-24 大梁老师：模型清单显示占用）。
    func currentMemoryUsage() -> ServerMemoryUsage {
        let svPid = (process?.isRunning ?? false) ? process?.processIdentifier : nil
        let q3Pid = (qwen3Process?.isRunning ?? false) ? qwen3Process?.processIdentifier : nil
        return ServerMemoryUsage(
            senseVoiceMB: svPid.flatMap { Self.residentMemoryMB(pid: $0) },
            qwen3MB: q3Pid.flatMap { Self.residentMemoryMB(pid: $0) }
        )
    }

    /// 用 ps 读某 pid 的 RSS（KB→MB）。每次刷新起一次轻量子进程，频率秒级、开销可忽略。
    nonisolated static func residentMemoryMB(pid: Int32) -> Int? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "rss=", "-p", String(pid)]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let kb = Int(s) else { return nil }
        return kb / 1024
    }

    var serverWSURL: URL? {
        guard let port else { return nil }
        return URL(string: "ws://127.0.0.1:\(port)/ws")
    }

    var healthURL: URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/health")
    }

    /// Called once at app launch. Kills orphans, then starts enabled servers.
    func start() async throws {
        await killOrphanedServers()
        Self.syncHotwordsFile()

        let svEnabled = UserDefaults.standard.object(forKey: DefaultsKeys.sensevoiceEnabled) as? Bool ?? true
        let qwen3Enabled = UserDefaults.standard.object(forKey: DefaultsKeys.qwen3FinalEnabled) as? Bool ?? true

        DebugFileLogger.log("start(): sv=\(svEnabled) q3=\(qwen3Enabled)")

        // Launch enabled servers in parallel.
        // 只要本地 LLM(gguf) 在位就起 Qwen3 server 承载 LLM——即使用户没启用/没下 Qwen3-ASR，
        // 本地 LLM(Qwen3.5-9B) 也能在 app 内独立运行（server 进入 LLM-only 模式）。
        let needQwen3Server = qwen3Enabled || LocalQwenLLMConfig.isModelAvailable
        var qwen3Task: Task<Void, Error>?
        if Self.isAppleSilicon && needQwen3Server && qwen3Process == nil {
            qwen3Task = Task { try await self.launchQwen3Server() }
        }

        // SenseVoice 启动失败不应拖垮整个 start()（更不应连累上面的 LLM/Qwen3 server）
        if svEnabled && process == nil {
            do {
                try await launchSenseVoiceServer()
            } catch {
                logger.warning("SenseVoice failed to start: \(error)")
                DebugFileLogger.log("SenseVoice launch failed: \(error)")
            }
        }

        if let qwen3Task {
            do {
                try await qwen3Task.value
            } catch {
                logger.warning("Qwen3-ASR failed to start: \(error)")
                DebugFileLogger.log("Qwen3-ASR launch failed: \(error)")
            }
        }

        DebugFileLogger.log("start() done: svPort=\(Self.currentPort ?? -1) q3Port=\(Self.currentQwen3Port ?? -1)")
    }

    /// Launch the SenseVoice server as the primary streaming server.
    private func launchSenseVoiceServer() async throws {
        let proc = Process()
        proc.environment = LocalServiceAuth.serverEnvironment()
        var args: [String] = []

        try await configureSenseVoiceServer(proc: proc, args: &args)

        // On Intel (no Qwen3), LLM runs on SenseVoice server
        if !Self.isAppleSilicon, let llmPath = LocalQwenLLMConfig.modelPath {
            args += ["--llm-model", llmPath]
            logger.info("LLM model configured on SenseVoice server: \(llmPath)")
        }

        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        let errPipe = Pipe()
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let msg = String(data: data, encoding: .utf8) else { return }
            for line in msg.split(separator: "\n") where !line.isEmpty {
                DebugFileLogger.log("sensevoice-server: \(line)")
            }
        }
        self.stdoutPipe = pipe
        let exitLatch = ServerProcessExitLatch()
        proc.terminationHandler = { [weak self, exitLatch] p in
            exitLatch.signal()
            Task { await self?.handleUnexpectedExit(of: p, label: "sensevoice-server") }
        }

        logger.info("Starting SenseVoice server: \(proc.executableURL?.path ?? "?")")

        do {
            try proc.run()
        } catch {
            detachPipeHandlers(of: proc)
            stdoutPipe = nil
            logger.error("Failed to start SenseVoice server: \(error)")
            throw ServerError.launchFailed(error)
        }
        guard let identity = await Self.captureLaunchedIdentity(
            kind: Self.senseVoiceKind,
            pid: proc.processIdentifier
        ) else {
            detachPipeHandlers(of: proc)
            _ = await Self.terminateUnidentifiedLaunchedProcess(
                proc,
                exitLatch: exitLatch,
                label: "sensevoice-server"
            )
            stdoutPipe = nil
            throw ServerError.processIdentityUnavailable
        }
        self.process = proc
        self.processIdentity = identity
        self.processExitLatch = exitLatch
        savePidsToFile()

        // SenseVoice model loading via PyTorch/FunASR is slow (~2 min), needs generous timeout
        let portResult = await ServerPortReader.discoverPort(from: pipe, timeout: .seconds(180))
        guard let discoveredPort = portResult else {
            let stopped = await reliablyTerminate(
                proc,
                identity: identity,
                kind: Self.senseVoiceKind,
                exitLatch: exitLatch,
                label: "sensevoice-server"
            )
            if stopped, process === proc {
                clearSenseVoiceState()
                savePidsToFile()
            }
            throw ServerError.portDiscoveryFailed
        }
        self.port = discoveredPort
        Self.currentPort = discoveredPort
        // 拿到 PORT 后 ServerPortReader 已摘除发现阶段 handler，
        // 此处给 stdout 装持续排空 handler，避免运行期日志写满管道缓冲让 Python 卡死。
        drainStdout(pipe: pipe, label: "sensevoice-server")
        logger.info("SenseVoice server started on port \(discoveredPort)")

        let healthy = await waitForHealth(timeout: 30)
        if !healthy {
            logger.warning("SenseVoice server started but health check not responding yet")
        }
        savePidsToFile()
    }

    /// Launch the Qwen3-ASR server as secondary (speculative final + LLM).
    private func launchQwen3Server() async throws {
        let proc = Process()
        proc.environment = LocalServiceAuth.serverEnvironment()
        var args: [String] = []

        try configureQwen3Server(proc: proc, args: &args)

        // LLM runs on Qwen3 server (shares _inference_lock for Metal GPU)
        if let llmPath = LocalQwenLLMConfig.modelPath {
            args += ["--llm-model", llmPath]
            logger.info("LLM model configured on Qwen3 server: \(llmPath)")
        }

        proc.arguments = args

        let pipe = Pipe()
        proc.standardOutput = pipe
        let errPipe = Pipe()
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let msg = String(data: data, encoding: .utf8) else { return }
            for line in msg.split(separator: "\n") where !line.isEmpty {
                DebugFileLogger.log("qwen3-asr-server: \(line)")
            }
        }
        self.qwen3StdoutPipe = pipe
        let exitLatch = ServerProcessExitLatch()
        proc.terminationHandler = { [weak self, exitLatch] p in
            exitLatch.signal()
            Task { await self?.handleUnexpectedExit(of: p, label: "qwen3-asr-server") }
        }

        logger.info("Starting Qwen3-ASR server: \(proc.executableURL?.path ?? "?")")

        do {
            try proc.run()
        } catch {
            detachPipeHandlers(of: proc)
            qwen3StdoutPipe = nil
            logger.error("Failed to start Qwen3-ASR server: \(error)")
            throw ServerError.launchFailed(error)
        }
        guard let identity = await Self.captureLaunchedIdentity(
            kind: Self.qwen3Kind,
            pid: proc.processIdentifier
        ) else {
            detachPipeHandlers(of: proc)
            _ = await Self.terminateUnidentifiedLaunchedProcess(
                proc,
                exitLatch: exitLatch,
                label: "qwen3-asr-server"
            )
            qwen3StdoutPipe = nil
            throw ServerError.processIdentityUnavailable
        }
        self.qwen3Process = proc
        self.qwen3Identity = identity
        self.qwen3ExitLatch = exitLatch
        savePidsToFile()

        let portResult = await ServerPortReader.discoverPort(from: pipe, timeout: .seconds(120))
        guard let discoveredPort = portResult else {
            let stopped = await reliablyTerminate(
                proc,
                identity: identity,
                kind: Self.qwen3Kind,
                exitLatch: exitLatch,
                label: "qwen3-asr-server"
            )
            if stopped, qwen3Process === proc {
                clearQwen3State()
                savePidsToFile()
            }
            throw ServerError.portDiscoveryFailed
        }
        self.qwen3Port = discoveredPort
        Self.currentQwen3Port = discoveredPort
        // 拿到 PORT 后 ServerPortReader 已摘除发现阶段 handler，
        // 此处给 stdout 装持续排空 handler，避免运行期日志写满管道缓冲让 Python 卡死。
        drainStdout(pipe: pipe, label: "qwen3-asr-server")
        logger.info("Qwen3-ASR server started on port \(discoveredPort)")

        // Health check for Qwen3
        let qwen3HealthURL = URL(string: "http://127.0.0.1:\(discoveredPort)/health")!
        var healthy = false
        for _ in 0..<30 {
            do {
                var request = URLRequest(url: qwen3HealthURL)
                LocalServiceAuth.authorize(&request)
                let (_, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 { healthy = true; break }
            } catch {}
            try? await Task.sleep(for: .seconds(1))
        }
        if !healthy {
            logger.warning("Qwen3-ASR server started but health check not responding yet")
        }
        savePidsToFile()
    }

    /// Start the Qwen3-ASR server independently (e.g. when user enables verification).
    /// Start the SenseVoice server independently.
    func startSenseVoice() async throws {
        guard process == nil else { return }
        try await launchSenseVoiceServer()
    }

    /// Stop the SenseVoice server independently.
    func stopSenseVoice() async {
        guard let proc = process else {
            clearSenseVoiceState()
            savePidsToFile()
            return
        }
        guard let identity = processIdentity, let exitLatch = processExitLatch else {
            Self.securityLog("拒绝停止 SenseVoice：缺少已验证的进程身份或退出观察器")
            return
        }

        let stopped = await reliablyTerminate(
            proc,
            identity: identity,
            kind: Self.senseVoiceKind,
            exitLatch: exitLatch,
            label: "sensevoice-server"
        )
        guard process === proc else { return }
        if stopped {
            clearSenseVoiceState()
            logger.info("SenseVoice server stopped")
            DebugFileLogger.log("SenseVoice server stopped (user toggle)")
        } else {
            Self.securityLog("SenseVoice 停止未确认，保留进程引用与 PID 身份")
        }
        savePidsToFile()
    }

    /// Start the Qwen3-ASR server independently.
    func startQwen3() async throws {
        guard qwen3Process == nil else { return }
        try await launchQwen3Server()
    }

    /// Stop the Qwen3-ASR server independently (e.g. when user disables verification).
    func stopQwen3() async {
        guard let proc = qwen3Process else {
            clearQwen3State()
            savePidsToFile()
            return
        }
        guard let identity = qwen3Identity, let exitLatch = qwen3ExitLatch else {
            Self.securityLog("拒绝停止 Qwen3：缺少已验证的进程身份或退出观察器")
            return
        }

        let stopped = await reliablyTerminate(
            proc,
            identity: identity,
            kind: Self.qwen3Kind,
            exitLatch: exitLatch,
            label: "qwen3-asr-server"
        )
        guard qwen3Process === proc else { return }
        if stopped {
            clearQwen3State()
            logger.info("Qwen3-ASR server stopped")
            DebugFileLogger.log("Qwen3-ASR server stopped (user toggle)")
        } else {
            Self.securityLog("Qwen3 停止未确认，保留进程引用与 PID 身份")
        }
        savePidsToFile()
    }

    /// Stop all server processes.
    func stop() async {
        await stopSenseVoice()
        await stopQwen3()
        if process == nil, qwen3Process == nil {
            logger.info("All ASR servers stopped")
        } else {
            Self.securityLog("本地服务停止未完全确认，仍保留活动进程引用")
        }
    }

    // MARK: - PID File Management

    private static var pidFileURL: URL {
        AppPaths.support("server-pids.txt")
    }

    /// 保存完整进程身份；停止未确认时 identity 会继续留在账本中。
    private func savePidsToFile() {
        Self.writeRecordedIdentities(currentIdentities())
    }

    private func currentIdentities() -> [ServerProcessIdentity] {
        [processIdentity, qwen3Identity].compactMap { $0 }
    }

    nonisolated private static func loadRecordedIdentities() -> [ServerProcessIdentity] {
        guard let data = try? Data(contentsOf: pidFileURL) else { return [] }
        return ServerProcessIdentityLedger.decode(
            data,
            log: { message in securityLog(message) }
        )
    }

    nonisolated private static func writeRecordedIdentities(
        _ identities: [ServerProcessIdentity]
    ) {
        do {
            let data = try ServerProcessIdentityLedger.encode(identities)
            try data.write(to: pidFileURL, options: .atomic)
        } catch {
            securityLog("写入 PID 身份文件失败：\(error.localizedDescription)")
        }
    }

    nonisolated private static func securityLog(_ message: String) {
        let redacted = LogRedactor.redact(message)
        Logger(
            subsystem: "pro.daliang.muse.sensevoice",
            category: "ProcessSecurity"
        ).error("\(redacted, privacy: .private)")
        DebugFileLogger.log("[ProcessSecurity] \(redacted)")
    }

    nonisolated private static func waitSynchronouslyForExit(
        _ identities: inout [ServerProcessIdentity],
        timeout: TimeInterval
    ) {
        let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        repeat {
            identities.removeAll { identity in
                switch ServerProcessController.validate(identity, expectedKind: identity.kind) {
                case .notRunning, .mismatchedKind, .mismatchedPath, .mismatchedStartTime:
                    return true
                case .matching, .unreadable:
                    return false
                }
            }
            if identities.isEmpty || DispatchTime.now().uptimeNanoseconds >= deadline { return }
            usleep(25_000)
        } while true
    }

    /// Kill orphaned server processes from previous app runs using saved PID file.
    /// 只有 JSON 中 kind、path、start time 全部仍匹配时才会发信号。
    private func killOrphanedServers() async {
        // 当前进程正在管理的 server 不是「孤儿」。start() 可能被多次调用（启动、保存配置、
        // 切换 provider 都触发）——若把自己刚拉起的 server 当孤儿杀掉、又因 isRunning 判定
        // 已在而不重启，就会出现「LLM/ASR 全部连不上」（2026-06-22 修复）。
        let managed = Set([process?.processIdentifier, qwen3Process?.processIdentifier].compactMap { $0 })
        var unresolved: [ServerProcessIdentity] = []
        for identity in Self.loadRecordedIdentities() where !managed.contains(identity.pid) {
            guard Self.knownKinds.contains(identity.kind) else {
                Self.securityLog("拒绝清理未知 kind 的孤儿 PID 身份：\(identity.kind)")
                unresolved.append(identity)
                continue
            }
            let result = await ServerProcessController.terminate(
                identity: identity,
                expectedKind: identity.kind,
                log: { message in Self.securityLog(message) }
            )
            switch result {
            case .terminatedGracefully, .killed:
                DebugFileLogger.log("Reaped verified orphan server PID \(identity.pid)")
            case .alreadyExited:
                break
            case .refused, .failed:
                Self.securityLog(
                    "孤儿进程清理未确认，未向不匹配身份升级信号：PID \(identity.pid)"
                )
                unresolved.append(identity)
            }
        }
        var seen: Set<String> = []
        let merged = (currentIdentities() + unresolved).filter { identity in
            seen.insert("\(identity.kind):\(identity.pid):\(identity.startTimeSeconds)").inserted
        }
        Self.writeRecordedIdentities(merged)
    }

    /// Check if the server is healthy.
    nonisolated func isHealthy() async -> Bool {
        guard let url = await healthURL else { return false }
        do {
            var request = URLRequest(url: url)
            LocalServiceAuth.authorize(&request)
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Private

    // MARK: - Qwen3-ASR (Apple Silicon)

    private func configureQwen3Server(proc: Process, args: inout [String]) throws {
        let resolved = try resolveServerExecutable(name: "qwen3-asr-server")

        // ASR 模型可选：缺省时让 server 进入 LLM-only 模式（本地 LLM 不依赖 Qwen3-ASR 独立运行）。
        // 但 ASR 与 LLM 至少要有一个，否则这个 server 没什么可服务。
        let modelPath = Self.resolveQwen3ModelPath()
        guard modelPath != nil || LocalQwenLLMConfig.modelPath != nil else {
            throw ServerError.modelNotFound
        }
        if let modelPath {
            logger.info("Qwen3-ASR model: \(modelPath)")
        } else {
            logger.info("No Qwen3-ASR model — Qwen3 server runs in LLM-only mode")
        }

        // Hotwords file (same as SenseVoice)
        let hotwordsPath = AppPaths.support("hotwords.txt")
        let hotwordsFile = FileManager.default.fileExists(atPath: hotwordsPath.path) ? hotwordsPath.path : ""

        proc.executableURL = resolved.executableURL
        if let serverScript = resolved.serverScriptURL {
            args.append(serverScript.path)
        }
        args += [
            "--model-path", modelPath ?? "",
            "--port", "0",
            "--hotwords-file", hotwordsFile,
        ]
        logger.info("Starting Qwen3-ASR server (asr=\(modelPath != nil))")
    }

    /// 暴露给模型清单 UI 做在位检查（nonisolated：纯文件系统探测）
    nonisolated static func resolveQwen3ModelPath() -> String? {
        // 1. Bundled in app (production DMG)
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Models")
            .appendingPathComponent("Qwen3-ASR")
        if let b = bundled, FileManager.default.fileExists(atPath: b.path) {
            return b.path
        }
        // 2. App Support (user-downloaded)
        let userModel = AppPaths.support("Models/Qwen3-ASR")
        if FileManager.default.fileExists(atPath: userModel.path) {
            return userModel.path
        }
        // 3. ModelScope cache (dev fallback)
        let cache06 = NSHomeDirectory() + "/.cache/modelscope/hub/models/Qwen/Qwen3-ASR-0.6B"
        if FileManager.default.fileExists(atPath: cache06) { return cache06 }
        let cache17 = NSHomeDirectory() + "/.cache/modelscope/hub/models/Qwen/Qwen3-ASR-1.7B"
        if FileManager.default.fileExists(atPath: cache17) { return cache17 }
        return nil
    }

    // MARK: - SenseVoice (Intel fallback)

    private func configureSenseVoiceServer(proc: Process, args: inout [String]) async throws {
        let resolved = try resolveServerExecutable(name: "sensevoice-server")

        let bundledModel = Bundle.main.resourceURL?
            .appendingPathComponent("Models")
            .appendingPathComponent("SenseVoiceSmall")
        // 用户下载位（与 ModelManager 多文件下载落地一致）
        let userModel = AppPaths.support("Models/SenseVoiceSmall")
        let candidates = [bundledModel, userModel].compactMap { $0 }
        var modelDir: String?
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            do {
                try await ModelArtifactVerifier.verifyInstalledDirectory(
                    at: candidate,
                    spec: ModelArtifactManifest.senseVoice
                )
                modelDir = candidate.path
                logger.info("Using verified SenseVoice model at \(candidate.path)")
                break
            } catch {
                logger.warning("拒绝未通过清单校验的 SenseVoice 模型：\(candidate.path, privacy: .private(mask: .hash))")
            }
        }
        guard let modelDir else {
            // 不把模型标识交给 Python/ModelScope，缺失或损坏时直接失败闭合。
            throw ServerError.modelNotFound
        }

        let hotwordsPath = AppPaths.support("hotwords.txt")
        let hotwordsFile = FileManager.default.fileExists(atPath: hotwordsPath.path) ? hotwordsPath.path : ""

        proc.executableURL = resolved.executableURL
        if let serverScript = resolved.serverScriptURL {
            args.append(serverScript.path)
        }
        args += [
            "--model-dir", modelDir,
            "--port", "0",
            "--hotwords-file", hotwordsFile,
            "--beam-size", "3",
            "--context-score", "6.0",
            "--device", "auto",
            "--language", "auto",
            "--textnorm",
            "--padding", "8",
            "--chunk-size", "10",
        ]
        logger.info("Starting SenseVoice server")
    }

    // MARK: - Server executable resolution

    /// ServerManager 与 ModelManager 共用同一 resolver；测试可注入构建策略和
    /// 文件元数据，不依赖当前测试二进制究竟是 Debug 还是 Release。
    nonisolated static func resolveServerExecutable(
        name: String,
        using resolver: ServerExecutableResolver = .live
    ) throws -> ResolvedServerExecutable {
        try resolver.resolve(name: name)
    }

    private func resolveServerExecutable(name: String) throws -> ResolvedServerExecutable {
        do {
            let resolved = try Self.resolveServerExecutable(name: name)
            if resolved.source == .development {
                logger.warning("\(name) resolved from explicit DEBUG development root")
            }
            return resolved
        } catch let error as ServerExecutableResolutionError {
            Self.securityLog("拒绝解析本地服务 \(name)：\(String(describing: error))")
            switch error {
            case .pythonMissing, .pythonNotExecutable:
                throw ServerError.venvNotFound
            default:
                throw ServerError.serverNotFound
            }
        }
    }

    nonisolated private static func captureLaunchedIdentity(
        kind: String,
        pid: Int32
    ) async -> ServerProcessIdentity? {
        for _ in 0..<5 {
            if let identity = ServerProcessController.captureIdentity(kind: kind, pid: pid) {
                return identity
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        securityLog("启动后无法捕获真实进程身份：kind=\(kind) pid=\(pid)")
        return nil
    }

    /// 身份捕获失败发生在 run 后的启动窗口；此时仍持有刚创建的精确 Process 对象。
    /// 先 TERM，再在对象仍报告运行时 KILL，确保不会留下无账本子进程。
    nonisolated private static func terminateUnidentifiedLaunchedProcess(
        _ proc: Process,
        exitLatch: ServerProcessExitLatch,
        label: String
    ) async -> Bool {
        if !proc.isRunning { return true }
        proc.terminate()
        if await exitLatch.wait(timeout: .seconds(1)) || !proc.isRunning {
            return true
        }

        guard proc.isRunning else { return true }
        if kill(proc.processIdentifier, SIGKILL) != 0 {
            securityLog("\(label) 身份捕获失败后 SIGKILL 发送失败：errno=\(errno)")
            return false
        }
        let stopped = await exitLatch.wait(timeout: .seconds(1)) || !proc.isRunning
        if !stopped {
            securityLog("\(label) 身份捕获失败后的强制回收未确认")
        }
        return stopped
    }

    private func reliablyTerminate(
        _ proc: Process,
        identity: ServerProcessIdentity,
        kind: String,
        exitLatch: ServerProcessExitLatch,
        label: String
    ) async -> Bool {
        if stoppingProcessIDs.contains(proc.processIdentifier) {
            let exited = await exitLatch.wait(timeout: .seconds(4))
            return exited || !proc.isRunning
        }
        stoppingProcessIDs.insert(proc.processIdentifier)
        detachPipeHandlers(of: proc)
        let result = await ServerProcessController.terminate(
            process: proc,
            identity: identity,
            expectedKind: kind,
            exitLatch: exitLatch,
            log: { message in Self.securityLog(message) }
        )
        stoppingProcessIDs.remove(proc.processIdentifier)

        if !proc.isRunning { return true }

        switch result {
        case .alreadyExited, .terminatedGracefully, .killed:
            return !proc.isRunning
        case .refused, .failed:
            Self.securityLog("\(label) 停止失败：\(String(describing: result))")
            restorePipeHandlers(of: proc, label: label)
            return false
        }
    }

    private func clearSenseVoiceState() {
        process = nil
        processIdentity = nil
        processExitLatch = nil
        port = nil
        Self.currentPort = nil
        stdoutPipe = nil
    }

    private func clearQwen3State() {
        qwen3Process = nil
        qwen3Identity = nil
        qwen3ExitLatch = nil
        qwen3Port = nil
        Self.currentQwen3Port = nil
        qwen3StdoutPipe = nil
    }

    /// 端口发现完成后给 stdout 装持续排空 handler（与 stderr 一致），把运行期日志喂给
    /// DebugFileLogger。否则 Python server 运行期的 print 会写满管道缓冲（约 64KB），阻塞在
    /// print() 上而拖死 ASR/LLM 引擎。须在 ServerPortReader 摘除发现 handler 后调用，避免争抢句柄。
    /// REPAIR_PLAN J9：进程收尾时摘除管道读 handler——handler 挂着的 dispatch source
    /// 会钉住已关闭的 FD，热词变更等频繁重启会累积泄漏句柄与 source。
    private func detachPipeHandlers(of proc: Process?) {
        (proc?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (proc?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    }

    private func restorePipeHandlers(of proc: Process, label: String) {
        if let stdout = proc.standardOutput as? Pipe {
            drainStdout(pipe: stdout, label: label)
        }
        if let stderr = proc.standardError as? Pipe {
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let message = String(data: data, encoding: .utf8) else { return }
                for line in message.split(separator: "\n") where !line.isEmpty {
                    DebugFileLogger.log("\(label): \(line)")
                }
            }
        }
    }

    /// REPAIR_PLAN J9：感知服务进程意外退出——此前无 terminationHandler，Python 崩溃后
    /// App 仍以为服务在运行，ASR/LLM 静默不可用。主动 stop/重启会先把属性换掉，
    /// 回调进 actor 时进程已不在册即忽略；仍在册说明是意外退出，清理在册状态留痕。
    /// 不做自动重启（避免崩溃风暴），下次识别/健康探测会走正常启动路径。
    private func handleUnexpectedExit(of proc: Process, label: String) {
        if stoppingProcessIDs.contains(proc.processIdentifier) {
            return
        }
        if proc === process {
            logger.error("\(label) exited unexpectedly (status \(proc.terminationStatus))")
            DebugFileLogger.log("\(label) exited unexpectedly status=\(proc.terminationStatus)")
            detachPipeHandlers(of: proc)
            clearSenseVoiceState()
            savePidsToFile()
        } else if proc === qwen3Process {
            logger.error("\(label) exited unexpectedly (status \(proc.terminationStatus))")
            DebugFileLogger.log("\(label) exited unexpectedly status=\(proc.terminationStatus)")
            detachPipeHandlers(of: proc)
            clearQwen3State()
            savePidsToFile()
        }
    }

    private func drainStdout(pipe: Pipe, label: String) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let msg = String(data: data, encoding: .utf8) else { return }
            for line in msg.split(separator: "\n") where !line.isEmpty {
                DebugFileLogger.log("\(label): \(line)")
            }
        }
    }

    private func waitForHealth(timeout: Int) async -> Bool {
        for _ in 0..<timeout {
            if await isHealthy() { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    // MARK: - Errors

    enum ServerError: Error, LocalizedError {
        case serverNotFound
        case venvNotFound
        case modelNotFound
        case launchFailed(Error)
        case processIdentityUnavailable
        case portDiscoveryFailed

        var errorDescription: String? {
            switch self {
            case .serverNotFound:
                return L("SenseVoice 服务未找到", "SenseVoice server not found")
            case .venvNotFound:
                return L("Python 环境未配置", "Python environment not configured")
            case .modelNotFound:
                return L("本地 ASR 模型未找到，请先下载", "Local ASR model not found, please download first")
            case .launchFailed(let e):
                return L("服务启动失败: \(e.localizedDescription)", "Server launch failed: \(e.localizedDescription)")
            case .processIdentityUnavailable:
                return L("无法验证本地服务进程身份", "Unable to verify local server process identity")
            case .portDiscoveryFailed:
                return L("服务端口发现失败", "Server port discovery failed")
            }
        }
    }
}
