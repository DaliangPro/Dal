enum VolcanoASRAutoResourceTestResult {
    case resolved(resourceId: String)
    case failed
    case cancelled
}

enum VolcanoASRAutoResourceTester {
    static func test(baseValues: [String: String]) async -> VolcanoASRAutoResourceTestResult {
        let options = ASRRequestOptionsFactory.current(enablePunc: false)
        let seedId = VolcanoASRConfig.resourceIdSeedASR
        let bigId = VolcanoASRConfig.resourceIdBigASR

        let seedOK = await testResource(baseValues: baseValues, resourceId: seedId, options: options)
        guard !Task.isCancelled else { return .cancelled }

        if seedOK {
            return .resolved(resourceId: seedId)
        }

        let bigOK = await testResource(baseValues: baseValues, resourceId: bigId, options: options)
        guard !Task.isCancelled else { return .cancelled }

        if bigOK {
            return .resolved(resourceId: bigId)
        }

        return .failed
    }

    private static func testResource(
        baseValues: [String: String],
        resourceId: String,
        options: ASRRequestOptions
    ) async -> Bool {
        var values = baseValues
        values["resourceId"] = resourceId
        guard let config = VolcanoASRConfig(credentials: values) else { return false }

        let client = VolcASRClient()
        do {
            try await client.connect(config: config, options: options)
            await client.disconnect()
            return true
        } catch {
            return false
        }
    }
}
