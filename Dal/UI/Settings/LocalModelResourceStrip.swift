import SwiftUI

struct LocalModelResourceStrip: View, SettingsCardHelpers {
    @State private var downloadProgress: [String: Double] = [:]
    @State private var downloadErrors: [String: String] = [:]
    @State private var pendingDelete: InventoryItem?
    @State private var refreshTick = 0
    @State private var memoryUsage: ServerMemoryUsage?

    private struct InventoryItem: Identifiable {
        let id: String
        let name: String
        let role: String
        let size: String?
        let installed: Bool
        var downloadable: Bool = false
    }

    private var items: [InventoryItem] {
        [
            InventoryItem(
                id: "sensevoice",
                name: "SenseVoice",
                role: L("语音识别 · 流式", "ASR · streaming"),
                size: "228MB",
                installed: ModelManager.isSenseVoiceModelDownloaded || ModelManager.isSenseVoiceBundled,
                downloadable: true
            ),
            InventoryItem(
                id: "qwen3-asr",
                name: "Qwen3-ASR",
                role: L("语音识别 · 终校", "ASR · final pass"),
                size: nil,
                installed: SenseVoiceServerManager.resolveQwen3ModelPath() != nil,
                downloadable: true
            ),
            InventoryItem(
                id: "qwen3.5-9b",
                name: "Qwen3.5-9B",
                role: L("文本处理", "Text processing"),
                size: "5.3GB",
                installed: LocalQwenLLMConfig.isModelAvailable,
                downloadable: true
            ),
            InventoryItem(
                id: "punctuation",
                name: L("智能标点", "Smart Punctuation"),
                role: L("自动补逗号、句号、问号", "Auto-adds punctuation"),
                size: "72MB",
                installed: ModelManager.shared.isModelAvailable(ModelManager.AuxModelType.punctuation),
                downloadable: true
            ),
        ]
    }

    private var installedCount: Int { items.filter(\.installed).count }

