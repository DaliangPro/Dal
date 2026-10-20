import XCTest
import Compression
@testable import Dal

final class VolcProtocolTests: XCTestCase {

    // MARK: - Header Encoding

    func testHeaderEncoding_fullClientRequest() {
        let header = VolcHeader(
            messageType: .fullClientRequest,
            flags: .noSequence,
            serialization: .json,
            compression: .gzip
        )
        let data = header.encode()
        XCTAssertEqual(data.count, 4)
        // Byte 0: version=1 (0001) | headerSize=1 (0001) => 0x11
        XCTAssertEqual(data[0], 0x11)
        // Byte 1: msgType=0001 | flags=0000 => 0x10
        XCTAssertEqual(data[1], 0x10)
        // Byte 2: serialization=0001 | compression=0001 => 0x11
        XCTAssertEqual(data[2], 0x11)
        // Byte 3: reserved
        XCTAssertEqual(data[3], 0x00)
    }

    func testHeaderEncoding_audioData() {
        let header = VolcHeader(
            messageType: .audioOnlyRequest,
            flags: .positiveSequence,
            serialization: .none,
            compression: .none
        )
        let data = header.encode()
        XCTAssertEqual(data.count, 4)
        // Byte 0: 0x11
        XCTAssertEqual(data[0], 0x11)
        // Byte 1: msgType=0010 | flags=0001 => 0x21
        XCTAssertEqual(data[1], 0x21)
        // Byte 2: ser=0000 | comp=0000 => 0x00
        XCTAssertEqual(data[2], 0x00)
        XCTAssertEqual(data[3], 0x00)
    }

    func testHeaderEncoding_lastAudioPacket() {
        let header = VolcHeader(
            messageType: .audioOnlyRequest,
            flags: .negativeSequenceLast,
            serialization: .none,
            compression: .none
        )
        let data = header.encode()
        // Byte 1: msgType=0010 | flags=0011 => 0x23
        XCTAssertEqual(data[1], 0x23)
    }

    // MARK: - Header Decoding

    func testHeaderDecoding_serverResponse() throws {
        let raw = Data([0x11, 0x90, 0x11, 0x00])
        let header = try VolcHeader.decode(from: raw)
        XCTAssertEqual(header.version, 1)
        XCTAssertEqual(header.headerSize, 1)
        XCTAssertEqual(header.messageType, .serverResponse)
        XCTAssertEqual(header.flags, .noSequence)
        XCTAssertEqual(header.serialization, .json)
        XCTAssertEqual(header.compression, .gzip)
    }

    func testHeaderDecoding_serverError() throws {
        let raw = Data([0x11, 0xF0, 0x10, 0x00])
        let header = try VolcHeader.decode(from: raw)
        XCTAssertEqual(header.messageType, .serverError)
        XCTAssertEqual(header.serialization, .json)
        XCTAssertEqual(header.compression, .none)
    }

    func testHeaderDecoding_asyncFinal() throws {
        let raw = Data([0x11, 0x94, 0x10, 0x00])
        let header = try VolcHeader.decode(from: raw)
        XCTAssertEqual(header.messageType, .serverResponse)
        XCTAssertEqual(header.flags, .asyncFinal)
        XCTAssertEqual(header.flags.hasSequence, false)
    }

    func testHeaderDecoding_tooShort() {
        let raw = Data([0x11, 0x90])
        XCTAssertThrowsError(try VolcHeader.decode(from: raw))
    }

    func testHeaderDecodingRejectsUnsupportedVersion() {
        let raw = Data([0x21, 0x90, 0x10, 0x00])

        XCTAssertThrowsError(try VolcHeader.decode(from: raw)) { error in
            guard case VolcProtocolError.unsupportedVersion(let version) = error else {
                XCTFail("Expected unsupportedVersion, got \(error)")
                return
            }
            XCTAssertEqual(version, 2)
        }
    }

