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
// loaded between runs, and is released after `idleDelay` without a run.
// Memory pressure releases it once the active operation drains, since
// TranslateGemma holds 7.5 GB.
actor LocalEngine {
    static let shared = LocalEngine()

    static let idleDelay: Duration = .seconds(600)

    private let files: LocalModelFiles
    private let loader: any LocalLoading
    private let physicalMemory: UInt64
    private let sleep: @Sendable (Duration) async throws -> Void
    private var loaded: (model: LocalModel, generator: any LocalGenerating)?
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseRequested = false
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
    var queuedOperations: Int { waiters.count }

    // Actors reenter across awaits. Keep model loading, generation and deletion
    // exclusive for the whole operation, including the SDK producer's drain.
    private func acquire() async {
        idleRelease?.cancel()
        idleRelease = nil
        if occupied { await withCheckedContinuation { waiters.append($0) } } else { occupied = true }
    }

    private func finishOperation() {
        if releaseRequested {
            releaseRequested = false
            unloadNow()
        }
        if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
        scheduleRelease()
    }

    func remove(_ model: LocalModel) async throws {
        try Task.checkCancellation()
        await acquire()
        defer { finishOperation() }
        try Task.checkCancellation()
        if loaded?.model == model { unloadNow() }
        try files.remove(model)
    }

    func complete(system: String, text: String, model: LocalModel) async throws -> String {
        try Task.checkCancellation()
        await acquire()
        defer { finishOperation() }
        try Task.checkCancellation()
        guard model.fits(physicalMemory: physicalMemory) else { throw LocalModelError.insufficientMemory(model) }
        guard files.isInstalled(model) else { throw LocalModelError.notDownloaded(model) }
        let generator = try await generator(for: model)
        try Task.checkCancellation()
        return try await generator.complete(model.prompt(system: system, text: text),
                                            maxTokens: LocalModel.maxTokens(inputCharacters: text.count))
    }

    // A different model replaces the resident one after the preceding run drains.
    private func generator(for model: LocalModel) async throws -> any LocalGenerating {
        if let loaded, loaded.model == model { return loaded.generator }
        unloadNow()
        startPressureMonitor()
        let started = ContinuousClock.now
        let generator = try await loader.load(model, from: files.root(for: model))
        try Task.checkCancellation()
        let elapsed = started.duration(to: .now)
        log.notice("Local model \(model.rawValue, privacy: .public) loaded in \(elapsed, privacy: .public)")
        loaded = (model, generator)
        return generator
    }

    private func scheduleRelease() {
        idleRelease?.cancel()
        guard !occupied, loaded != nil else { return }
        let sleep = sleep
        idleRelease = Task { [weak self] in
            guard (try? await sleep(Self.idleDelay)) != nil, !Task.isCancelled else { return }
            await self?.releaseIfIdle(reason: "idle")
        }
    }

    func releaseIfIdle(reason: String) {
        guard !occupied else { releaseRequested = true; return }
        guard let model = loaded?.model else { return }
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

    // A release requested during generation runs as soon as that operation drains.
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
        // cancelled run drains the SDK producer before releasing the model.
        func complete(_ prompt: String, maxTokens: Int) async throws -> String {
            try await container.perform { (context: ModelContext) in
                var context = context
                context.configuration.extraEOSTokens = LocalModel.stopTokens
                let tokens = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
                try Task.checkCancellation()
                let input = LMInput(tokens: MLXArray(tokens))
                let iterator = try TokenIterator(input: input, model: context.model,
                    parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.3, topP: 0.95))
                let (stream, producer) = generateTask(promptTokenCount: tokens.count,
                    modelConfiguration: context.configuration, tokenizer: context.tokenizer, iterator: iterator)
                return try await LocalGeneration.collect(stream, producer: producer)
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

// Collect one SDK generation. The producer owns the model until it completes.
enum LocalGeneration {
    static func collect(_ stream: AsyncStream<Generation>, producer: Task<Void, Never>) async throws -> String {
        var output = ""
        var stop: GenerateStopReason?
        for await generation in stream {
            switch generation {
            case .chunk(let text): output += text
            case .info(let info): stop = info.stopReason
            default: break
            }
        }
        // AsyncStream cancellation stops its consumer before the worker has
        // synchronized the GPU. Keep the model locked until that worker exits.
        if Task.isCancelled { producer.cancel() }
        await producer.value
        try Task.checkCancellation()
        guard stop == .stop else { throw LocalModelError.outputLimit }
        return output
    }
}
