import Foundation

/// 流式 WebSocket ASR 客户端的共享协议。
///
/// 流式客户端共享同一套事件流懒加载（`events`）与发射（`emitEvent`）样板。这里用协议默认
/// 实现统一收口，客户端只需声明两个存储属性并标注遵循。
///
/// 说明：receive loop / 消息解包 / close 判定等仍因各 provider 协议差异保留在各客户端，
/// 未强行抽取，以免在无实时服务可验证的前提下引入回归。
protocol WebSocketASRClient: Actor, SpeechRecognizer {
    var eventContinuation: AsyncStream<RecognitionEvent>.Continuation? { get set }
    var _events: AsyncStream<RecognitionEvent>? { get set }
}

extension WebSocketASRClient {

    var events: AsyncStream<RecognitionEvent> {
        if let existing = _events {
            return existing
        }
        let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
        eventContinuation = continuation
        _events = stream
        return stream
    }

    func emitEvent(_ event: RecognitionEvent) {
        eventContinuation?.yield(event)
    }
}
