import Foundation
import Compression

// MARK: - Result Types

struct VolcUtterance: Sendable, Equatable {
    let text: String
    let definite: Bool
}

struct VolcASRResult: Sendable, Equatable {
    let text: String
    let utterances: [VolcUtterance]
}

struct VolcServerResponse: Sendable, Equatable {
    let header: VolcHeader
    let result: VolcASRResult
}

// MARK: - Protocol Functions

enum VolcProtocol: Sendable {
    static let maximumCompressedPayloadBytes = 4 * 1_024 * 1_024
    static let maximumDecompressedPayloadBytes = 16 * 1_024 * 1_024
    static let maximumUtteranceCount = 10_000
    static let maximumTextBytes = 1 * 1_024 * 1_024
    static let maximumServerErrorMessageBytes = 4 * 1_024

    // MARK: - Build Client Request JSON

    static func buildClientRequest(
        uid: String,
        format: String = "pcm",
        codec: String = "raw",
        rate: Int = 16000,
        bits: Int = 16,
        channel: Int = 1,
        showUtterances: Bool = true,
        resultType: String = "full",
        options: ASRRequestOptions = ASRRequestOptions()
    ) -> Data {
        var requestDict: [String: Any] = [
            "model_name": "bigmodel",
            "enable_punc": options.enablePunc,
            "enable_ddc": true,
            "enable_nonstream": true,
            "show_utterances": showUtterances,
            "result_type": resultType,
            "end_window_size": 3000,
            "force_to_speech_time": 1000,
        ]

        if let contextString = buildContextString(
            hotwords: options.hotwords,
            userHotwordCount: options.userHotwordCount,
            correctionWords: options.correctionWords
        ) {
            requestDict["context"] = contextString
        }

        var corpus: [String: Any] = [:]
        if let boostingTableID = sanitized(options.boostingTableID) {
            corpus["boosting_table_id"] = boostingTableID
        }
        if !corpus.isEmpty {
            requestDict["corpus"] = corpus
        }

        if options.contextHistoryLength > 0 {
            requestDict["context_history_length"] = options.contextHistoryLength
        }

        let payload: [String: Any] = [
            "user": ["uid": uid],
            "audio": [
                "format": format,
                "codec": codec,
                "rate": rate,
                "bits": bits,
                "channel": channel,
            ],
            "request": requestDict,
        ]
        // Force-try is safe here: dictionary of known-serializable types
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private static func buildContextString(
        hotwords: [String],
        userHotwordCount: Int,
        correctionWords: [String: String]
    ) -> String? {
        var contextObject: [String: Any] = [:]

        var seenHotwords = Set<String>()
        var cleanedUserHotwordCount = 0
        let cleanedHotwords = hotwords.enumerated().compactMap { index, word -> String? in
            let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            let key = cleaned.lowercased()
            guard seenHotwords.insert(key).inserted else { return nil }
            if index < max(userHotwordCount, 0) {
                cleanedUserHotwordCount += 1
            }
            return cleaned
        }
        if !cleanedHotwords.isEmpty {
            // 火山请求级热词的官方格式只声明 word。此前附带的 scale 无文档背书，
            // 可能导致服务端忽略所谓权重；用户词优先级由上游顺序保持。
            contextObject["hotwords"] = cleanedHotwords.map { word in
                ["word": word] as [String: Any]
            }
        }

        let userHotwords = Array(cleanedHotwords.prefix(cleanedUserHotwordCount))
        var effectiveCorrections = automaticCorrectionWords(for: userHotwords)
        // 用户手工配置的错词纠正优先于自动格式变体。
        for (trigger, replacement) in correctionWords {
            let cleanedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedTrigger.isEmpty, !cleanedReplacement.isEmpty else { continue }
            effectiveCorrections[cleanedTrigger] = cleanedReplacement
        }
        if !effectiveCorrections.isEmpty {
            contextObject["correct_words"] = effectiveCorrections
        }

        guard !contextObject.isEmpty,
              let contextData = try? JSONSerialization.data(withJSONObject: contextObject),
              let contextString = String(data: contextData, encoding: .utf8)
        else {
            return nil
        }
        return contextString
    }

    /// 用户只输入正确词，后台自动补常见的英文大小写、CamelCase 分词与扩展名口语形式。
    /// 中文同音错词无法可靠猜测，仍由「错词纠正」让用户明确指定，避免误替换。
    private static func automaticCorrectionWords(for hotwords: [String]) -> [String: String] {
        var corrections: [String: String] = [:]

        for canonical in hotwords {
            var variants: [String] = []
            func appendVariant(_ value: String) {
                let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, cleaned != canonical, !variants.contains(cleaned) else { return }
                variants.append(cleaned)
            }

            appendVariant(canonical.lowercased())

            let camelSpaced = splitCamelCase(canonical)
            appendVariant(camelSpaced)
            appendVariant(camelSpaced.lowercased())

            if canonical.contains(".") {
                let spaceVariant = canonical.replacingOccurrences(of: ".", with: " ")
                appendVariant(spaceVariant)
                appendVariant(spaceVariant.lowercased())

                let chineseDotVariant = canonical.replacingOccurrences(of: ".", with: "点")
                appendVariant(chineseDotVariant)
                appendVariant(chineseDotVariant.lowercased())
            }

            for variant in variants where corrections[variant] == nil {
                corrections[variant] = canonical
            }
        }

        return corrections
    }

    private static func splitCamelCase(_ value: String) -> String {
        var result = ""
        var previous: Character?
        for character in value {
            if let previous,
               character.isUppercase,
               previous.isLowercase || previous.isNumber {
                result.append(" ")
            }
            result.append(character)
            previous = character
        }
        return result
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    // MARK: - Encode Full Binary Message

    static func encodeMessage(
        header: VolcHeader,
        payload: Data,
        sequenceNumber: Int32? = nil
    ) -> Data {
        var message = header.encode()

        // Append sequence number if flagged
        if let seq = sequenceNumber {
            var seqBig = seq.bigEndian
            message.append(Data(bytes: &seqBig, count: 4))
        }

        // Append payload size (4 bytes big-endian) + payload
        var size = UInt32(payload.count).bigEndian
        message.append(Data(bytes: &size, count: 4))
        message.append(payload)

        return message
    }

    // MARK: - Encode Audio Packet

    static func encodeAudioPacket(
        audioData: Data,
        isLast: Bool
    ) -> Data {
        let flags: VolcMessageFlags = isLast ? .lastPacketNoSequence : .noSequence
        let header = VolcHeader(
            messageType: .audioOnlyRequest,
            flags: flags,
            serialization: .none,
            compression: .none
        )
        return encodeMessage(header: header, payload: audioData)
    }

    // MARK: - Decode Server Message

    static func decodeServerResponse(_ data: Data) throws -> VolcServerResponse {
        let header = try VolcHeader.decode(from: data)
        let headerBytes = Int(header.headerSize) * 4
        var offset = headerBytes

        // Skip sequence number if present
        if header.flags.hasSequence {
            guard data.count - offset >= 4 else {
                throw VolcProtocolError.truncatedSequence
            }
            offset += 4
        }

        // 火山官方错误帧格式与普通响应不同：header + error code + payload size + payload。
        // 先识别官方格式；若长度不吻合，再兼容历史的 header + size + JSON payload。
        if header.messageType == .serverError,
           data.count - offset >= 8 {
            let code = Int(readBigEndianUInt32(from: data, offset: offset))
            let payloadSize = Int(readBigEndianUInt32(from: data, offset: offset + 4))
            let payloadOffset = offset + 8
            if payloadSize == data.count - payloadOffset {
                let payload = try decodePayload(
                    from: data,
                    offset: payloadOffset,
                    size: payloadSize,
                    compression: header.compression
                )
                throw serverError(from: payload, fallbackCode: code)
            }
        }

        guard data.count - offset >= 4 else {
            throw VolcProtocolError.invalidPayload
        }

        // 逐字节组合，避免 Data slice 的起始地址未对齐时触发 load(as:) 崩溃。
        let payloadSize = Int(readBigEndianUInt32(from: data, offset: offset))
        offset += 4

        let payload = try decodePayload(
            from: data,
            offset: offset,
            size: payloadSize,
            compression: header.compression
        )

        // Handle server error
        if header.messageType == .serverError {
            throw serverError(from: payload, fallbackCode: nil)
        }

        // Parse JSON
        guard header.serialization == .json else {
            throw VolcProtocolError.invalidPayload
        }

        try validateDecodedPayloadSize(payload)
        guard let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw VolcProtocolError.invalidPayload
        }

        // Response format: {"result": {"text": "...", "utterances": [...]}, "audio_info": {...}}
        let resultObj = json["result"] as? [String: Any]
        let text = resultObj?["text"] as? String ?? json["text"] as? String ?? ""
        try validateTextSize(text)
        var utterances: [VolcUtterance] = []

        let uttsSource = resultObj?["utterances"] as? [[String: Any]]
            ?? json["utterances"] as? [[String: Any]]
        if let utts = uttsSource {
            guard utts.count <= maximumUtteranceCount else {
                throw VolcProtocolError.tooManyUtterances(
                    limit: maximumUtteranceCount,
                    actual: utts.count
                )
            }
            utterances.reserveCapacity(utts.count)
            for utterance in utts {
                let utteranceText = utterance["text"] as? String ?? ""
                try validateTextSize(utteranceText)
                utterances.append(
                    VolcUtterance(
                        text: utteranceText,
                        definite: utterance["definite"] as? Bool ?? false
                    )
                )
            }
        }

        return VolcServerResponse(
            header: header,
            result: VolcASRResult(text: text, utterances: utterances)
        )
    }

    // MARK: - Gzip

    private static func readBigEndianUInt32(from data: Data, offset: Int) -> UInt32 {
        let start = data.index(data.startIndex, offsetBy: offset)
        let byte0 = UInt32(data[start])
        let byte1 = UInt32(data[data.index(start, offsetBy: 1)])
        let byte2 = UInt32(data[data.index(start, offsetBy: 2)])
        let byte3 = UInt32(data[data.index(start, offsetBy: 3)])
        return (byte0 << 24) | (byte1 << 16) | (byte2 << 8) | byte3
    }

    private static func decodePayload(
        from data: Data,
        offset: Int,
        size: Int,
        compression: VolcCompression
    ) throws -> Data {
        let maximumWirePayloadBytes = compression == .gzip
            ? maximumCompressedPayloadBytes
            : maximumDecompressedPayloadBytes
        guard size <= maximumWirePayloadBytes else {
            throw VolcProtocolError.payloadTooLarge(
                limit: maximumWirePayloadBytes,
                actual: size
            )
        }
        guard offset >= 0, offset <= data.count, size >= 0, size <= data.count - offset else {
            throw VolcProtocolError.invalidPayload
        }

        let payloadStart = data.index(data.startIndex, offsetBy: offset)
        let payloadEnd = data.index(payloadStart, offsetBy: size)
        var payload = Data(data[payloadStart ..< payloadEnd])
        if compression == .gzip {
            payload = try gzipDecompress(
                payload,
                maximumOutputBytes: maximumDecompressedPayloadBytes
            )
        }
        try validateDecodedPayloadSize(payload)
        return payload
    }

    private static func serverError(
        from payload: Data,
        fallbackCode: Int?
    ) -> VolcProtocolError {
        if !payload.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            let code = json["code"] as? Int ?? fallbackCode
            let message = ((json["message"] as? String) ?? (json["msg"] as? String))
                .map(boundedServerErrorMessage)
            return .serverError(code: code, message: message)
        }
        return .serverError(
            code: fallbackCode,
            message: boundedServerErrorBody(payload)
        )
    }

