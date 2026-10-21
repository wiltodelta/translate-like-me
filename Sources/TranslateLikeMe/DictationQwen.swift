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
        // The app bundles the native Metal kernels. A CLI/test host can use
        // MLX's normal colocated mlx.metallib lookup instead.
        let library = Bundle.main.url(forResource: "mlx", withExtension: "metallib") ?? GPU.metallib ??
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("mlx.metallib")
        guard FileManager.default.fileExists(atPath: library.path) else { throw DictationError.notReady }
        GPU.metallib = library
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
            model = try await Qwen3ASRModel.fromModelDirectory(runtime)
            try Task.checkCancellation()
        } catch {
            model = nil
            Stream.gpu.synchronize()
            Memory.clearCache()
            throw error
        }
    }

    func transcribe(_ samples: [Float]) throws -> String {
        guard let model, let tokenizer = model.tokenizer else { throw DictationError.notReady }
        let endTokens = Set(["<|im_end|>", "<|endoftext|>"].compactMap { tokenizer.convertTokenToId($0) })
        guard endTokens.count == 2 else { throw DictationError.notReady }
        defer {
            Stream.gpu.synchronize()
            Memory.clearCache()
        }
        var transcripts: [String] = []
        // Use the SDK's low-energy boundaries to bound prefill memory on long
        // recordings. Each chunk has a fresh decoder cache and automatic language.
        let chunks = splitAudioIntoChunks(MLXArray(samples), sampleRate: 16_000, chunkDuration: 30)
        for (audio, _) in chunks {
            try Task.checkCancellation()
            let (features, mask, count) = model.preprocessAudio(audio)
            let prompt = model.buildPrompt(numAudioTokens: count)
            let cache = model.makeCache()
            do {
                let tokens = try DictationQwenDecoding.decode(endTokens: endTokens) { previous in
                    let logits: MLXArray
                    if let previous {
                        let input = MLXArray([Int32(previous)]).expandedDimensions(axis: 0)
                        logits = model(inputIds: input, cache: cache)
                    } else {
                        logits = model(inputIds: prompt, inputFeatures: features,
                                       featureAttentionMask: mask, cache: cache)
                    }
                    return logits[0..., -1, 0...].argMax(axis: -1).item(Int.self)
                }
                transcripts.append(DictationQwenDecoding.transcript(tokenizer.decode(tokens: tokens)))
            } catch DictationQwenDecoding.Failure.limit {
                throw DictationError.recognitionLimit
            }
        }
        try Task.checkCancellation()
        return transcripts.joined(separator: " ")
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
        let snapshot = DictationSnapshot(root: root, revision: source.revision,
                                         variant: "", required: DictationQwen.files)
        return try await snapshot.prepare(download: download) {
            let hub = HubApiWrapper(downloadBase: base, endpoint: source.endpoint)
            _ = try await hub.snapshot(from: .init(id: source.modelRepo), revision: source.revision,
                                       matching: DictationQwen.files) { progress($0.fractionCompleted * 0.95) }
        }
    }
}
