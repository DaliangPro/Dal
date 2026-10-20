import Foundation

/// Foundation 完成语法解析后，再拒绝任何层级的重复 key，避免原字节与解码对象含义不唯一。
struct VoicePolishJSONUniqueKeys {
    enum ValidationError: Error { case invalidJSON }
    let bytes: [UInt8]
    var index = 0
    init(data: Data) { bytes = Array(data) }
    mutating func check() throws { try value(depth: 0); whitespace(); guard index == bytes.count else { throw ValidationError.invalidJSON } }
    mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func string() throws -> String {
        let start = index; index += 1
        while index < bytes.count {
            if bytes[index] == 92 { index += 2; continue }
            if bytes[index] == 34 {
                index += 1
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
            index += 1
        }
        throw ValidationError.invalidJSON
    }
    mutating func value(depth: Int) throws {
        guard depth <= 64 else { throw ValidationError.invalidJSON }
        whitespace(); guard index < bytes.count else { throw ValidationError.invalidJSON }
        if bytes[index] == 34 { _ = try string(); return }
        if bytes[index] == 123 {
            index += 1; whitespace(); var keys = Set<String>()
            if index < bytes.count && bytes[index] == 125 { index += 1; return }
            while index < bytes.count {
                whitespace(); guard bytes[index] == 34 else { throw ValidationError.invalidJSON }
                let key = try string(); guard keys.insert(key).inserted else { throw ValidationError.invalidJSON }
                whitespace(); guard index < bytes.count && bytes[index] == 58 else { throw ValidationError.invalidJSON }
                index += 1; try value(depth: depth + 1); whitespace()
                guard index < bytes.count else { throw ValidationError.invalidJSON }
                if bytes[index] == 125 { index += 1; return }
                guard bytes[index] == 44 else { throw ValidationError.invalidJSON }; index += 1
            }
        } else if bytes[index] == 91 {
            index += 1; whitespace()
            if index < bytes.count && bytes[index] == 93 { index += 1; return }
            while index < bytes.count {
                try value(depth: depth + 1); whitespace(); guard index < bytes.count else { throw ValidationError.invalidJSON }
                if bytes[index] == 93 { index += 1; return }
                guard bytes[index] == 44 else { throw ValidationError.invalidJSON }; index += 1
            }
        } else {
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            return
        }
        throw ValidationError.invalidJSON
    }
}
