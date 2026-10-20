import Foundation

enum LLMThinkingValidationResult: Equatable, Sendable {
    case valid
    case adjusted(mode: LLMThinkingMode, message: String)
    case failed(message: String)
}

/// “测试连接”不仅验证接口可达，还验证所选深度思考状态。
///
/// 当服务端明确拒绝当前状态，或响应证据与当前状态冲突时，验证器会在同一次测试中
/// 尝试相反状态；只有相反状态也经过真实请求确认后，才返回自动纠正结果。
enum LLMThinkingModeValidator {
    static let probeText = L(
        "请在内部逐步推理：求最小正整数 n，使它除以 2 余 1、除以 3 余 2，依此类推，直到除以 10 余 9。最终只返回 n。",
        "Reason step by step internally: find the smallest positive integer n whose remainders when divided by 2 through 10 are respectively 1 through 9. Return only n."
    )

    typealias Probe = (LLMConfig) async throws -> LLMThinkingProbeEvidence

    static func validate(
        provider: LLMProvider,
        config: LLMConfig,
        client: any LLMClient
    ) async -> LLMThinkingValidationResult {
        await validate(provider: provider, config: config) { candidate in
            try await client.probeThinkingMode(config: candidate)
        }
    }

    static func validate(
        provider: LLMProvider,
        config: LLMConfig,
        probe: Probe
    ) async -> LLMThinkingValidationResult {
        let requestedMode = config.thinkingMode

        if let fixedMode = provider.fixedThinkingMode(for: config.model) {
            return await validateKnownFixedMode(
                config: config,
                fixedMode: fixedMode,
                probe: probe
            )
        }

        do {
            let evidence = try await probe(config)
            switch assess(
                evidence,
                requestedMode: requestedMode
            ) {
            case .confirmed:
                return .valid
            case .contradicted:
                return await validateCorrection(
                    config: config.withThinkingMode(requestedMode.opposite),
                    correctedMode: requestedMode.opposite,
                    probe: probe
                )
            case .unverified:
                // 当前状态没有足够证据时也验证相反状态。这样既不会把“接口能返回”
                // 误当成“开关已生效”，又能在相反状态可确认时自动纠正开关。
                return await validateAlternativeAfterUnverified(
                    config: config,
                    initialEvidence: evidence,
                    probe: probe
                )
            }
        } catch {
            guard isThinkingModeRejection(error) else {
                return .failed(message: error.localizedDescription)
            }
            return await validateCorrection(
                config: config.withThinkingMode(requestedMode.opposite),
                correctedMode: requestedMode.opposite,
                probe: probe
            )
        }
    }

