import CoreML
@preconcurrency import WhisperKit

// WhisperKit's dedicated language pass bypasses custom text logits filters.
// Inject the preference at its sampler, while forwarding text decoding and model lifecycle.
final class DictationWhisperLanguage: TextDecoding, WhisperMLModel {
    let base: TextDecoder
    let preference: DictationLanguagePreference

    init(base: TextDecoder, preference: DictationLanguagePreference) {
        self.base = base
        self.preference = preference
    }

    var model: MLModel? { get { base.model } set { base.model = newValue } }
    var tokenizer: WhisperTokenizer? { get { base.tokenizer } set { base.tokenizer = newValue } }
    var isModelMultilingual: Bool { get { base.isModelMultilingual } set { base.isModelMultilingual = newValue } }
    var logitsFilters: [any LogitsFiltering]? { get { base.logitsFilters } set { base.logitsFilters = newValue } }
    var supportsWordTimestamps: Bool { base.supportsWordTimestamps }
    var logitsSize: Int? { base.logitsSize }
    var kvCacheEmbedDim: Int? { base.kvCacheEmbedDim }
    var kvCacheMaxSequenceLength: Int? { base.kvCacheMaxSequenceLength }
    var windowSize: Int? { base.windowSize }
    var embedSize: Int? { base.embedSize }

    func loadModel(at modelPath: URL, computeUnits: MLComputeUnits, prewarmMode: Bool) async throws {
        try await base.loadModel(at: modelPath, computeUnits: computeUnits, prewarmMode: prewarmMode)
    }

    func unloadModel() { base.unloadModel() }

    func predictLogits(_ inputs: any TextDecoderInputType) async throws -> (any TextDecoderOutputType)? {
        try await base.predictLogits(inputs)
    }

    func prepareDecoderInputs(withPrompt initialPrompt: [Int]) throws -> any DecodingInputsType {
        try base.prepareDecoderInputs(withPrompt: initialPrompt)
    }

    func prefillDecoderInputs(_ decoderInputs: any DecodingInputsType,
                              withOptions options: DecodingOptions?) async throws -> any DecodingInputsType {
        try await base.prefillDecoderInputs(decoderInputs, withOptions: options)
    }

    func decodeText(from encoderOutput: any AudioEncoderOutputType, using decoderInputs: any DecodingInputsType,
                    sampler tokenSampler: any TokenSampling, options decoderOptions: DecodingOptions,
                    callback: TranscriptionCallback?) async throws -> DecodingResult {
        try await base.decodeText(from: encoderOutput, using: decoderInputs, sampler: tokenSampler,
                                  options: decoderOptions, callback: callback)
    }

    func detectLanguage(from encoderOutput: any AudioEncoderOutputType, using decoderInputs: any DecodingInputsType,
                        sampler tokenSampler: any TokenSampling, options: DecodingOptions,
                        temperature: FloatType) async throws -> DecodingResult {
        let supported = Set(tokenizer?.allLanguageTokens.compactMap {
            tokenizer?.decode(tokens: [$0]).trimmingCharacters(in: CharacterSet(charactersIn: "<|>"))
        } ?? [])
        let codes = preference.resolvedCodes(supported: supported)
        let tokens = Set(codes.compactMap { tokenizer?.convertTokenToId("<|\($0)|>") })
        let sampler = DictationWhisperLanguageSampler(base: tokenSampler, preferredTokens: tokens)
        return try await base.detectLanguage(from: encoderOutput, using: decoderInputs, sampler: sampler,
                                             options: options, temperature: temperature)
    }

    static func updateKVCache(keyTensor: MLMultiArray, keySlice: MLMultiArray,
                              valueTensor: MLMultiArray, valueSlice: MLMultiArray, insertAtIndex index: Int) {
        TextDecoder.updateKVCache(keyTensor: keyTensor, keySlice: keySlice,
                                  valueTensor: valueTensor, valueSlice: valueSlice, insertAtIndex: index)
    }
}

struct DictationWhisperLanguageSampler: TokenSampling {
    let base: any TokenSampling
    let preferredTokens: Set<Int>

    func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult {
        for token in preferredTokens where token >= 0 && token < logits.count {
            logits[token] = NSNumber(value: logits[token].floatValue + DictationLanguagePreference.logWeight)
        }
        return await base.update(tokens: tokens, logits: logits, logProbs: logProbs)
    }

    func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult {
        base.finalize(tokens: tokens, logProbs: logProbs)
    }
}
