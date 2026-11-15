import Foundation
import os
@preconcurrency import MLX
@preconcurrency import MLXAudioSTT
@preconcurrency import MLXNN
@preconcurrency import WhisperKit

// Own the non-Sendable MLX model and all array operations in one actor. No SDK
// streaming producer may outlive cancellation or keep an old model running.
actor DictationQwen {
    static let source = ModelDownloadConfig(modelRepo: "mlx-community/Qwen3-ASR-1.7B-8bit",
                                           revision: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55")
    static let files = ["config.json", "model.safetensors", "vocab.json", "merges.txt", "tokenizer_config.json"]
    private var model: Qwen3ASRModel?

    init(root: URL) async throws {
        guard MLXKernels.use() else { throw DictationError.notReady }
        let runtime = FileManager.default.temporaryDirectory.appendingPathComponent("tlm-qwen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtime) }
        // The SDK derives tokenizer.json. Keep that generated file outside the
        // verified Hub snapshot, so offline integrity checks never trust it.
        for file in Self.files {
            try FileManager.default.createSymbolicLink(at: runtime.appendingPathComponent(file),
                                                       withDestinationURL: root.appendingPathComponent(file))
        }
        do {
            let loaded = try await Qwen3ASRModel.fromModelDirectory(runtime)
            try Task.checkCancellation()
            Self.warmUp(loaded)
            model = loaded
        } catch {
            model = nil
            Stream.gpu.synchronize()
            Memory.clearCache()
            throw error
        }
    }

    // The first pass after loading builds GPU pipelines: about 30 ms on the
    // first dictation, 320 ms when the system shader cache is cold, as after an
    // update. One second of silence pays for it here.
    private static func warmUp(_ model: Qwen3ASRModel) {
        let (features, mask, count) = model.preprocessAudio(MLXArray.zeros([16_000]))
        let cache = model.makeCache()
        let first = model(inputIds: model.buildPrompt(numAudioTokens: count), inputFeatures: features,
                          featureAttentionMask: mask, cache: cache)[0, -1, 0...].argMax(axis: -1)
        eval(model(inputIds: first.reshaped(1, 1).asType(.int32), cache: cache))
        Stream.gpu.synchronize()
        Memory.clearCache()
    }

    func transcribe(_ samples: [Float], preference: DictationLanguagePreference,
                    context: String = "", vocabulary: DictationVocabulary = .empty) throws -> String {
        guard let model, let tokenizer = model.tokenizer else { throw DictationError.notReady }
        let endTokens = Set(["<|im_end|>", "<|endoftext|>"].compactMap { tokenizer.convertTokenToId($0) })
        guard endTokens.count == 2 else { throw DictationError.notReady }
        defer {
            Stream.gpu.synchronize()
            Memory.clearCache()
        }
        let names = preference.resolvedNames(supported: model.config.supportLanguages)
        let languagePrefix = DictationLanguagePrefix(start: tokenizer.encode(text: "language"),
            preferred: names.sorted().map { tokenizer.encode(text: "language " + $0) })
        let decoder = ChunkDecoder(model: model, embed: Self.textEmbedding(of: model),
                                   prefix: languagePrefix, endTokens: endTokens)
        var transcripts: [String] = []
        // Use the SDK's low-energy boundaries to bound prefill memory on long
        // recordings. Each chunk has a fresh decoder cache and automatic language.
        let chunks = splitAudioIntoChunks(MLXArray(samples), sampleRate: 16_000, chunkDuration: 30)
        for (audio, _) in chunks {
            try Task.checkCancellation()
            let chunkContext = DictationContext.chunkContext(base: context, vocabulary: vocabulary,
                                                             previousChunks: transcripts)
            do {
                let text = try decoder.decode(audio, context: chunkContext)
                if !text.isEmpty { transcripts.append(text) }
            } catch let failure as DictationQwenDecoding.Failure {
                Logger.app("dictation").error("Qwen decoding stopped: \(String(describing: failure), privacy: .public)")
                throw DictationError.recognitionLimit
            }
        }
        try Task.checkCancellation()
        return DictationTextSpacing.joinChunks(transcripts)
    }

    private struct PreparedAudio {
        let features: MLXArray
        let mask: MLXArray
        let cached: (embeddings: MLXArray, embed: Embedding)?
        let count: Int
    }

    private struct ChunkDecoder {
        let model: Qwen3ASRModel
        let embed: Embedding?
        let prefix: DictationLanguagePrefix
        let endTokens: Set<Int>

        // Contextual prompts bias Qwen's language token toward the prompt's script if
        // `language` is unset. Detect the spoken language without context first, then
        // decode the transcript with that language locked and destination context set,
        // sharing the single audioTower encoding across both passes.
        func decode(_ audio: MLXArray, context: String) throws -> String {
            guard let tokenizer = model.tokenizer else { throw DictationError.notReady }
            let raw = model.preprocessAudio(audio)
            let cached: (embeddings: MLXArray, embed: Embedding)?
            if !context.isEmpty, let embed {
                let encoded = model.getAudioFeatures(raw.0, featureAttentionMask: raw.1)
                asyncEval(encoded)
                cached = (encoded, embed)
            } else {
                cached = nil
            }
            let prepared = PreparedAudio(features: raw.0, mask: raw.1, cached: cached, count: raw.2)
            var prompt = model.buildPrompt(numAudioTokens: prepared.count)
            var activePrefix = prefix
            if !context.isEmpty {
                switch try DictationQwen.detectLanguage(model, audio: prepared, prompt: prompt,
                                                        prefix: prefix, endTokens: endTokens) {
                case .noSpeech:
                    return ""
                case .language(let detected):
                    prompt = model.buildPrompt(numAudioTokens: prepared.count, context: context, language: detected)
                    activePrefix = DictationLanguagePrefix(start: [], preferred: [])
                case .fallback:
                    break
                }
            }
            let tokens = try DictationQwen.decodePrompt(model, audio: prepared, prompt: prompt,
                                                        prefix: activePrefix, endTokens: endTokens)
            return DictationQwenDecoding.transcript(tokenizer.decode(tokens: tokens))
        }
    }

    static func textEmbedding(of model: Qwen3ASRModel) -> Embedding? {
        model.children()[unwrapping: "model"]?.children()[unwrapping: "embed_tokens"] as? Embedding
    }

    static func mergedAudioEmbeddings(_ model: Qwen3ASRModel, prompt: MLXArray,
                                      audioFeatures: MLXArray, embed: Embedding) -> MLXArray {
        let promptEmbeds = embed(prompt)
        return model.mergeAudioFeatures(
            inputsEmbeds: promptEmbeds,
            audioFeatures: audioFeatures.asType(promptEmbeds.dtype),
            inputIds: prompt
        )
    }

    private static func detectLanguage(_ model: Qwen3ASRModel, audio: PreparedAudio,
                                       prompt: MLXArray, prefix: DictationLanguagePrefix,
                                       endTokens: Set<Int>) throws -> DictationQwenDecoding.HeaderOutcome {
        guard let tokenizer = model.tokenizer else { throw DictationError.notReady }
        let asrTextToken = tokenizer.convertTokenToId("<asr_text>")
        let forward = makeForward(model, prompt: prompt, audio: audio)
        var header: [Int] = []
        for _ in 0..<12 {
            try Task.checkCancellation()
            let logits = forward(stepInput(header.last))
            let value = Self.nextToken(logits: logits, generated: header, prefix: prefix).item(Int.self)
            if endTokens.contains(value) { break }
            header.append(value)
            if let asrTextToken, value != asrTextToken { continue }
            let decoded = tokenizer.decode(tokens: header)
            if decoded.contains("<asr_text>") {
                return DictationQwenDecoding.headerOutcome(decoded, supported: model.config.supportLanguages)
            }
        }
        return .fallback
    }

    // Greedy decoding of one chunk with a fresh decoder cache.
    private static func decodePrompt(_ model: Qwen3ASRModel, audio: PreparedAudio,
                                     prompt: MLXArray, prefix: DictationLanguagePrefix,
                                     endTokens: Set<Int>) throws -> [Int] {
        let forward = makeForward(model, prompt: prompt, audio: audio)
        let reach = prefix.reach
        var generated: [Int] = []
        var ahead: MLXArray?
        return try DictationQwenDecoding.decode(endTokens: endTokens) { previous in
            let token: MLXArray
            if let ahead {
                token = ahead
            } else {
                let logits = forward(stepInput(previous))
                token = Self.nextToken(logits: logits, generated: generated, prefix: prefix)
            }
            // Once no language preference can apply, queue the following
            // step on the GPU before reading this token: about 10% faster
            // on phrases of 30+ tokens, identical tokens (docs/dictation-latency.md).
            ahead = nil
            if generated.count + 1 >= reach {
                let following = forward(token.reshaped(1, 1).asType(.int32))[0, -1, 0...]
                    .argMax(axis: -1)
                asyncEval(following)
                ahead = following
            }
            let value = token.item(Int.self)
            generated.append(value)
            return value
        }
    }

    private static func makeForward(_ model: Qwen3ASRModel, prompt: MLXArray,
                                    audio: PreparedAudio) -> (MLXArray?) -> MLXArray {
        let cache = model.makeCache()
        return { nextInput in
            if let nextInput { return model(inputIds: nextInput, cache: cache) }
            if let cached = audio.cached {
                let merged = mergedAudioEmbeddings(model, prompt: prompt, audioFeatures: cached.embeddings,
                                                   embed: cached.embed)
                return model(inputIds: prompt, inputEmbeddings: merged, cache: cache)
            }
            return model(inputIds: prompt, inputFeatures: audio.features,
                         featureAttentionMask: audio.mask, cache: cache)
        }
    }

    private static func stepInput(_ previous: Int?) -> MLXArray? {
        previous.map { MLXArray([Int32($0)]).expandedDimensions(axis: 0) }
    }

    // Lazy, so the caller decides when the GPU result is read.
    static func nextToken(logits: MLXArray, generated: [Int], prefix: DictationLanguagePrefix) -> MLXArray {
        let nextLogits = logits[0, -1, 0...]
        for token in prefix.nextTokens(after: generated) {
            nextLogits[token] += MLXArray(DictationLanguagePreference.logWeight)
        }
        return nextLogits.argMax(axis: -1)
    }

    func unload() {
        model = nil
        Stream.gpu.synchronize()
        Memory.clearCache()
    }
}

extension DictationEngine {
    func prepareQwen(in base: URL, download: Bool,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let source = DictationQwen.source
        let root = ModelDownloader(config: source).localRepoLocation(downloadBase: base)
        let snapshot = ModelSnapshot(root: root, revision: source.revision,
                                     variant: "", required: DictationQwen.files)
        return try await snapshot.prepareForDictation(download: download) {
            let hub = HubApiWrapper(downloadBase: base, endpoint: source.endpoint)
            _ = try await hub.snapshot(from: .init(id: source.modelRepo), revision: source.revision,
                                       matching: DictationQwen.files) { progress($0.fractionCompleted * 0.95) }
        }
    }
}