    private static func validateKnownFixedMode(
        config: LLMConfig,
        fixedMode: LLMThinkingMode,
        probe: Probe
    ) async -> LLMThinkingValidationResult {
        do {
            let evidence = try await probe(config.withThinkingMode(fixedMode))
            if let actualMode = actualMode(from: evidence),
               actualMode != fixedMode {
                return .failed(message: L(
                    "模型返回的深度思考状态与已知能力不一致，测试未通过",
                    "The model's reasoning state conflicts with its known capability; test failed"
                ))
            }
            guard config.thinkingMode != fixedMode else { return .valid }
            return .adjusted(
                mode: fixedMode,
                message: correctionMessage(for: fixedMode)
            )
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    private static func validateCorrection(
        config: LLMConfig,
        correctedMode: LLMThinkingMode,
        probe: Probe
    ) async -> LLMThinkingValidationResult {
        do {
            let evidence = try await probe(config)
            switch assess(
                evidence,
                requestedMode: correctedMode
            ) {
            case .confirmed:
                return .adjusted(
                    mode: correctedMode,
                    message: correctionMessage(for: correctedMode)
                )
            case .contradicted:
                return .failed(message: L(
                    "模型返回的深度思考状态与开关不一致，测试未通过",
                    "The model's reasoning state does not match the switch; test failed"
                ))
            case .unverified:
                return .failed(message: unverifiedMessage)
            }
        } catch {
            if isThinkingModeRejection(error) {
                return .failed(message: L(
                    "服务端不接受深度思考控制参数，无法验证开关状态",
                    "The server rejected reasoning controls, so the switch state could not be verified"
                ))
            }
            return .failed(message: error.localizedDescription)
        }
    }

    private static func validateAlternativeAfterUnverified(
        config: LLMConfig,
        initialEvidence: LLMThinkingProbeEvidence,
        probe: Probe
    ) async -> LLMThinkingValidationResult {
        let requestedMode = config.thinkingMode
        let alternativeMode = requestedMode.opposite
        do {
            let evidence = try await probe(config.withThinkingMode(alternativeMode))
            switch assess(
                evidence,
                requestedMode: alternativeMode
            ) {
            case .confirmed:
                if requestedMode == .disabled,
                   actualMode(from: initialEvidence) == nil,
                   actualMode(from: evidence) == .enabled,
                   evidence.controlAccepted {
                    // 同一题目只改变开关：关闭时没有推理通道，开启时明确出现推理，
                    // 这组差分证据足以确认关闭状态确实生效。
                    return .valid
                }
                return .adjusted(
                    mode: alternativeMode,
                    message: unverifiedCorrectionMessage(for: alternativeMode)
                )
            case .contradicted:
                // 请求相反状态时仍明确观察到原状态，说明当前所选状态实际有效，
                // 只是该服务端无法在第一次响应里直接回报它。
                return .valid
            case .unverified:
                return .failed(message: unverifiedMessage)
            }
        } catch {
            if isThinkingModeRejection(error) {
                return .failed(message: L(
                    "服务端不接受深度思考控制参数，无法验证开关状态",
                    "The server rejected reasoning controls, so the switch state could not be verified"
                ))
            }
            return .failed(message: error.localizedDescription)
        }
    }

    private enum Assessment {
        case confirmed
        case contradicted
        case unverified
    }

    private static func assess(
        _ evidence: LLMThinkingProbeEvidence,
        requestedMode: LLMThinkingMode
    ) -> Assessment {
        guard let actualMode = actualMode(from: evidence) else { return .unverified }
        return actualMode == requestedMode ? .confirmed : .contradicted
    }

    private static func actualMode(
        from evidence: LLMThinkingProbeEvidence
    ) -> LLMThinkingMode? {
        evidence.observedMode
    }

    private static func isThinkingModeRejection(_ error: Error) -> Bool {
        (error as? LLMError)?.isThinkingModeRejection == true
    }

    private static var unverifiedMessage: String {
        L(
            "模型可以连接，但没有返回足够证据确认深度思考开关已生效，因此测试未通过",
            "The model connected, but did not provide enough evidence that the reasoning switch took effect"
        )
    }

    private static func correctionMessage(for mode: LLMThinkingMode) -> String {
        switch mode {
        case .enabled:
            return L(
                "该模型不支持关闭深度思考，已自动调整为开启；连接测试通过",
                "This model cannot disable reasoning. The switch was changed to On and the connection test passed."
            )
        case .disabled:
            return L(
                "该模型不支持开启深度思考，已自动调整为关闭；连接测试通过",
                "This model cannot enable reasoning. The switch was changed to Off and the connection test passed."
            )
        }
    }

    private static func unverifiedCorrectionMessage(for mode: LLMThinkingMode) -> String {
        switch mode {
        case .enabled:
            return L(
                "无法确认关闭状态，已自动调整为经过验证的开启状态；连接测试通过",
                "The Off state could not be verified. The switch was changed to the verified On state, and the connection test passed."
            )
        case .disabled:
            return L(
                "无法确认开启状态，已自动调整为经过验证的关闭状态；连接测试通过",
                "The On state could not be verified. The switch was changed to the verified Off state, and the connection test passed."
            )
        }
    }
}
