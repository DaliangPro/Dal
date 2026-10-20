import Foundation

enum EstimatedTokenCounter {
    static func count(in text: String) -> Int {
        var total = 0
        var latinRunBytes = 0
        var pendingWhitespaceBytes = 0

        func flushLatinRun() {
            guard latinRunBytes > 0 else {
                pendingWhitespaceBytes = 0
                return
            }
            total += max(1, Int(ceil(Double(latinRunBytes) / 4.0)))
            latinRunBytes = 0
            pendingWhitespaceBytes = 0
        }

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if latinRunBytes > 0 {
                    pendingWhitespaceBytes += scalar.utf8.count
                }
                continue
            }

            if isCJK(scalar) {
                flushLatinRun()
                total += 1
                continue
            }

            if CharacterSet.alphanumerics.contains(scalar) {
                latinRunBytes += pendingWhitespaceBytes + scalar.utf8.count
                pendingWhitespaceBytes = 0
                continue
            }

            flushLatinRun()
            total += 1
        }

        flushLatinRun()
        return total
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0x2CEB0...0x2EBEF,
             0x30000...0x3134F,
             0x31350...0x323AF,
             0x3040...0x30FF,
             0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }
}
