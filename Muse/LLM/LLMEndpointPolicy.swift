import Foundation

enum LLMEndpointPolicyError: Error, LocalizedError, Equatable {
    case invalidURL
    case insecureScheme
    case disallowedHost
    case invalidPort
    case disallowedComponents
    case localQwenPortUnavailable
    case invalidLocalQwenEndpoint

    var errorDescription: String? {
        switch self {
        case .invalidURL, .disallowedComponents:
            return L("LLM 地址格式无效", "Invalid LLM URL")
        case .insecureScheme:
            return L("云端 LLM 地址必须使用 HTTPS", "Cloud LLM URL must use HTTPS")
        case .disallowedHost:
            return L("本地 LLM 的 HTTP 地址必须使用回环主机", "Local LLM HTTP URL must use a loopback host")
        case .invalidPort:
            return L("LLM 地址端口无效", "Invalid LLM URL port")
        case .localQwenPortUnavailable:
            return L("本地 Qwen 服务尚未启动", "Local Qwen service is not running")
        case .invalidLocalQwenEndpoint:
            return L("本地 Qwen 地址与当前服务不匹配", "Local Qwen URL does not match the active service")
        }
    }
}

enum LLMEndpointPolicy {
    static func normalizedBaseURL(
        rawValue: String,
        provider: LLMProvider,
        localQwenPort: Int? = nil
    ) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? provider.defaultBaseURL : trimmed
        guard hasValidExplicitPortSyntax(candidate) else {
            throw LLMEndpointPolicyError.invalidPort
        }
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.query == nil
        else {
            throw LLMEndpointPolicyError.invalidURL
        }

        if let port = components.port, !(1...65_535).contains(port) {
            throw LLMEndpointPolicyError.invalidPort
        }
        guard components.url != nil else {
            throw LLMEndpointPolicyError.invalidURL
        }

        switch provider {
        case .localQwen:
            guard let localQwenPort else {
                throw LLMEndpointPolicyError.localQwenPortUnavailable
            }
            guard (1...65_535).contains(localQwenPort) else {
                throw LLMEndpointPolicyError.invalidPort
            }
            guard scheme == "http",
                  host == "127.0.0.1",
                  components.port == localQwenPort
            else {
                throw LLMEndpointPolicyError.invalidLocalQwenEndpoint
            }
        case .ollama:
            if scheme == "http" {
                guard isAllowedLoopbackHost(host) else {
                    throw LLMEndpointPolicyError.disallowedHost
                }
            } else if scheme != "https" {
                throw LLMEndpointPolicyError.insecureScheme
            }
        default:
            guard scheme == "https" else {
                throw LLMEndpointPolicyError.insecureScheme
            }
        }

        let pathSegments = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !pathSegments.contains("."), !pathSegments.contains("..") else {
            throw LLMEndpointPolicyError.disallowedComponents
        }
        components.scheme = scheme
        components.host = host
        components.percentEncodedPath = pathSegments.isEmpty ? "" : "/" + pathSegments.joined(separator: "/")

        if provider == .localQwen, components.percentEncodedPath != "/v1" {
            throw LLMEndpointPolicyError.invalidLocalQwenEndpoint
        }

        guard let normalized = components.url else {
            throw LLMEndpointPolicyError.invalidURL
        }
        return normalized
    }

    static func endpoint(baseURL: URL, pathComponents: [String]) throws -> URL {
        var endpoint = baseURL
        for component in pathComponents {
            guard !component.isEmpty,
                  component != ".",
                  component != "..",
                  !component.contains("/")
            else {
                throw LLMEndpointPolicyError.disallowedComponents
            }
            endpoint.appendPathComponent(component, isDirectory: false)
        }
        return endpoint
    }

    static var currentLocalQwenPort: Int? {
        #if arch(arm64)
        SenseVoiceServerManager.currentQwen3Port
        #else
        SenseVoiceServerManager.currentPort
        #endif
    }

    private static func isAllowedLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    private static func hasValidExplicitPortSyntax(_ value: String) -> Bool {
        guard let schemeRange = value.range(of: "://") else { return true }
        let remainder = value[schemeRange.upperBound...]
        let authority = remainder.prefix { character in
            character != "/" && character != "?" && character != "#"
        }
        let hostPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
        if hostPort.hasPrefix("[") {
            guard let closingBracket = hostPort.firstIndex(of: "]") else { return true }
            let suffix = hostPort[hostPort.index(after: closingBracket)...]
            guard !suffix.isEmpty else { return true }
            guard suffix.first == ":" else { return true }
            return isValidPortText(suffix.dropFirst())
        }
        guard let colon = hostPort.lastIndex(of: ":") else { return true }
        return isValidPortText(hostPort[hostPort.index(after: colon)...])
    }

    private static func isValidPortText(_ text: Substring) -> Bool {
        guard !text.isEmpty,
              text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(text),
              (1...65_535).contains(port)
        else {
            return false
        }
        return true
    }
}

