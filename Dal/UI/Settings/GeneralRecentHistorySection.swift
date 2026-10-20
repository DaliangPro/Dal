import SwiftUI

struct GeneralRecentHistorySection: View, SettingsCardHelpers {
    let records: [HistoryRecord]
    let copiedRecordId: String?
    let correctedRecordIds: Set<String>
    @Binding var selectedDayKey: String
    let onCopy: (HistoryRecord) -> Void
    let onLearn: (HistoryRecord) -> Void
    let onUndoCorrection: (HistoryRecord) -> Void
    let onDelete: (HistoryRecord) -> Void

    var body: some View {
        compactSettingsCard(expandVertically: true) {
            VStack(alignment: .leading, spacing: GeneralSettingsStyle.sectionTitleSpacing) {
                sectionHeader

                if records.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        historyList
                            .padding(.top, 10)
                            .padding(.bottom, SettingsScrollFade.contentPadding)
                    }
                    .settingsThinScrollIndicators()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .settingsVerticalScrollFade(color: GeneralSettingsStyle.sectionCardFillColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension GeneralRecentHistorySection {
    /// 日期下拉选项：最近 10 天（今天/昨天/前天 + 往前 7 天），2026-06-23 大梁老师拍板砍短
    static func dayOptions() -> [(value: String, label: String)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<10).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (dayKey(for: day), dayLabel(for: day, offset: offset))
        }
    }

    static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func day(fromKey key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key).map { Calendar.current.startOfDay(for: $0) }
    }

    private static func dayLabel(for date: Date, offset: Int) -> String {
        switch offset {
        case 0: return L("今天", "Today")
        case 1: return L("昨天", "Yesterday")
        case 2: return L("前天", "2 days ago")
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: Locale.preferredLanguages.first ?? "zh-Hans")
            formatter.dateFormat = L("M月d日", "MMM d")
            return formatter.string(from: date)
        }
    }
}

private extension GeneralRecentHistorySection {
    var sectionHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(L("识别记录", "Recent Records"))
                .font(TF.settingsFontSectionTitle)
                .foregroundStyle(TF.settingsText)

            Spacer(minLength: 10)

            // 日期选择（2026-06-12 用户拍板）：挪到右上角与标题同行
            settingsInspectorInlineDropdown(
                selection: $selectedDayKey,
                options: Self.dayOptions(),
                width: 86,
                height: 22
            )
            .accessibilityLabel(L("识别记录日期", "Recognition history date"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var historyList: some View {
        // 懒加载：当天可能上百条记录，普通 VStack 会把全部行一次性构建+布局，
        // 切到概览页打开那一下明显卡顿；LazyVStack 只渲染滚动可见的几行，滚到哪画到哪（2026-06-25）
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                historyRow(record)

                if index < records.count - 1 {
                    Rectangle()
                        .fill(TF.settingsStroke.opacity(0.14))
                        .frame(height: 1)
                }
            }
        }
    }

    var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("这一天没有识别记录", "No records on this day"))
                .font(TF.settingsFontSectionTitle)
                .foregroundStyle(TF.settingsText)
            Text(L("换个日期看看，或使用快捷键开始语音输入。", "Pick another day, or start voice input with a shortcut."))
                .font(TF.settingsFontBody)
                .foregroundStyle(TF.settingsTextTertiary)
                .lineSpacing(2)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func historyRow(_ record: HistoryRecord) -> some View {
        RecentHistoryRowView(
            record: record,
            timeText: GeneralSettingsFormatters.recentTime(record.createdAt),
            isCopied: copiedRecordId == record.id,
            isCorrected: correctedRecordIds.contains(record.id),
            copyAction: { onCopy(record) },
            learnAction: record.status.hasPrefix("voice_polish_") ? { onLearn(record) } : nil,
            undoCorrectionAction: correctedRecordIds.contains(record.id)
                ? { onUndoCorrection(record) }
                : nil,
            deleteAction: { onDelete(record) }
        )
    }

    func compactSettingsCard<Content: View>(
        expandVertically: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        settingsGroupCard(
            "",
            expandVertically: expandVertically,
            showsHeader: false,
            cornerRadius: GeneralSettingsStyle.sectionCardCornerRadius,
            contentPadding: GeneralSettingsStyle.sectionCardContentPadding,
            fillColor: GeneralSettingsStyle.sectionCardFillColor,
            showsBorder: false
        ) {
            content()
        }
    }
}
