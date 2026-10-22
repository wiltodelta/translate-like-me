import Foundation
@preconcurrency import MLX
@preconcurrency import MLXAudioSTT
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

    func transcribe(_ samples: [Float], preference: DictationLanguagePreference) throws -> String {
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
        var transcripts: [String] = []
        // Use the SDK's low-energy boundaries to bound prefill memory on long
        // recordings. Each chunk has a fresh decoder cache and automatic language.
        let chunks = splitAudioIntoChunks(MLXArray(samples), sampleRate: 16_000, chunkDuration: 30)
        for (audio, _) in chunks {
            try Task.checkCancellation()
            do {
                let tokens = try Self.decode(model, audio: audio, prefix: languagePrefix, endTokens: endTokens)
                transcripts.append(DictationQwenDecoding.transcript(tokenizer.decode(tokens: tokens)))
            } catch DictationQwenDecoding.Failure.limit {
                throw DictationError.recognitionLimit
            }
        }
        try Task.checkCancellation()
        return transcripts.joined(separator: " ")
    }

    // Greedy decoding of one chunk with a fresh decoder cache.
    private static func decode(_ model: Qwen3ASRModel, audio: MLXArray, prefix: DictationLanguagePrefix,
                               endTokens: Set<Int>) throws -> [Int] {
        let (features, mask, count) = model.preprocessAudio(audio)
        let prompt = model.buildPrompt(numAudioTokens: count)
        let cache = model.makeCache()
        let reach = prefix.reach
        var generated: [Int] = []
        var ahead: MLXArray?
        return try DictationQwenDecoding.decode(endTokens: endTokens) { previous in
            let token: MLXArray
            if let ahead {
                token = ahead
            } else {
                let logits = previous.map {
                    model(inputIds: MLXArray([Int32($0)]).expandedDimensions(axis: 0), cache: cache)
                } ?? model(inputIds: prompt, inputFeatures: features, featureAttentionMask: mask, cache: cache)
                token = Self.nextToken(logits: logits, generated: generated, prefix: prefix)
            }
            // Once no language preference can apply, queue the following
            // step on the GPU before reading this token: about 10% faster
            // on phrases of 30+ tokens, identical tokens (docs/dictation-latency.md).
            ahead = nil
            if generated.count + 1 >= reach {
                let following = model(inputIds: token.reshaped(1, 1).asType(.int32), cache: cache)[0, -1, 0...]
                    .argMax(axis: -1)
                asyncEval(following)
                ahead = following
            }
            let value = token.item(Int.self)
            generated.append(value)
            return value
        }
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
