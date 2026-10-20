enum ASRRequestOptionsFactory {
    static func current(enablePunc: Bool) -> ASRRequestOptions {
        let biasSettings = ASRBiasSettingsStorage.load()
        let hotwords = HotwordStorage.loadEffectiveForASR()
        return ASRRequestOptions(
            enablePunc: enablePunc,
            hotwords: hotwords.words,
            userHotwordCount: hotwords.userCount,
            correctionWords: SnippetStorage.userCorrectionWords(),
            boostingTableID: biasSettings.boostingTableID,
            contextHistoryLength: biasSettings.contextHistoryLength
        )
    }
}