final class LLMRedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum LLMNetworkSession {
    static let shared = makeSession()

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        return configuration
    }

    static func makeSession() -> URLSession {
        URLSession(
            configuration: makeConfiguration(),
            delegate: LLMRedirectBlockingDelegate(),
            delegateQueue: nil
        )
    }

    static func sanitizedErrorBody(_ data: Data, limit: Int = 512) -> String {
        let inspectionLimit = max(0, limit) + 4_096
        let text = LogRedactor.redact(
            String(decoding: data.prefix(inspectionLimit), as: UTF8.self)
        )
        let maximum = max(0, limit)
        let utf8 = Data(text.utf8)
        guard utf8.count > maximum else { return text }
        var end = maximum
        while end > 0 {
            if let bounded = String(data: utf8.prefix(end), encoding: .utf8) {
                return bounded
            }
            end -= 1
        }
        return ""
    }

    static func readPrefix<S: AsyncSequence>(
        _ sequence: S,
        limit: Int
    ) async throws -> Data where S.Element == UInt8 {
        let maximum = max(0, limit)
        var data = Data()
        data.reserveCapacity(maximum)
        guard maximum > 0 else { return data }
        for try await byte in sequence {
            guard data.count < maximum else { break }
            data.append(byte)
        }
        return data
    }

    static func readCapped<S: AsyncSequence>(
        _ sequence: S,
        limit: Int
    ) async throws -> Data where S.Element == UInt8 {
        let maximum = max(0, limit)
        var data = Data()
        data.reserveCapacity(maximum)
        for try await byte in sequence {
            guard data.count < maximum else {
                throw LLMError.responseTooLarge(maximum)
            }
            data.append(byte)
        }
        return data
    }
}

struct SSEByteStreamDecoder: Sendable {
    static let defaultMaximumTotalBytes = 16 * 1_024 * 1_024
    static let defaultMaximumLineBytes = 4 * 1_024 * 1_024

    private let maximumTotalBytes: Int
    private let maximumLineBytes: Int
    private var totalBytes = 0
    private var lineBytes: [UInt8] = []

    init(
        maximumTotalBytes: Int = defaultMaximumTotalBytes,
        maximumLineBytes: Int = defaultMaximumLineBytes
    ) {
        self.maximumTotalBytes = max(0, maximumTotalBytes)
        self.maximumLineBytes = max(0, maximumLineBytes)
    }

    mutating func consume(byte: UInt8) throws -> String? {
        guard totalBytes < maximumTotalBytes else {
            throw LLMError.responseTooLarge(maximumTotalBytes)
        }
        totalBytes += 1

        if byte == 0x0A {
            return takeLine()
        }
        guard lineBytes.count < maximumLineBytes else {
            throw LLMError.responseTooLarge(maximumLineBytes)
        }
        lineBytes.append(byte)
        return nil
    }

    mutating func finish() throws -> String? {
        guard !lineBytes.isEmpty else { return nil }
        return takeLine()
    }

    private mutating func takeLine() -> String {
        if lineBytes.last == 0x0D {
            lineBytes.removeLast()
        }
        let line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)
        return line
    }
}

struct SSEEventAccumulator: Sendable {
    static let defaultMaximumEventBytes = 4 * 1_024 * 1_024

    private var dataLines: [String] = []
    private var eventBytes = 0
    private let maximumEventBytes: Int

    init(maximumEventBytes: Int = defaultMaximumEventBytes) {
        self.maximumEventBytes = max(0, maximumEventBytes)
    }

