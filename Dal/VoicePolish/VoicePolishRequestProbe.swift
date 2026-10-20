import AppKit
import CoreFoundation
import Darwin
import Foundation
import Security

/// 独立实验请求，不进入润色管线、质量评分、麦克风或文字注入。
enum VoicePolishRequestProbe {
    static let argument = "--voice-polish-request-probe"
    static let maximumInputBytes = 1_048_576
    static let expectedEndpoint = "https://api.deepseek.com/chat/completions"

    enum ProbeError: String, Error {
        case mixedOperations = "mixed_operations"
        case invalidArguments = "invalid_arguments"
        case invalidInput = "invalid_input"
        case invalidPath = "invalid_path"
        case outputExists = "output_exists"
        case fileFailure = "file_failure"
        case configurationUnavailable = "configuration_unavailable"
        case configurationMismatch = "configuration_mismatch"
        case runtimeIdentityUnavailable = "runtime_identity_unavailable"
        case timedOut = "timed_out"
        case invalidReceipt = "invalid_receipt"
    }

    struct Invocation: Sendable, Equatable {
        let inputPath: String
        let outputPath: String
    }

    enum ResponseFormat: String, Decodable, Sendable {
        case text
        case jsonObject = "json_object"
    }

    struct Input: Decodable, Sendable, Equatable {
        let schemaVersion: Int
        let experimentID: String
        let caseID: String
        let canonicalText: String
        let system: String
        let user: String
        let maxOutputTokens: Int
        let responseFormat: ResponseFormat

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", experimentID = "experiment_id", caseID = "case_id"
            case canonicalText = "canonical_text", system, user
            case maxOutputTokens = "max_output_tokens", responseFormat = "response_format"
        }
    }

    struct RuntimeIdentity: Sendable, Encodable {
        let commit: String
        let executableSHA256: String
        let processID: Int32
        enum CodingKeys: String, CodingKey {
            case commit, executableSHA256 = "executable_sha256", processID = "process_id"
        }
    }

    struct RequestRecord: Encodable, Sendable {
        let context = "structuredTask"
        let task = "voicePolishRender"
        let system: String
        let user: String
        let temperature = 0
        let reasoningPolicy = "disabled"
        let timeoutMilliseconds = 30_000
        let maxOutputTokens: Int
        let responseFormat: String
        enum CodingKeys: String, CodingKey {
            case context, task, system, user, temperature
            case reasoningPolicy = "reasoning_policy", timeoutMilliseconds = "timeout_milliseconds"
            case maxOutputTokens = "max_output_tokens", responseFormat = "response_format"
        }
    }

    struct ResponseRecord: Encodable, Sendable {
        let text: String
        let model: String
        let textSHA256: String
        enum CodingKeys: String, CodingKey { case text, model, textSHA256 = "text_sha256" }
    }

    struct Evidence: Encodable, Sendable {
        let schemaVersion = 1
        let evidenceKind = "controlled_request_probe"
        let isProductionQualityResult = false
        let runNonce: String
        let startedAt: Date
        var finishedAt: Date?
        var elapsedMilliseconds: Int64 = 0
        var status = "failed"
        var failureCode: String?
        var experimentID: String?
        var caseID: String?
        var inputSHA256: String?
        var runtime: RuntimeIdentity?
        var request: RequestRecord?
        var response: ResponseRecord?
        var provider: String?
        var endpointURL: String?
        var attemptCount = 0
        var receiptCount: Int? = 0
        var stageResponses: [VoicePolishQualityStageResponse] = []

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", evidenceKind = "evidence_kind"
            case isProductionQualityResult = "is_production_quality_result"
            case runNonce = "run_nonce", startedAt = "started_at", finishedAt = "finished_at"
            case elapsedMilliseconds = "elapsed_milliseconds", status, failureCode = "failure_code"
            case experimentID = "experiment_id", caseID = "case_id", inputSHA256 = "input_sha256"
            case runtime, request, response, provider, endpointURL = "endpoint_url"
            case attemptCount = "attempt_count", receiptCount = "receipt_count", stageResponses = "stage_responses"
        }
    }

    /// 先于三种 headless 操作的任何权限、配置或客户端构造执行。
    static func validateOperations(arguments: [String]) throws {
        let flags = [argument, "--voice-polish-quality-run", VoicePolishQualityAuthorization.argument]
        let count = flags.reduce(0) { total, flag in total + arguments.filter { $0 == flag }.count }
        guard count <= 1 else { throw ProbeError.mixedOperations }
    }

    static func parseInvocation(arguments: [String]) throws -> Invocation? {
        try validateOperations(arguments: arguments)
        guard arguments.contains(argument) else { return nil }
        guard arguments.count == 6, arguments.first?.hasPrefix("--") == false else {
            throw ProbeError.invalidArguments
        }
        var values: [String: String] = [:]
        var sawProbe = false
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            if flag == argument {
                guard !sawProbe else { throw ProbeError.invalidArguments }
                sawProbe = true; index += 1; continue
            }
            guard ["--probe-input", "--probe-output"].contains(flag), values[flag] == nil,
                  index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw ProbeError.invalidArguments
            }
            values[flag] = arguments[index + 1]; index += 2
        }
        guard sawProbe, let input = values["--probe-input"], let output = values["--probe-output"],
              canonicalAbsolutePath(input), canonicalAbsolutePath(output) else { throw ProbeError.invalidArguments }
        return Invocation(inputPath: input, outputPath: output)
    }

    static func decodeInput(_ data: Data) throws -> Input {
        guard data.count <= maximumInputBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schema_version", "experiment_id", "case_id", "canonical_text", "system", "user", "max_output_tokens", "response_format"],
              exactInteger(object["schema_version"]) == 1,
              let tokens = exactInteger(object["max_output_tokens"]), (1...8192).contains(tokens),
              let input = try? JSONDecoder().decode(Input.self, from: data),
              validIdentifier(input.experimentID), validIdentifier(input.caseID),
              !input.canonicalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.canonicalText.count <= 1_000,
              !input.system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.system.utf8.count <= 32 * 1024, input.user.utf8.count <= 128 * 1024,
              let user = try? JSONSerialization.jsonObject(with: Data(input.user.utf8)) as? [String: Any],
              let canonical = user["canonical_text"] as? String,
              canonical.utf8.elementsEqual(input.canonicalText.utf8),
              !containsCredentialFields(user) else { throw ProbeError.invalidInput }
        var outerScanner = VoicePolishJSONUniqueKeys(data: data)
        var userScanner = VoicePolishJSONUniqueKeys(data: Data(input.user.utf8))
        do {
            try outerScanner.check()
            try userScanner.check()
        } catch { throw ProbeError.invalidInput }
        return input
    }

    static func makeRequest(_ input: Input) -> LLMRequest {
        LLMRequest(context: .structuredTask, task: .voicePolishRender, system: input.system, user: input.user,
                   options: .init(temperature: 0, maxOutputTokens: input.maxOutputTokens,
                                  reasoningPolicy: .disabled,
                                  responseFormat: input.responseFormat == .text ? .text : .jsonObject))
    }

    static func validateConfiguration(provider: LLMProvider, config: LLMConfig) throws -> String {
        guard provider == .deepseek, config.model == "deepseek-flash", !config.apiKey.isEmpty,
              let endpoint = try? VoicePolishQualityRunner.endpointIdentity(rawBaseURL: config.baseURL, provider: provider),
              endpoint == expectedEndpoint else { throw ProbeError.configurationMismatch }
        return endpoint
    }

    /// 测试显式注入依赖，不访问真实配置；正式入口只提供下方固定的生产依赖。
    static func execute(
        invocation: Invocation,
        workspaceRoot: URL,
        loadIdentity: () throws -> RuntimeIdentity,
        loadConfiguration: () throws -> (LLMProvider, LLMConfig),
        clientFactory: (LLMProvider) -> any LLMClient
    ) async throws -> Evidence {
        let output = try prepareOutput(invocation.outputPath, workspaceRoot: workspaceRoot)
        var report = Evidence(runNonce: VoicePolishProviderAudit.sha256Hex(Data(UUID().uuidString.utf8)), startedAt: Date())
        let start = ContinuousClock.now
        let counter = VoicePolishProviderAuditSuccessCounter()
        var receiptURL: URL?
        do {
            let data = try readInput(invocation.inputPath, workspaceRoot: workspaceRoot)
            report.inputSHA256 = VoicePolishProviderAudit.sha256Hex(data)
            let input = try decodeInput(data)
            report.experimentID = input.experimentID; report.caseID = input.caseID
            // 无效/带配置字段输入不复制进证据目录；有效请求保存输入原字节，不重新编码替代。
            try writeNew(data, to: output.appendingPathComponent("input.raw.json"))
            let request = makeRequest(input)
            let requestRecord = RequestRecord(system: input.system, user: input.user,
                                              maxOutputTokens: input.maxOutputTokens, responseFormat: input.responseFormat.rawValue)
            report.request = requestRecord
            try writeNew(encode(requestRecord), to: output.appendingPathComponent("request.json"))
            report.runtime = try loadIdentity()
            let (provider, config) = try loadConfiguration()
            report.endpointURL = try validateConfiguration(provider: provider, config: config)
            report.provider = provider.rawValue
            let receipt = output.appendingPathComponent("provider-audit.jsonl")
            try writeNew(Data(), to: receipt)
            receiptURL = receipt
            let client = VoicePolishProviderAuditedLLMClient(base: clientFactory(provider),
                runNonce: report.runNonce, testInputID: input.caseID, receiptPath: receipt.path, successCounter: counter)
            let bodyPath = output.appendingPathComponent("request-body.json").path
            let response = try await AsyncTimeout.throwingValue(.seconds(30), timeoutError: ProbeError.timedOut) {
                try Task.checkCancellation()
                return try await VoicePolishProviderAudit.withRequestProbe(bodyPath: bodyPath) {
                    try await client.generate(request, config: config)
                }
            }
            let responseRecord = ResponseRecord(text: response.text, model: response.model,
                                                textSHA256: VoicePolishProviderAudit.sha256Hex(Data(response.text.utf8)))
            report.response = responseRecord
            try writeNew(encode(responseRecord), to: output.appendingPathComponent("response.json"))
            try validateReceipt(at: receipt, bodyURL: URL(fileURLWithPath: bodyPath), runNonce: report.runNonce,
                                caseID: input.caseID, response: response)
            report.receiptCount = 1
            report.status = "succeeded"
        } catch {
            // 不把底层错误消息、HTTP headers 或 LLMConfig 编码到报告。
            report.failureCode = (error as? ProbeError)?.rawValue ?? "request_failed"
        }
        report.stageResponses = await counter.stageResponses().map { stage in
            var safe = stage
            if safe.failureReason != nil { safe.failureReason = "client_failed" }
            return safe
        }
        report.attemptCount = report.stageResponses.count
        if let receiptURL {
            if let data = try? Data(contentsOf: receiptURL), data.isEmpty || data.last == 0x0A {
                report.receiptCount = data.split(separator: 0x0A, omittingEmptySubsequences: true).count
            } else {
                report.receiptCount = nil
            }
        }
        report.finishedAt = Date()
        report.elapsedMilliseconds = VoicePolishQualityRunner.milliseconds(ContinuousClock.now - start)
        try writeNew(encode(report), to: output.appendingPathComponent("probe-report.json"))
        return report
    }

    @MainActor
    static func startIfRequested(arguments: [String]) -> Bool {
        guard arguments.contains(argument) else { return false }
        let invocation: Invocation
        do {
            guard let parsed = try parseInvocation(arguments: arguments) else { return false }
            invocation = parsed
        } catch {
            print("VOICE_POLISH_REQUEST_PROBE_FAILED invalid_arguments")
            NSApp.terminate(nil); return true
        }
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                // 运行目录必须是明确的 Dal 源工作区；不能把用户目录当输出根。
                try requireRegular(workspace.appendingPathComponent("Package.swift"))
                try requireRegular(workspace.appendingPathComponent("Dal/VoicePolish/VoicePolishQualityRunner.swift"))
                let report = try await execute(invocation: invocation, workspaceRoot: workspace,
                    loadIdentity: runtimeIdentity,
                    loadConfiguration: {
                        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                            throw ProbeError.configurationUnavailable
                        }
                        let provider = KeychainService.selectedPolishProvider(for: .light)
                        guard provider == .deepseek else { throw ProbeError.configurationMismatch }
                        guard let config = KeychainService.loadPolishConfig(for: .light) else { throw ProbeError.configurationUnavailable }
                        return (provider, config)
                    }, clientFactory: { LLMProviderRegistry.makeClient(for: $0) })
                print("VOICE_POLISH_REQUEST_PROBE_FINISHED status=\(report.status) attempts=\(report.attemptCount)")
            } catch {
                print("VOICE_POLISH_REQUEST_PROBE_FAILED startup_or_evidence")
            }
            NSApp.terminate(nil)
        }
        return true
    }

    private static func runtimeIdentity() throws -> RuntimeIdentity {
        guard let commit = Bundle.main.object(forInfoDictionaryKey: "DalSourceCommit") as? String,
              commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil,
              let executable = Bundle.main.executableURL,
              let data = try? Data(contentsOf: executable) else { throw ProbeError.runtimeIdentityUnavailable }
        return RuntimeIdentity(commit: commit, executableSHA256: VoicePolishProviderAudit.sha256Hex(data),
                               processID: ProcessInfo.processInfo.processIdentifier)
    }

    private static func validateReceipt(at url: URL, bodyURL: URL, runNonce: String, caseID: String,
                                        response: LLMResponse) throws {
        try requireRegular(url); try requireRegular(bodyURL)
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard data.last == 0x0A, lines.count == 1,
              let receipt = try? decoder.decode(VoicePolishProviderAuditReceipt.self, from: Data(lines[0])),
              receipt.schemaVersion == 2, receipt.runNonce == runNonce, receipt.testInputID == caseID,
              receipt.requestOrdinal == 1, receipt.llmTask == "voicePolishRender", receipt.provider == "deepseek",
              receipt.configuredModel == "deepseek-flash", receipt.responseModel == "deepseek-flash",
              response.model == "deepseek-flash", receipt.endpointURL == expectedEndpoint, receipt.httpStatus == 200,
              !receipt.providerResponseID.isEmpty,
              receipt.requestBodySHA256 == VoicePolishProviderAudit.sha256Hex(try Data(contentsOf: bodyURL)),
              receipt.responseTextSHA256 == VoicePolishProviderAudit.sha256Hex(Data(response.text.utf8)),
              receipt.requestBindingSHA256 == VoicePolishProviderAudit.requestBindingSHA256(runNonce: runNonce,
                  testInputID: caseID, requestOrdinal: 1, requestBodySHA256: receipt.requestBodySHA256) else {
            throw ProbeError.invalidReceipt
        }
    }

    private static func canonicalAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            && URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    private static func validatedWorkspacePath(_ path: String, root: URL) throws -> URL {
        guard canonicalAbsolutePath(path), canonicalAbsolutePath(root.path), root.path != "/",
              path.hasPrefix(root.path + "/") else { throw ProbeError.invalidPath }
        try rejectSymlinkAncestors(root)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else {
            throw ProbeError.invalidPath
        }
        return URL(fileURLWithPath: path)
    }

    private static func prepareOutput(_ path: String, workspaceRoot: URL) throws -> URL {
        let output = try validatedWorkspacePath(path, root: workspaceRoot)
        try rejectSymlinkAncestors(output.deletingLastPathComponent())
        var info = stat()
        guard lstat(path, &info) != 0, errno == ENOENT else { throw ProbeError.outputExists }
        guard mkdir(path, 0o700) == 0 else { throw ProbeError.fileFailure }
        return output
    }

    private static func readInput(_ path: String, workspaceRoot: URL) throws -> Data {
        let input = try validatedWorkspacePath(path, root: workspaceRoot)
        try requireRegular(input)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ProbeError.fileFailure }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumInputBytes else { throw ProbeError.invalidInput }
        let data = try handle.read(upToCount: maximumInputBytes + 1) ?? Data()
        guard data.count <= maximumInputBytes else { throw ProbeError.invalidInput }
        return data
    }

    private static func rejectSymlinkAncestors(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { throw ProbeError.invalidPath }
        }
    }

    private static func requireRegular(_ url: URL) throws {
        try rejectSymlinkAncestors(url)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ProbeError.invalidPath }
    }

    private static func writeNew(_ data: Data, to url: URL) throws {
        try rejectSymlinkAncestors(url.deletingLastPathComponent())
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ProbeError.fileFailure }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return Int(number.stringValue)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }

    private static func containsCredentialFields(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            let forbidden: Set<String> = ["apikey", "authorization", "credentials", "headers", "password", "accesstoken", "secret"]
            return object.contains { key, child in
                forbidden.contains(key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: ""))
                    || containsCredentialFields(child)
            }
        }
        return (value as? [Any])?.contains(where: containsCredentialFields) == true
    }

}
