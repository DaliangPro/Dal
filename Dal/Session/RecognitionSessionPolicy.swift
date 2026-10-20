import Foundation

/// 纯转写取值与恢复预算策略；不持有麦克风、网络客户端或会话可变状态。
extension RecognitionSession {
    // REPAIR_PLAN K2：注入取值守卫。HUD 字幕与 LLM 路径显示/消费 composedText
    // （流式累积），而 displayText 优先 authoritativeText（火山 asyncFinal 的
    // result.text）——后者偶发只承载尾段或被服务端 DDC 重排变短。权威文本明显
    // 短于流式累积时回退 composed，使注入与用户在 HUD 所见一致。
    static func effectiveTranscriptText(for transcript: RecognitionTranscript) -> String {
        let auth = transcript.authoritativeText
        let composed = transcript.composedText
        guard !auth.isEmpty else { return composed }
        guard !composed.isEmpty else { return auth }
        if Double(auth.count) < Double(composed.count) * 0.6 {
            DebugFileLogger.log(
                "stop: authoritative text suspiciously short auth=\(auth.count) "
                    + "composed=\(composed.count), using composed"
            )
            return composed
        }
        return auth
    }

    // REPAIR_PLAN K10：按真实有声时长而非墙钟录音时长判断，长停顿不再把正常
    // 文本误报为丢字；活动摘要只计通过声音阈值的 20ms 帧。
    static func isTranscriptImplausiblyShort(
        textCount: Int,
        audioSummary: PCMAudioActivitySummary
    ) -> Bool {
        isTranscriptImplausiblyShort(
            textCount: textCount,
            durationSeconds: audioSummary.voicedDurationSeconds
        )
    }

    // REPAIR_PLAN K2：有声时长较长且不足每秒 0.5 字时视为疑似流层丢失。
    // 0 字交由 K7 的 PCM 活动摘要另行判断；不足 10 秒的短句不触发。
    static func isTranscriptImplausiblyShort(
        textCount: Int,
        durationSeconds: Double
    ) -> Bool {
        guard durationSeconds >= 10 else { return false }
        guard textCount > 0 else { return false }
        return Double(textCount) < durationSeconds * 0.5
    }

    /// 阿里云与火山重放都按实时节奏发送，超时必须覆盖音频本身时长；其他厂商
    /// 保持原 30 秒上限。极长会话最多等待 5 分钟，避免停止流程无限占用。
    static func batchFallbackTimeout(
        provider: ASRProvider,
        audioByteCount: Int
    ) -> Duration {
        guard provider == .aliyun || provider == .volcano else { return .seconds(30) }
        let bytesPerSecond = Int(AudioCaptureEngine.sampleRate)
            * MemoryLayout<Int16>.size
        let audioSeconds = Double(max(0, audioByteCount)) / Double(bytesPerSecond)
        return .seconds(min(300, max(30, audioSeconds.rounded(.up) + 15)))
    }

}
