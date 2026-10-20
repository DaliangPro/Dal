import SwiftUI

enum SettingsTestStatus: Equatable {
    case idle, testing, saved, success, failed(String)

    var badgeTitle: String? {
        switch self {
        case .idle, .testing:
            return nil
        case .saved:
            return L("已保存", "Saved")
        case .success:
            return L("连接成功", "Connected")
        case .failed(let msg):
            return msg
        }
    }

    var badgeSystemImage: String? {
        switch self {
        case .idle, .testing:
            return nil
        case .saved, .success:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    var badgeTone: SettingsStatusTone {
        switch self {
        case .idle, .testing:
            return .neutral
        case .saved, .success:
            return .success
        case .failed:
            return .danger
        }
    }
}