    func testHeaderDecodingRejectsZeroHeaderSize() {
        let raw = Data([0x10, 0x90, 0x10, 0x00])

        XCTAssertThrowsError(try VolcHeader.decode(from: raw)) { error in
            guard case VolcProtocolError.invalidHeaderSize(let headerSize) = error else {
                XCTFail("Expected invalidHeaderSize, got \(error)")
                return
            }
            XCTAssertEqual(headerSize, 0)
        }
    }

    func testHeaderDecodingRejectsHeaderSizeBeyondInput() {
        let raw = Data([0x12, 0x90, 0x10, 0x00])

        XCTAssertThrowsError(try VolcHeader.decode(from: raw)) { error in
            guard case VolcProtocolError.invalidHeaderSize(let headerSize) = error else {
                XCTFail("Expected invalidHeaderSize, got \(error)")
                return
            }
            XCTAssertEqual(headerSize, 2)
        }
    }

    // MARK: - Client Request JSON

    func testClientRequestJSON() throws {
        let payload = VolcProtocol.buildClientRequest(uid: "test-user-123")
        let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        XCTAssertNotNil(json)

        let user = json?["user"] as? [String: Any]
        XCTAssertEqual(user?["uid"] as? String, "test-user-123")

        let audio = json?["audio"] as? [String: Any]
        XCTAssertEqual(audio?["format"] as? String, "pcm")
        XCTAssertEqual(audio?["codec"] as? String, "raw")
        XCTAssertEqual(audio?["rate"] as? Int, 16000)

        let request = json?["request"] as? [String: Any]
        XCTAssertEqual(request?["show_utterances"] as? Bool, true)
        XCTAssertEqual(request?["result_type"] as? String, "full")
        XCTAssertEqual(request?["enable_nonstream"] as? Bool, true)
        XCTAssertEqual(request?["enable_ddc"] as? Bool, true)
        XCTAssertNil(request?["context"])
    }

    func testClientRequestJSON_usesHotwordsAndBoostingCorpusFields() throws {
        let payload = VolcProtocol.buildClientRequest(
            uid: "test-user-123",
            options: ASRRequestOptions(
                enablePunc: true,
                hotwords: ["OpenClaw", "Claude.md", "GitHub"],
                userHotwordCount: 2,
                correctionWords: ["大良": "大梁"],
                boostingTableID: "boost-123",
                contextHistoryLength: 6
            )
        )
        let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let request = json?["request"] as? [String: Any]
        XCTAssertEqual(request?["boosting_table_id"] as? String, nil)
        XCTAssertEqual(request?["context_history_length"] as? Int, 6)

        let contextString = request?["context"] as? String
        XCTAssertNotNil(contextString)
        let contextData = try XCTUnwrap(contextString?.data(using: .utf8))
        let context = try JSONSerialization.jsonObject(with: contextData) as? [String: Any]
        let hotwords = context?["hotwords"] as? [[String: Any]]
        XCTAssertEqual(hotwords?.count, 3)
        XCTAssertEqual(hotwords?.compactMap { $0["word"] as? String }, ["OpenClaw", "Claude.md", "GitHub"])
        XCTAssertTrue(hotwords?.allSatisfy { Set($0.keys) == ["word"] } == true)

        let corrections = context?["correct_words"] as? [String: String]
        XCTAssertEqual(corrections?["Open Claw"], "OpenClaw")
        XCTAssertEqual(corrections?["open claw"], "OpenClaw")
        XCTAssertEqual(corrections?["Claude md"], "Claude.md")
        XCTAssertEqual(corrections?["Claude点md"], "Claude.md")
        XCTAssertEqual(corrections?["大良"], "大梁")
        XCTAssertNil(corrections?["Git Hub"], "内置词不应自动生成用户专属格式纠正")

        let corpus = request?["corpus"] as? [String: Any]
        XCTAssertEqual(corpus?["boosting_table_id"] as? String, "boost-123")
        XCTAssertNil(corpus?["correct_table_id"])
    }

