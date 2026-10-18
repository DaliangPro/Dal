import Foundation

enum PostInjectionRangeRead: Sendable {
    case text(String)
    case outOfBounds
    case unsupported
    case unavailable
}

enum PostInjectionCaptureFailure: String, Sendable, Equatable {
    case focusChanged
    case selectionUnavailable
    case selectionActive
    case insertionPending
    case rangeUnsupported
    case rangeUnreadable
    case invalidRangeResponse
    case textMismatch
    case windowTooLarge

    var feedback: AutomaticLearningFeedback? {
        switch self {
        case .focusChanged: return nil
        case .selectionUnavailable: return .selectionUnavailable
        case .selectionActive: return .selectionActive
        case .insertionPending, .textMismatch: return .insertionUnverified
        case .rangeUnsupported: return .rangeUnsupported
        case .rangeUnreadable: return .fieldUnresponsive
        case .invalidRangeResponse: return .rangeResponseInvalid
        case .windowTooLarge: return .learningWindowTooLarge
        }
    }

    var canRetry: Bool {
        switch self {
        case .focusChanged, .rangeUnsupported, .invalidRangeResponse, .windowTooLarge: return false
        default: return true
        }
    }
}

enum PostInjectionWindowRead: Sendable {
    case window(String, complete: Bool)
    case failure(PostInjectionCaptureFailure)
}

/// 总字数是优化信息，不是读取能力的证明。缺失或过期时，在已确认的短窗口内
/// 使用明确的越界响应查找终点；不把 IPC 失败、空响应或短响应当成文字末尾。
enum PostInjectionBoundedWindow {
    static func read(
        field: PostInjectionLearningField, start: Int, minimumEnd: Int,
        maximumLength: Int, reportedCount: Int?
    ) async -> PostInjectionWindowRead {
        guard start >= 0, minimumEnd >= start, maximumLength > 0,
              maximumLength <= PostInjectionEditLearningMonitor.maximumWindowLength,
              start <= Int.max - maximumLength,
              minimumEnd - start <= maximumLength else { return .failure(.windowTooLarge) }
        guard await field.isAvailable() else { return .failure(.focusChanged) }
        if let count = reportedCount, count >= minimumEnd {
            let length = min(count - start, maximumLength)
            switch await exact(field: field, start: start, length: length) {
            case .window(let text, _):
                if length < maximumLength {
                    guard await field.isAvailable() else { return .failure(.focusChanged) }
                    let next = await field.readRange(CFRange(location: count, length: 1))
                    guard await field.isAvailable() else { return .failure(.focusChanged) }
                    // 明确读到后续字符，说明字数元数据滞后；不能截断这次纠正。
                    if case .text(let nextText) = next {
                        if nextText.utf16.count == 1 { break }
                        if !nextText.isEmpty { return .failure(.invalidRangeResponse) }
                    }
                }
                return .window(text, complete: count - start <= maximumLength)
            case .failure(.insertionPending): break
            case .failure(let reason): return .failure(reason)
            }
        }

        // 先确认下界可读。之后每次仅探测一个 UTF-16 单位，最多约 12 次，
        // 请求位置始终位于同一个有界窗口中，不读取页面或输入框全文。
        switch await exact(field: field, start: start, length: minimumEnd - start) {
        case .failure(let reason): return .failure(reason)
        case .window: break
        }
        var lower = minimumEnd
        var upper = start + maximumLength - 1
        if lower > upper {
            return await exact(field: field, start: start, length: maximumLength, complete: false)
        }
        while lower < upper {
            let index = lower + (upper - lower) / 2
            guard await field.isAvailable() else { return .failure(.focusChanged) }
            let response = await field.readRange(CFRange(location: index, length: 1))
            guard await field.isAvailable() else { return .failure(.focusChanged) }
            switch response {
            case .text(let text) where text.utf16.count == 1: lower = index + 1
            case .outOfBounds: upper = index
            case .text: return .failure(.invalidRangeResponse)
            case .unsupported: return .failure(.rangeUnsupported)
            case .unavailable: return .failure(.rangeUnreadable)
            }
        }
        guard await field.isAvailable() else { return .failure(.focusChanged) }
        let boundary = await field.readRange(CFRange(location: lower, length: 1))
        guard await field.isAvailable() else { return .failure(.focusChanged) }
        switch boundary {
        case .outOfBounds:
            return await exact(field: field, start: start, length: lower - start)
        case .text(let text) where text.utf16.count == 1:
            return await exact(field: field, start: start, length: maximumLength, complete: false)
        case .text: return .failure(.invalidRangeResponse)
        case .unsupported: return .failure(.rangeUnsupported)
        case .unavailable: return .failure(.rangeUnreadable)
        }
    }

    private static func exact(
        field: PostInjectionLearningField, start: Int, length: Int, complete: Bool = true
    ) async -> PostInjectionWindowRead {
        guard await field.isAvailable() else { return .failure(.focusChanged) }
        let response = await field.readRange(CFRange(location: start, length: length))
        guard await field.isAvailable() else { return .failure(.focusChanged) }
        switch response {
        case .text(let text):
            return text.utf16.count == length ? .window(text, complete: complete) : .failure(.invalidRangeResponse)
        case .outOfBounds: return .failure(.insertionPending)
        case .unsupported: return .failure(.rangeUnsupported)
        case .unavailable: return .failure(.rangeUnreadable)
        }
    }
}