    mutating func consume(line rawLine: String) throws -> [String] {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            return flush()
        }
        guard line.hasPrefix("data:") else { return [] }
        var payload = String(line.dropFirst(5))
        if payload.hasPrefix(" ") {
            payload.removeFirst()
        }
        if payload == "[DONE]" {
            var events = flush()
            events.append(payload)
            return events
        }
        let separatorBytes = dataLines.isEmpty ? 0 : 1
        let additionalBytes = payload.utf8.count + separatorBytes
        guard additionalBytes <= maximumEventBytes - eventBytes else {
            throw LLMError.responseTooLarge(maximumEventBytes)
        }
        dataLines.append(payload)
        eventBytes += additionalBytes
        return []
    }

    mutating func finish() -> [String] {
        flush()
    }

    private mutating func flush() -> [String] {
        guard !dataLines.isEmpty else { return [] }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        eventBytes = 0
        return [payload]
    }
}

struct LLMStreamingParser: Sendable {
    static let defaultMaximumResponseBytes = 2 * 1_024 * 1_024

    private var events: SSEEventAccumulator
    private var result = ""
    private var resultBytes = 0
    var hasContent: Bool { !result.isEmpty }
    private let maxResponseBytes: Int
    private(set) var isComplete = false
    private(set) var reasoningObserved = false
    private(set) var hitOutputTokenLimit = false

    init(
        maxResponseBytes: Int = defaultMaximumResponseBytes,
        maxEventBytes: Int = SSEEventAccumulator.defaultMaximumEventBytes
    ) {
        self.maxResponseBytes = max(0, maxResponseBytes)
        self.events = SSEEventAccumulator(maximumEventBytes: maxEventBytes)
    }

    mutating func consume(line: String) throws {
        guard !isComplete else { return }
        for payload in try events.consume(line: line) {
            try consume(payload: payload)
        }
    }

    /// 思考探针只提取证据，不交付题目答案；正常结束但答案耗尽预算不等于连接中断。
    /// 没有推理证据仍交给上层差分验证；正文生成及缺失结束标志的流继续严格校验。
    mutating func finish(allowIncompleteProbeAnswer: Bool = false) throws -> String {
        if !isComplete {
            for payload in events.finish() {
                try consume(payload: payload)
            }
        }
        guard isComplete else {
            throw LLMError.truncatedResponse(result.count)
        }
        if allowIncompleteProbeAnswer, reasoningObserved || !result.isEmpty { return result }
        guard !hitOutputTokenLimit else {
            throw LLMError.truncatedResponse(result.count)
        }
        guard !result.isEmpty else {
            throw LLMError.emptyResponse(nil)
        }
        return result
    }

    mutating func errorForStreamFailure(_ streamError: Error) -> Error {
        if Task.isCancelled {
            return CancellationError()
        }
        if streamError is CancellationError
            || (streamError as? URLError)?.code == .cancelled
            || streamError is LLMError {
            return streamError
        }
        do {
            for payload in events.finish() {
                try consume(payload: payload)
            }
        } catch {
            return error
        }
        return result.isEmpty ? streamError : LLMError.truncatedResponse(result.count)
    }

    private mutating func consume(payload: String) throws {
        if payload == "[DONE]" {
            isComplete = true
            return
        }
        guard let data = payload.data(using: .utf8) else {
            throw LLMError.malformedResponse
        }
        let chunk: ChatStreamChunk
        do {
            chunk = try JSONDecoder().decode(ChatStreamChunk.self, from: data)
        } catch {
            DebugFileLogger.log("OpenAI-compatible streaming chunk decode failed bytes=\(data.count)")
            throw LLMError.malformedResponse
        }

        if (chunk.usage?.completion_tokens_details?.reasoning_tokens ?? 0) > 0 {
            reasoningObserved = true
        }
        for choice in chunk.choices {
            if choice.delta?.reasoningObserved == true {
                reasoningObserved = true
            }
            if let content = choice.delta?.content, !content.isEmpty {
                if content.contains("<think>") {
                    reasoningObserved = true
                }
                let additionalBytes = content.utf8.count
                guard additionalBytes <= maxResponseBytes - resultBytes else {
                    throw LLMError.responseTooLarge(maxResponseBytes)
                }
                result += content
                resultBytes += additionalBytes
            }
            if let finishReason = choice.finish_reason?.trimmingCharacters(in: .whitespacesAndNewlines),
               !finishReason.isEmpty {
                if LLMCompletionTermination.hitOutputTokenLimit(finishReason) {
                    hitOutputTokenLimit = true
                }
                isComplete = true
            }
        }
    }
}

enum LLMCompletionTermination {
    static func hitOutputTokenLimit(_ reason: String?) -> Bool {
        guard let normalized = reason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else { return false }
        return normalized == "length"
            || normalized == "max_tokens"
            || normalized == "max_output_tokens"
    }
}