    func testClientRequestJSON_userCorrectionOverridesAutomaticVariant() throws {
        let payload = VolcProtocol.buildClientRequest(
            uid: "test-user-123",
            options: ASRRequestOptions(
                hotwords: ["OpenClaw"],
                userHotwordCount: 1,
                correctionWords: ["Open Claw": "自定义结果"]
            )
        )
        let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let request = json?["request"] as? [String: Any]
        let contextString = try XCTUnwrap(request?["context"] as? String)
        let contextData = try XCTUnwrap(contextString.data(using: .utf8))
        let context = try JSONSerialization.jsonObject(with: contextData) as? [String: Any]
        let corrections = context?["correct_words"] as? [String: String]

        XCTAssertEqual(corrections?["Open Claw"], "自定义结果")
    }

    func testClientRequestJSON_cleansHotwordsAndKeepsUserFirst() throws {
        let payload = VolcProtocol.buildClientRequest(
            uid: "test-user-123",
            options: ASRRequestOptions(
                hotwords: [" OpenClaw ", "", "openclaw", "Dal"],
                userHotwordCount: 3
            )
        )
        let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let request = json?["request"] as? [String: Any]
        let contextString = try XCTUnwrap(request?["context"] as? String)
        let contextData = try XCTUnwrap(contextString.data(using: .utf8))
        let context = try JSONSerialization.jsonObject(with: contextData) as? [String: Any]
        let hotwords = context?["hotwords"] as? [[String: Any]]
        let corrections = context?["correct_words"] as? [String: String]

        XCTAssertEqual(hotwords?.compactMap { $0["word"] as? String }, ["OpenClaw", "Dal"])
        XCTAssertTrue(hotwords?.allSatisfy { Set($0.keys) == ["word"] } == true)
        XCTAssertEqual(corrections?["Open Claw"], "OpenClaw")
        XCTAssertNil(corrections?["dal"], "内置词不应被空值或重复用户词误算为用户词")
    }

    // MARK: - Full Message Encoding

    func testEncodeMessage_withSequenceNumber() {
        let header = VolcHeader(
            messageType: .audioOnlyRequest,
            flags: .positiveSequence,
            serialization: .none,
            compression: .none
        )
        let audio = Data([0xAA, 0xBB, 0xCC])
        let message = VolcProtocol.encodeMessage(
            header: header,
            payload: audio,
            sequenceNumber: 1
        )
        // 4 (header) + 4 (seq) + 4 (size) + 3 (payload) = 15
        XCTAssertEqual(message.count, 15)

        // Check sequence number (big-endian 1)
        XCTAssertEqual(message[4], 0x00)
        XCTAssertEqual(message[5], 0x00)
        XCTAssertEqual(message[6], 0x00)
        XCTAssertEqual(message[7], 0x01)

        // Check payload size (big-endian 3)
        XCTAssertEqual(message[8], 0x00)
        XCTAssertEqual(message[9], 0x00)
        XCTAssertEqual(message[10], 0x00)
        XCTAssertEqual(message[11], 0x03)

        // Check payload
        XCTAssertEqual(message[12], 0xAA)
        XCTAssertEqual(message[13], 0xBB)
        XCTAssertEqual(message[14], 0xCC)
    }

    func testEncodeMessage_noSequenceNumber() {
        let header = VolcHeader(
            messageType: .fullClientRequest,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )
        let payload = Data([0x01, 0x02])
        let message = VolcProtocol.encodeMessage(header: header, payload: payload)
        // 4 (header) + 4 (size) + 2 (payload) = 10
        XCTAssertEqual(message.count, 10)

        // Payload size at offset 4
        XCTAssertEqual(message[4], 0x00)
        XCTAssertEqual(message[5], 0x00)
        XCTAssertEqual(message[6], 0x00)
        XCTAssertEqual(message[7], 0x02)
    }

    // MARK: - Audio Packet Encoding