    var body: some View {
        settingsGroupCard(
            "",
            expandVertically: false,
            showsHeader: false,
            cornerRadius: ModelSettingsStyle.outerCardCornerRadius,
            fillColor: ModelSettingsStyle.cardFillColor,
            showsBorder: false
        ) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(L("本地模型", "Local Models"))
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsText)
                    Text(L("用于离线、本地识别", "For offline, on-device use"))
                        .font(TF.settingsFontCaption)
                        .foregroundStyle(TF.settingsTextTertiary)
                    Spacer()
                    settingsHeaderStatus(
                        title: L("已下载 \(installedCount)/\(items.count)", "\(installedCount)/\(items.count) downloaded"),
                        color: installedCount > 0 ? TF.settingsAccentGreen : TF.settingsAccentAmber
                    )
                }
                .padding(.bottom, 12)

                ForEach(items) { item in
                    inventoryRow(item)
                    if item.id != items.last?.id {
                        settingsInspectorDivider()
                    }
                }
            }
        }
        .frame(minHeight: ModelSettingsStyle.resourceStripMinHeight, alignment: .topLeading)
        .id(refreshTick)
        .confirmationDialog(
            L("删除该模型？", "Delete this model?"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { item in
            Button(L("删除", "Delete"), role: .destructive) { performDelete(item) }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: { item in
            Text(L("将删除「\(item.name)」的本地文件，需重新下载才能再次使用。",
                   "Removes \(item.name)'s local files; you'll need to download it again."))
        }
        .task {
            while !Task.isCancelled {
                let anyInUse = items.contains { $0.installed && isInUse($0.id) }
                if anyInUse {
                    let usage = await SenseVoiceServerManager.shared.currentMemoryUsage()
                    await MainActor.run { memoryUsage = usage }
                } else if memoryUsage != nil {
                    await MainActor.run { memoryUsage = nil }
                }
                try? await Task.sleep(nanoseconds: anyInUse ? 3_000_000_000 : 8_000_000_000)
            }
        }
    }

    private func inventoryRow(_ item: InventoryItem) -> some View {
        let progress = downloadProgress[item.id]
        let error = downloadErrors[item.id]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(TF.settingsFontBody)
                            .foregroundStyle(TF.settingsText)
                        if item.installed {
                            modelStatusBadge(item)
                        }
                    }
                    Text(item.size.map { "\(item.role) · \($0)" } ?? item.role)
                        .font(TF.settingsFontMetadata)
                        .foregroundStyle(TF.settingsTextTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if item.installed {
                    SettingsButton(variant: .success, controlSize: .compact, width: 36, action: {}) {
                        Image(systemName: "checkmark")
                    }
                    .allowsHitTesting(false)
                    if progress == nil {
                        SettingsButton(variant: .danger, controlSize: .compact, width: 36, action: { pendingDelete = item }) {
                            Image(systemName: "xmark")
                        }
                    }
                } else if item.downloadable && progress == nil {
                    SettingsButton(variant: .secondary, controlSize: .compact, width: 36, action: { startDownload(item) }) {
                        Image(systemName: "arrow.down.to.line")
                    }
                }
            }
            .frame(height: ModelSettingsStyle.localInventoryRowHeight)

            if let progress {
                downloadProgressLine(progress)
                    .padding(.bottom, 9)
            }
            if let error {
                Text(error)
                    .font(TF.settingsFontCaption)
                    .foregroundStyle(TF.settingsAccentRed)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.bottom, 9)
            }
        }
    }

    private func isInUse(_ id: String) -> Bool {
        let asr = KeychainService.selectedASRProvider
        switch id {
        case "sensevoice":
            return asr == .sherpa && ModelManager.selectedStreamingModel == .senseVoiceSmall
        case "qwen3-asr":
            return asr == .sherpa
                && (UserDefaults.standard.object(forKey: DefaultsKeys.qwen3FinalEnabled) as? Bool ?? true)
        case "qwen3.5-9b":
            return KeychainService.anyPolishUsesLocalModel
        case "punctuation":
            return asr == .sherpa
        default:
            return false
        }
    }

    private func memoryMB(_ id: String) -> Int? {
        switch id {
        case "sensevoice": return memoryUsage?.senseVoiceMB
        case "qwen3-asr", "qwen3.5-9b": return memoryUsage?.qwen3MB
        default: return nil
        }
    }

    private func isSharedEngine(_ id: String) -> Bool {
        id == "qwen3-asr" || id == "qwen3.5-9b"
    }

    @ViewBuilder
    private func modelStatusBadge(_ item: InventoryItem) -> some View {
        let inUse = isInUse(item.id)
        let mb = inUse ? memoryMB(item.id) : nil
        HStack(spacing: 5) {
            Circle()
                .fill(inUse ? TF.settingsAccentGreen : TF.settingsTextTertiary)
                .frame(width: 6, height: 6)
            Text(statusText(id: item.id, inUse: inUse, mb: mb))
                .font(TF.settingsFontMetadata)
                .foregroundStyle(inUse ? TF.settingsTextSecondary : TF.settingsTextTertiary)
                .lineLimit(1)
        }
        .fixedSize()
        .help(statusTooltip(id: item.id, inUse: inUse))
    }

    private func statusText(id: String, inUse: Bool, mb: Int?) -> String {
        guard inUse else { return L("闲置", "Idle") }
        if id == "punctuation" { return L("使用中", "In use") }
        guard let mb else { return L("使用中 · 待命", "In use · idle") }
        let mem = mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024.0) : "\(mb) MB"
        return isSharedEngine(id)
            ? L("使用中 · \(mem) 共享", "In use · \(mem) shared")
            : L("使用中 · \(mem)", "In use · \(mem)")
    }

    private func statusTooltip(id: String, inUse: Bool) -> String {
        if !inUse { return L("已下载但未启用，不占内存", "Downloaded but not in use — no memory") }
        if id == "punctuation" { return L("识别后自动补标点（内置轻量库，占用极小）", "Auto punctuation (built-in, tiny footprint)") }
        if isSharedEngine(id) { return L("与另一个本地模型共用同一引擎，内存为合计", "Shares one engine with another local model; memory is combined") }
        return L("使用中", "In use")
    }

    private func downloadProgressLine(_ progress: Double) -> some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(TF.settingsTextTertiary.opacity(0.3))
                        .frame(height: 3)
                    Capsule()
                        .fill(TF.settingsAccentAmber)
                        .frame(width: max(geo.size.width * progress, 3), height: 3)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 6)

            Text("\(Int(progress * 100))%")
                .font(TF.settingsFontMono)
                .foregroundStyle(TF.settingsTextSecondary)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.trailing, 9)
        .animation(.linear(duration: 0.2), value: progress)
    }

    private func performDelete(_ item: InventoryItem) {
        let id = item.id
        pendingDelete = nil
        downloadErrors[id] = nil
        Task {
            do {
                try await ModelManager.shared.deleteLocalModel(id: id)
                await MainActor.run { refreshTick += 1 }
            } catch {
                await MainActor.run {
                    downloadErrors[id] = L("删除失败：", "Delete failed: ") + error.localizedDescription
                }
            }
        }
    }

    private func startDownload(_ item: InventoryItem) {
        let id = item.id
        downloadErrors[id] = nil
        downloadProgress[id] = 0
        Task {
            do {
                switch id {
                case "punctuation":
                    try await ModelManager.shared.downloadModel(ModelManager.AuxModelType.punctuation) { progress in
                        Task { @MainActor in downloadProgress[id] = progress }
                    }
                case "qwen3.5-9b":
                    try await ModelManager.shared.downloadQwen3LLM { progress in
                        Task { @MainActor in downloadProgress[id] = progress }
                    }
                case "sensevoice":
                    try await ModelManager.shared.downloadMultiFileModel(ModelManager.senseVoiceMultiFile) { progress in
                        Task { @MainActor in downloadProgress[id] = progress }
                    }
                case "qwen3-asr":
                    try await ModelManager.shared.downloadMultiFileModel(ModelManager.qwen3ASRMultiFile) { progress in
                        Task { @MainActor in downloadProgress[id] = progress }
                    }
                default:
                    break
                }
                await MainActor.run { downloadProgress[id] = nil }
            } catch {
                await MainActor.run {
                    downloadProgress[id] = nil
                    downloadErrors[id] = L("下载失败：", "Download failed: ") + error.localizedDescription
                }
            }
        }
    }
}
