import XCTest
@testable import Dal

@MainActor
final class LLMModelListStateTests: XCTestCase {
    func testOldProviderIgnoringCancellationCannotReplaceNewModels() async {
        let state = LLMModelListState()
        let gate = ModelListGate()
        let oldTask = state.fetch(provider: .openai, values: [:]) { _, _, _ in
            await gate.load()
        }
        await gate.waitUntilStarted()
        let newTask = state.fetch(provider: .claude, values: [:]) { _, _, _ in ["当前模型"] }
        await newTask.value
        await gate.resolve(["旧模型"])
        await oldTask.value
        XCTAssertEqual(state.models, ["当前模型"])
        XCTAssertEqual(state.status, .idle)
    }

    func testCredentialChangeInvalidatesLateFailure() async {
        let state = LLMModelListState()
        let gate = ModelListGate()
        let oldTask = state.fetch(provider: .openai, values: ["apiKey": "fixture"]) { _, _, _ in
            _ = await gate.load()
            throw URLError(.badServerResponse)
        }
        await gate.waitUntilStarted()
        state.invalidate()
        await gate.resolve([])
        await oldTask.value
        XCTAssertTrue(state.models.isEmpty)
        XCTAssertEqual(state.status, .idle)
    }
}

private actor ModelListGate {
    private var continuation: CheckedContinuation<[String], Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?

    func load() async -> [String] {
        await withCheckedContinuation {
            continuation = $0
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func resolve(_ value: [String]) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
