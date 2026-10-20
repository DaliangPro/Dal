import Foundation
import Observation

/// 模型列表请求的 UI 状态。代际先失效再取消任务，忽略取消的旧网络响应也不能回填。
@MainActor
@Observable
final class LLMModelListState {
    private(set) var models: [String] = []
    private(set) var status: SettingsTestStatus = .idle
    private var generation = UUID()
    private var task: Task<Void, Never>?

    func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        models = []
        status = .idle
    }

    @discardableResult
    func fetch(
        provider: LLMProvider,
        values: [String: String],
        loader: @escaping @Sendable (LLMProvider, String, String) async throws -> [String] = {
            try await LLMModelListFetcher.fetchModels(provider: $0, apiKey: $1, baseURL: $2)
        }
    ) -> Task<Void, Never> {
        invalidate()
        let requestGeneration = generation
        status = .testing
        let requestTask = Task {
            do {
                let result = try await loader(provider, values["apiKey"] ?? "", values["baseURL"] ?? "")
                guard generation == requestGeneration, !Task.isCancelled else { return }
                models = result
                status = .idle
            } catch {
                guard generation == requestGeneration, !Task.isCancelled else { return }
                models = []
                status = .failed(error.localizedDescription)
            }
        }
        task = requestTask
        return requestTask
    }
}