    func testEncodeAudioPacket_normal() {
        let audio = Data(repeating: 0x55, count: 10)
        let packet = VolcProtocol.encodeAudioPacket(
            audioData: audio,
            isLast: false
        )
        // Header byte 1: audioOnly=0010 | noSequence=0000 => 0x20
        XCTAssertEqual(packet[1], 0x20)
        // No sequence number, payload size at offset 4
        // 4 (header) + 4 (size) + 10 (payload) = 18
        XCTAssertEqual(packet.count, 18)
    }

    func testEncodeAudioPacket_last() {
        let audio = Data(repeating: 0x55, count: 10)
        let packet = VolcProtocol.encodeAudioPacket(
            audioData: audio,
            isLast: true
        )
        // Header byte 1: audioOnly=0010 | lastPacketNoSequence=0010 => 0x22
        XCTAssertEqual(packet[1], 0x22)
        // 4 (header) + 4 (size) + 10 (payload) = 18
        XCTAssertEqual(packet.count, 18)
    }

    // MARK: - Server Response Decoding

    func testDecodeServerResponseSupportsUnalignedDataSlice() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["text": "unaligned"])
        let header = VolcHeader(
            messageType: .serverResponse,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: payload)
        let storage = Data([0xFF]) + message
        let unaligned = storage.dropFirst()

        XCTAssertEqual(unaligned.startIndex, 1)
        let pointerAlignment = unaligned.withUnsafeBytes { bytes in
            Int(bitPattern: bytes.baseAddress!) % MemoryLayout<UInt32>.alignment
        }
        XCTAssertNotEqual(pointerAlignment, 0, "fixture 必须真实覆盖未对齐读取")

        let response = try VolcProtocol.decodeServerResponse(unaligned)
        XCTAssertEqual(response.result.text, "unaligned")
    }

    func testCompressedPayloadBeyondWireLimitIsRejected() {
        let validCompressedJSON = Data([
            0xAB, 0x56, 0x2A, 0x49, 0xAD, 0x28, 0x51, 0xB2, 0x52, 0xCA, 0x48, 0xCD, 0xC9, 0xC9, 0x57, 0x28,
            0xCF, 0x2F, 0xCA, 0x49, 0x51, 0xD2, 0x51, 0x2A, 0x2D, 0x29, 0x49, 0x2D, 0x4A, 0xCC, 0x4B, 0x4E,
            0x2D, 0x56, 0xB2, 0x8A, 0xAE, 0x46, 0x51, 0x03, 0x94, 0x4D, 0x49, 0x4D, 0xCB, 0xCC, 0xCB, 0x2C,
            0x49, 0x55, 0xB2, 0x2A, 0x29, 0x2A, 0x4D, 0xAD, 0xD5, 0x81, 0x2B, 0x80, 0x69, 0x47, 0x28, 0x48,
            0x4B, 0xCC, 0x29, 0x4E, 0xAD, 0x8D, 0xAD, 0x05, 0x00
        ])
        var oversizedPayload = validCompressedJSON
        oversizedPayload.append(
            Data(
                repeating: 0,
                count: VolcProtocol.maximumCompressedPayloadBytes + 1 - validCompressedJSON.count
            )
        )
        let header = VolcHeader(
            messageType: .serverResponse,
            flags: .noSequence,
            serialization: .json,
            compression: .gzip
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: oversizedPayload)

        assertPayloadTooLarge(
            try VolcProtocol.decodeServerResponse(message),
            expectedLimit: VolcProtocol.maximumCompressedPayloadBytes
        )
    }

    func testDeclaredPayloadSizeOverflowIsRejectedBeforeSlicing() {
        let header = VolcHeader(
            messageType: .serverResponse,
            flags: .noSequence,
            serialization: .json,
            compression: .gzip
        )
        var message = header.encode()
        var declaredSize = UInt32.max.bigEndian
        message.append(Data(bytes: &declaredSize, count: MemoryLayout<UInt32>.size))

        assertPayloadTooLarge(
            try VolcProtocol.decodeServerResponse(message),
            expectedLimit: VolcProtocol.maximumCompressedPayloadBytes
        )
    }

    func testGzipOutputBeyondProtocolLimitIsRejected() throws {
        var oversizedJSON = Data("{\"result\":{\"text\":\"ok\",\"utterances\":[]},\"padding\":\"".utf8)
        oversizedJSON.append(
            Data(repeating: 0x61, count: VolcProtocol.maximumDecompressedPayloadBytes)
        )
        oversizedJSON.append(Data("\"}".utf8))
        let compressed = try zlibCompress(oversizedJSON)
        XCTAssertLessThan(compressed.count, VolcProtocol.maximumCompressedPayloadBytes)

        let header = VolcHeader(
            messageType: .serverResponse,
            flags: .noSequence,
            serialization: .json,
            compression: .gzip
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: compressed)

        assertPayloadTooLarge(
            try VolcProtocol.decodeServerResponse(message),
            expectedLimit: VolcProtocol.maximumDecompressedPayloadBytes
        )
    }

    func testGzipDecompressHonorsInjectedOutputLimit() throws {
        let compressed = try zlibCompress(Data(repeating: 0x41, count: 1_025))

        assertPayloadTooLarge(
            try VolcProtocol.gzipDecompress(compressed, maximumOutputBytes: 1_024),
            expectedLimit: 1_024
        )
    }

    func testTruncatedSequenceNumberIsRejected() {
        let header = VolcHeader(
            messageType: .serverResponse,
            flags: .positiveSequence,
            serialization: .json,
            compression: .none
        )
        var message = header.encode()
        message.append(contentsOf: [0x00, 0x00, 0x00])

        XCTAssertThrowsError(try VolcProtocol.decodeServerResponse(message)) { error in
            guard case VolcProtocolError.truncatedSequence = error else {
                XCTFail("Expected truncatedSequence, got \(error)")
                return
            }
        }
    }

    func testUtteranceCountBeyondLimitIsRejected() throws {
        let utterances = (0...VolcProtocol.maximumUtteranceCount).map { index in
            ["text": "u\(index)", "definite": true] as [String: Any]
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "result": ["text": "ok", "utterances": utterances]
        ])
        let header = VolcHeader(
            messageType: .serverResponse,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )

        XCTAssertThrowsError(
            try VolcProtocol.decodeServerResponse(
                VolcProtocol.encodeMessage(header: header, payload: payload)
            )
        ) { error in
            guard case VolcProtocolError.tooManyUtterances(let limit, let actual) = error else {
                XCTFail("Expected tooManyUtterances, got \(error)")
                return
            }
            XCTAssertEqual(limit, VolcProtocol.maximumUtteranceCount)
            XCTAssertEqual(actual, VolcProtocol.maximumUtteranceCount + 1)
        }
    }

    func testSingleTextBeyondLimitIsRejected() throws {
        let oversizedText = String(
            repeating: "a",
            count: VolcProtocol.maximumTextBytes + 1
        )
        let payload = try JSONSerialization.data(withJSONObject: ["text": oversizedText])
        let header = VolcHeader(
            messageType: .serverResponse,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )

        XCTAssertThrowsError(
            try VolcProtocol.decodeServerResponse(
                VolcProtocol.encodeMessage(header: header, payload: payload)
            )
        ) { error in
            guard case VolcProtocolError.textTooLarge(let limit) = error else {
                XCTFail("Expected textTooLarge, got \(error)")
                return
            }
            XCTAssertEqual(limit, VolcProtocol.maximumTextBytes)
        }
    }

    func testDecodeServerMessage_withGzip() throws {
        // 预压缩好的 zlib(COMPRESSION_ZLIB) 字节,解压后为:
        // {"text":"hello world","utterances":[{"text":"hello","definite":true},{"text":"world","definite":false}]}
        // 用固定 fixture 替代已删除的 gzipCompress,仍覆盖生产 gzipDecompress 解压路径。
        let compressed = Data([
            0xAB, 0x56, 0x2A, 0x49, 0xAD, 0x28, 0x51, 0xB2, 0x52, 0xCA, 0x48, 0xCD, 0xC9, 0xC9, 0x57, 0x28,
            0xCF, 0x2F, 0xCA, 0x49, 0x51, 0xD2, 0x51, 0x2A, 0x2D, 0x29, 0x49, 0x2D, 0x4A, 0xCC, 0x4B, 0x4E,
            0x2D, 0x56, 0xB2, 0x8A, 0xAE, 0x46, 0x51, 0x03, 0x94, 0x4D, 0x49, 0x4D, 0xCB, 0xCC, 0xCB, 0x2C,
            0x49, 0x55, 0xB2, 0x2A, 0x29, 0x2A, 0x4D, 0xAD, 0xD5, 0x81, 0x2B, 0x80, 0x69, 0x47, 0x28, 0x48,
            0x4B, 0xCC, 0x29, 0x4E, 0xAD, 0x8D, 0xAD, 0x05, 0x00
        ])

        // Build a server response message
        let header = VolcHeader(
            messageType: .serverResponse,
            flags: .noSequence,
            serialization: .json,
            compression: .gzip
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: compressed)

        let result = try VolcProtocol.decodeServerResponse(message).result
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.utterances.count, 2)
        XCTAssertEqual(result.utterances[0].text, "hello")
        XCTAssertEqual(result.utterances[0].definite, true)
        XCTAssertEqual(result.utterances[1].text, "world")
        XCTAssertEqual(result.utterances[1].definite, false)
    }

    func testDecodeServerResponse_preservesAsyncFinalFlag() throws {
        let jsonPayload: [String: Any] = [
            "result": [
                "text": "修正后的整句",
                "utterances": [
                    ["text": "修正后的整句", "definite": true]
                ]
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: jsonPayload)
        let header = VolcHeader(
            messageType: .serverResponse,
            flags: .asyncFinal,
            serialization: .json,
            compression: .none
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: jsonData)
        let response = try VolcProtocol.decodeServerResponse(message)
        XCTAssertEqual(response.header.flags, .asyncFinal)
        XCTAssertEqual(response.result.text, "修正后的整句")
        XCTAssertEqual(response.result.utterances.first?.text, "修正后的整句")
    }

    func testDecodeServerMessage_uncompressed() throws {
        let jsonPayload: [String: Any] = [
            "text": "test",
            "utterances": [] as [[String: Any]]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: jsonPayload)

        let header = VolcHeader(
            messageType: .serverResponse,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: jsonData)

        let result = try VolcProtocol.decodeServerResponse(message).result
        XCTAssertEqual(result.text, "test")
        XCTAssertEqual(result.utterances.count, 0)
    }

    func testDecodeServerMessage_serverError() throws {
        let errorJson: [String: Any] = ["code": 1001, "message": "auth failed"]
        let jsonData = try JSONSerialization.data(withJSONObject: errorJson)

        let header = VolcHeader(
            messageType: .serverError,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )
        let message = VolcProtocol.encodeMessage(header: header, payload: jsonData)

        XCTAssertThrowsError(try VolcProtocol.decodeServerResponse(message)) { error in
            guard case VolcProtocolError.serverError(let code, let msg) = error else {
                XCTFail("Expected serverError, got \(error)")
                return
            }
            XCTAssertEqual(code, 1001)
            XCTAssertEqual(msg, "auth failed")
        }
    }

    func testDecodeOfficialServerErrorWireFormat() throws {
        let messageText = "server busy"
        let messageData = Data(messageText.utf8)
        let header = VolcHeader(
            messageType: .serverError,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )
        var code = UInt32(55_000_031).bigEndian
        var size = UInt32(messageData.count).bigEndian
        var message = header.encode()
        message.append(Data(bytes: &code, count: MemoryLayout<UInt32>.size))
        message.append(Data(bytes: &size, count: MemoryLayout<UInt32>.size))
        message.append(messageData)

        XCTAssertThrowsError(try VolcProtocol.decodeServerResponse(message)) { error in
            guard case VolcProtocolError.serverError(let code, let detail) = error else {
                XCTFail("Expected serverError, got \(error)")
                return
            }
            XCTAssertEqual(code, 55_000_031)
            XCTAssertEqual(detail, messageText)
        }
    }

    func testDecodeServerMessage_gzipJSONServerError() throws {
        let compressed = Data([
            0xAB, 0x56, 0x4A, 0xCE, 0x4F, 0x49, 0x55, 0xB2, 0x32, 0x34, 0x30, 0x30, 0xD4,
            0x51, 0xCA, 0x4D, 0x2D, 0x2E, 0x4E, 0x4C, 0x07, 0x72, 0x95, 0x12, 0x4B, 0x4B,
            0x32, 0x14, 0xD2, 0x12, 0x33, 0x73, 0x52, 0x53, 0x94, 0x6A, 0x01
        ])
        let header = VolcHeader(
            messageType: .serverError,
            flags: .noSequence,
            serialization: .json,
            compression: .gzip
        )

        XCTAssertThrowsError(
            try VolcProtocol.decodeServerResponse(
                VolcProtocol.encodeMessage(header: header, payload: compressed)
            )
        ) { error in
            guard case VolcProtocolError.serverError(let code, let message) = error else {
                XCTFail("Expected serverError, got \(error)")
                return
            }
            XCTAssertEqual(code, 1001)
            XCTAssertEqual(message, "auth failed")
        }
    }

    func testServerErrorMessageIsBoundedBeforePropagation() throws {
        let oversizedMessage = String(
            repeating: "a",
            count: VolcProtocol.maximumServerErrorMessageBytes * 2
        )
        let payload = try JSONSerialization.data(withJSONObject: [
            "code": 500,
            "message": oversizedMessage,
        ])
        let header = VolcHeader(
            messageType: .serverError,
            flags: .noSequence,
            serialization: .json,
            compression: .none
        )

        XCTAssertThrowsError(
            try VolcProtocol.decodeServerResponse(
                VolcProtocol.encodeMessage(header: header, payload: payload)
            )
        ) { error in
            guard case VolcProtocolError.serverError(let code, let message) = error else {
                XCTFail("Expected serverError, got \(error)")
                return
            }
            XCTAssertEqual(code, 500)
            XCTAssertEqual(message?.utf8.count, VolcProtocol.maximumServerErrorMessageBytes)
            XCTAssertEqual(message, String(repeating: "a", count: VolcProtocol.maximumServerErrorMessageBytes))
        }
    }

    private func assertPayloadTooLarge<T>(
        _ expression: @autoclosure () throws -> T,
        expectedLimit: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case VolcProtocolError.payloadTooLarge(let limit, let actual) = error else {
                XCTFail("Expected payloadTooLarge, got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(limit, expectedLimit, file: file, line: line)
            XCTAssertGreaterThan(actual, limit, file: file, line: line)
        }
    }

    private func zlibCompress(_ source: Data) throws -> Data {
        var output = Data(count: max(source.count, 256))
        let encodedSize = output.withUnsafeMutableBytes { destinationBytes in
            source.withUnsafeBytes { sourceBytes in
                guard let destination = destinationBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let source = sourceBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
                    return 0
                }
                return compression_encode_buffer(
                    destination,
                    destinationBytes.count,
                    source,
                    sourceBytes.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard encodedSize > 0 else {
            throw TestFixtureError.compressionFailed
        }
        output.count = encodedSize
        return output
    }

    private enum TestFixtureError: Error {
        case compressionFailed
    }
}
