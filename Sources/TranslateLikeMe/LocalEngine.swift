import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import os
@preconcurrency import WhisperKit

private let log = Logger.app("local")

// A model loaded into memory, ready to complete a prompt.
protocol LocalGenerating: Sendable {
    func complete(_ prompt: String, maxTokens: Int) async throws -> String
}

protocol LocalLoading: Sendable {
    func load(_ model: LocalModel, from directory: URL) async throws -> any LocalGenerating
    // Frees what the unloaded model left in the runtime's buffer cache.
    func release()
}

// Runs translations on this Mac. One model is resident at a time: loading
// takes 2-6 s from a warm disk cache (docs/local-translation.md), so it stays
// loaded between runs, and is released after
// `idleDelay` without a run, or at once under memory pressure, since
// TranslateGemma holds 7.5 GB.
actor LocalEngine {
    static let shared = LocalEngine()

    static let idleDelay: Duration = .seconds(600)

    private let files: LocalModelFiles
    private let loader: any LocalLoading
    private let physicalMemory: UInt64
    private let sleep: @Sendable (Duration) async throws -> Void
    private var loaded: (model: LocalModel, generator: any LocalGenerating)?
    private var loading: (model: LocalModel, task: Task<any LocalGenerating, Error>)?
    private var running = 0
    private var idleRelease: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?

    init(files: LocalModelFiles = .live, loader: any LocalLoading = MLXLoader(),
         physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.files = files
        self.loader = loader
        self.physicalMemory = physicalMemory
        self.sleep = sleep
    }

    var loadedModel: LocalModel? { loaded?.model }

    func complete(system: String, text: String, model: LocalModel) async throws -> String {
        guard model.fits(physicalMemory: physicalMemory) else { throw LocalModelError.insufficientMemory(model) }
        guard files.isInstalled(model) else { throw LocalModelError.notDownloaded(model) }
        running += 1
        defer {
            running -= 1
            scheduleRelease()
        }
        let generator = try await generator(for: model)
        try Task.checkCancellation()
        return try await generator.complete(model.prompt(system: system, text: text),
                                            maxTokens: LocalModel.maxTokens(inputCharacters: text.count))
    }

    // A run for another model replaces the resident one; concurrent runs for
    // the same model share one load.
    private func generator(for model: LocalModel) async throws -> any LocalGenerating {
        if let loaded, loaded.model == model { return loaded.generator }
        if let loading, loading.model == model { return try await loading.task.value }
        unloadNow()
        let directory = files.root(for: model)
        let loader = loader
        let task = Task { try await loader.load(model, from: directory) }
        loading = (model, task)
        defer { if loading?.model == model { loading = nil } }
        startPressureMonitor()
        let started = ContinuousClock.now
        let generator = try await task.value
        let elapsed = started.duration(to: .now)
        log.notice("Local model \(model.rawValue, privacy: .public) loaded in \(elapsed, privacy: .public)")
        loaded = (model, generator)
        return generator
    }

    private func scheduleRelease() {
        idleRelease?.cancel()
        guard running == 0, loaded != nil else { return }
        let sleep = sleep
        idleRelease = Task { [weak self] in
            guard (try? await sleep(Self.idleDelay)) != nil, !Task.isCancelled else { return }
            await self?.releaseIfIdle(reason: "idle")
        }
    }

    func releaseIfIdle(reason: String) {
        guard running == 0, loading == nil, let model = loaded?.model else { return }
        log.notice("Local model \(model.rawValue, privacy: .public) released: \(reason, privacy: .public)")
        unloadNow()
    }

    private func unloadNow() {
        idleRelease?.cancel()
        idleRelease = nil
        guard loaded != nil else { return }
        loaded = nil
        loader.release()
    }

    // A run in progress keeps its model; the release waits for the next idle
    // check instead of pulling memory from under the generation.
    private func startPressureMonitor() {
        guard pressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler { [weak self] in
            Task { await self?.releaseIfIdle(reason: "memory pressure") }
        }
        pressure = source
        source.resume()
    }
}

// MLX on Metal, in this process. The tokenizer is the one WhisperKit already
// ships (the Hugging Face tokenizer without its Jinja templates, matching
// Python's token ids on both models' prompts, checked 2026-10-20); the prompt's
// turn markers come from LocalModel, so no chat template is needed.
struct MLXLoader: LocalLoading {
    func load(_ model: LocalModel, from directory: URL) async throws -> any LocalGenerating {
        guard MLXKernels.use() else { throw CocoaError(.fileNoSuchFile) }
        // MLX otherwise keeps freed buffers up to the memory limit.
        Memory.cacheLimit = 64 << 20
        let container = try await LLMModelFactory.shared.loadContainer(from: directory, using: TokenizerLoader())
        return Generator(container: container)
    }

    func release() { Memory.clearCache() }

    private struct Generator: LocalGenerating {
        let container: ModelContainer

        // The sampling of the benchmark (temperature 0.3, top-p 0.95). A
        // cancelled run ends the stream, which stops generating.
        func complete(_ prompt: String, maxTokens: Int) async throws -> String {
            try await container.perform { (context: ModelContext) in
                var context = context
                context.configuration.extraEOSTokens = LocalModel.stopTokens
                let tokens = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
                let stream = try MLXLMCommon.generate(
                    input: LMInput(tokens: MLXArray(tokens)),
                    parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.3, topP: 0.95),
                    context: context)
                var output = ""
                for await generation in stream {
                    if case .chunk(let text) = generation { output += text }
                }
                try Task.checkCancellation()
                return output
            }
        }
    }

    private struct TokenizerLoader: MLXLMCommon.TokenizerLoader {
        func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
            WhisperKitTokenizer(base: try await AutoTokenizerWrapper.from(modelFolder: directory, strict: false))
        }
    }

    private struct WhisperKitTokenizer: MLXLMCommon.Tokenizer {
        let base: TokenizerWrapper

        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            base.encode(text: text, addSpecialTokens: addSpecialTokens)
        }

        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
        }

        func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
        var bosToken: String? { base.bosToken }
        var eosToken: String? { base.eosToken }
        var unknownToken: String? { base.unknownToken }

        // Prompts arrive formatted (LocalModel.prompt).
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                               additionalContext: [String: any Sendable]?) throws -> [Int] {
            throw TokenizerError.missingChatTemplate
        }
    }
}
