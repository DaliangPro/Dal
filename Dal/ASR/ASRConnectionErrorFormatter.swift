import Foundation

enum ASRConnectionErrorFormatter {
    static func describe(_ error: Error) -> String {
        if let aliyun = error as? AliyunASRError,
           case .taskFailed(_, let message) = aliyun,
           let message,
           !looksLikeRawProtocolText(message) {
            return message
        }
        if let volc = error as? VolcASRError, case .serverRejected(_, let message) = volc {
            // 技术裸文不糊用户脸（2026-07）：websocket/upgrade/裸 JSON 一律转人话，原文已在日志
            if let message, !looksLikeRawProtocolText(message) {
                return message
            }
            return L("连接中断，请再试一次", "Connection interrupted — try again")
        }
        if let volc = error as? VolcProtocolError, case .serverError(let code, let message) = volc {
            let desc = message ?? L("服务器错误", "Server error")
            return code.map { "\(desc) (\($0))" } ?? desc
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return L("网络未连接", "No internet")
            case .timedOut:
                return L("连接超时", "Timed out")
            case .cannotFindHost, .cannotConnectToHost:
                return L("无法连接服务器", "Cannot reach server")
            default:
                return urlError.localizedDescription
            }
        }
        return L("连接失败", "Connection failed") + ": " + error.localizedDescription
    }

    /// 协议层裸文特征：这类内容对用户无意义，只该进日志
    private static func looksLikeRawProtocolText(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("websocket")
            || lowered.contains("upgrade")
            || lowered.contains("bad request")
            || lowered.contains("{\"")
    }
}
