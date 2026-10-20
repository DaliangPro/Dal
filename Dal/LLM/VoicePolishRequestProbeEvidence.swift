import Darwin
import Foundation

extension VoicePolishProviderAudit {
    /// 仅显式请求实验启用；调用方必须在实际 generate 所在任务内设置。
    @TaskLocal static var requestProbeBodyPath: String?

    static func withRequestProbe<T>(
        bodyPath: String,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $requestProbeBodyPath.withValue(bodyPath, operation: operation)
    }
}

/// 记录已经编码、即将交给 URLSession 的正文；不接收请求头或配置对象。
/// 独立于既有 quality report 和 Provider receipt，普通调用没有文件副作用。
final class VoicePolishRequestProbeEvidence {
    private let responseHandle: FileHandle
    private let bodySHA256: String

    private init(responseHandle: FileHandle, bodySHA256: String) {
        self.responseHandle = responseHandle
        self.bodySHA256 = bodySHA256
    }

    deinit { try? responseHandle.close() }

    static func captureIfRequested(body: Data?, task: LLMTask?) throws -> VoicePolishRequestProbeEvidence? {
        guard let path = VoicePolishProviderAudit.requestProbeBodyPath else { return nil }
        guard let audit = VoicePolishProviderAudit.currentContext, let task, let body else {
            throw ProbeError.missingAuditContext
        }
        let parameterKeys: Set<String> = [
            "model", "stream", "temperature", "max_tokens", "thinking", "response_format",
            "enable_thinking", "reasoning_effort", "reasoning", "think", "reasoning_split"
        ]
        guard let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(decoded.keys).isSubset(of: parameterKeys.union(["messages"])),
              let messages = decoded["messages"] as? [[String: Any]], !messages.isEmpty else {
            throw ProbeError.invalidBody
        }
        let messageEvidence: [[String: Any]] = try messages.enumerated().map { index, message in
            guard Set(message.keys) == ["role", "content"],
                  let role = message["role"] as? String,
                  let content = message["content"] as? String else { throw ProbeError.invalidBody }
            let bytes = Data(content.utf8)
            return ["index": index, "role": role, "content_utf8_bytes": bytes.count,
                    "content_sha256": VoicePolishProviderAudit.sha256Hex(bytes)]
        }
        let digest = VoicePolishProviderAudit.sha256Hex(body)
        let metadata: [String: Any] = [
            "schema_version": 1,
            "evidence_kind": "actual_encoded_http_body_before_send",
            "run_nonce": audit.runNonce, "test_input_id": audit.testInputID,
            "llm_task": task.rawValue,
            "request_body_file": path, "request_body_sha256": digest,
            "request_body_utf8_bytes": body.count,
            "parameters": decoded.filter { parameterKeys.contains($0.key) },
            "messages": messageEvidence,
            "message_content_location": "原文逐字保存在 request_body_file 的 messages 中；此处摘要基于已编码正文解码所得 UTF-8。",
            "response_evidence_file": path + ".response.json"
        ]
        let encodedMetadata = try encode(metadata)
        let (directory, filename) = try openParent(of: path)
        defer { Darwin.close(directory) }
        // 所有文件在发送前独占创建；任何冲突或符号链接均阻断本次实验请求。
        // 失败时保留已创建的部分证据，不覆盖或清理原有文件。
        let bodyHandle = try createFile(filename, in: directory)
        defer { try? bodyHandle.close() }
        let metadataHandle = try createFile(filename + ".metadata.json", in: directory)
        defer { try? metadataHandle.close() }
        let responseHandle = try createFile(filename + ".response.json", in: directory)
        do {
            try bodyHandle.write(contentsOf: body)
            try bodyHandle.synchronize()
            try metadataHandle.write(contentsOf: encodedMetadata)
            try metadataHandle.synchronize()
            return VoicePolishRequestProbeEvidence(responseHandle: responseHandle, bodySHA256: digest)
        } catch {
            try? responseHandle.close()
            throw error
        }
    }

    func recordResponse(
        status: String, text: String? = nil, httpStatus: Int? = nil,
        responseModel: String? = nil, transport: String? = nil
    ) throws {
        var evidence: [String: Any] = [
            "schema_version": 1, "status": status, "request_body_sha256": bodySHA256,
            "finish_reason": "unknown", "usage": "unknown",
            "unknown_reason": "当前客户端解析结果未公开 finish_reason 或完整 usage；本实验不推测这些值。"
        ]
        if let text { evidence["response_text_sha256"] = VoicePolishProviderAudit.sha256Hex(Data(text.utf8)) }
        if let httpStatus { evidence["http_status"] = httpStatus }
        if let responseModel { evidence["response_model"] = responseModel }
        if let transport { evidence["transport"] = transport }
        try responseHandle.write(contentsOf: Self.encode(evidence))
        try responseHandle.synchronize()
        try responseHandle.close()
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        var bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        bytes.append(0x0A)
        return bytes
    }

    private static func openParent(of path: String) throws -> (Int32, String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.utf8.contains(0), parts.count >= 2, parts.first == "", parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let filename = parts.last else { throw ProbeError.invalidPath }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ProbeError.invalidPath }
        for part in parts.dropFirst().dropLast() {
            let next = Darwin.openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(directory)
            guard next >= 0 else { throw ProbeError.invalidPath }
            directory = next
        }
        return (directory, String(filename))
    }

    private static func createFile(_ name: String, in directory: Int32) throws -> FileHandle {
        let descriptor = Darwin.openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw ProbeError.exclusiveCreationFailed }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private enum ProbeError: LocalizedError {
        case missingAuditContext, invalidBody, invalidPath, exclusiveCreationFailed

        var errorDescription: String? {
            switch self {
            case .missingAuditContext: return "请求实验缺少既有 Provider 审计上下文、任务或实际正文。"
            case .invalidBody: return "请求实验的实际编码正文不符合参数与消息字段白名单。"
            case .invalidPath: return "请求实验证据必须使用已存在且不含符号链接的绝对目录。"
            case .exclusiveCreationFailed: return "请求实验证据文件必须全新创建，不能覆盖已有文件或符号链接。"
            }
        }
    }
}