    private static func validateDecodedPayloadSize(_ payload: Data) throws {
        guard payload.count <= maximumDecompressedPayloadBytes else {
            throw VolcProtocolError.payloadTooLarge(
                limit: maximumDecompressedPayloadBytes,
                actual: payload.count
            )
        }
    }

    private static func validateTextSize(_ text: String) throws {
        guard text.utf8.count <= maximumTextBytes else {
            throw VolcProtocolError.textTooLarge(limit: maximumTextBytes)
        }
    }

    private static func boundedServerErrorMessage(_ message: String) -> String {
        guard message.utf8.count > maximumServerErrorMessageBytes else {
            return message
        }

        var prefix = Data(message.utf8.prefix(maximumServerErrorMessageBytes))
        while !prefix.isEmpty, String(data: prefix, encoding: .utf8) == nil {
            prefix.removeLast()
        }
        return String(data: prefix, encoding: .utf8) ?? ""
    }

    private static func boundedServerErrorBody(_ payload: Data) -> String? {
        guard !payload.isEmpty else { return nil }
        let boundedBytes = payload.prefix(maximumServerErrorMessageBytes)
        return boundedServerErrorMessage(String(decoding: boundedBytes, as: UTF8.self))
    }

    private static func processStream(
        operation: compression_stream_operation,
        source: Data,
        maximumOutputBytes: Int
    ) throws -> Data {
        guard maximumOutputBytes >= 0 else {
            throw VolcProtocolError.invalidPayload
        }

        let pageSize = 16384
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: pageSize)
        defer { dstBuffer.deallocate() }

        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }

        let initStatus = compression_stream_init(streamPtr, operation, COMPRESSION_ZLIB)
        guard initStatus == COMPRESSION_STATUS_OK else {
            throw VolcProtocolError.decompressionFailed
        }
        defer { compression_stream_destroy(streamPtr) }

        return try source.withUnsafeBytes { (srcPointer: UnsafeRawBufferPointer) throws -> Data in
            guard let srcBase = srcPointer.baseAddress else {
                throw VolcProtocolError.decompressionFailed
            }

            streamPtr.pointee.src_ptr = srcBase.assumingMemoryBound(to: UInt8.self)
            streamPtr.pointee.src_size = source.count

            var output = Data()

            repeat {
                streamPtr.pointee.dst_ptr = dstBuffer
                streamPtr.pointee.dst_size = pageSize
                let sourceBytesBefore = streamPtr.pointee.src_size

                let status = compression_stream_process(streamPtr, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

                let produced = pageSize - streamPtr.pointee.dst_size
                if produced > 0 {
                    guard produced <= maximumOutputBytes - output.count else {
                        throw VolcProtocolError.payloadTooLarge(
                            limit: maximumOutputBytes,
                            actual: output.count + produced
                        )
                    }
                    output.append(dstBuffer, count: produced)
                }

                if status == COMPRESSION_STATUS_END {
                    return output
                }
                if status == COMPRESSION_STATUS_ERROR {
                    throw VolcProtocolError.decompressionFailed
                }
                if produced == 0, streamPtr.pointee.src_size == sourceBytesBefore {
                    throw VolcProtocolError.decompressionFailed
                }
            } while true
        }
    }

    static func gzipDecompress(
        _ data: Data,
        maximumOutputBytes: Int
    ) throws -> Data {
        guard !data.isEmpty else { return Data() }
        return try processStream(
            operation: COMPRESSION_STREAM_DECODE,
            source: data,
            maximumOutputBytes: maximumOutputBytes
        )
    }
}
