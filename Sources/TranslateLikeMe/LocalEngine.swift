import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import os
@preconcurrency import WhisperKit

private let log = Logger.app("local")

// A model loaded into memory, ready to complete a prompt.
protocol LocalGenerating: Sendable {
    func prepare(head: String) async throws
    // `head` begins `prompt` and repeats across runs, so its state can be reused.
    func complete(_ prompt: String, head: String, maxTokens: Int) async throws -> String
}

protocol LocalLoading: Sendable {
    // `drafter` is the draft model's directory when the model has one.
    func load(_ model: LocalModel, from directory: URL, drafter: URL?) async throws -> any LocalGenerating
    // Frees what the unloaded model left in the runtime's buffer cache.
    func release()
}

// Runs translations on this Mac. One model is resident at a time: loading
// takes 2-6 s from a warm disk cache (docs/local-translation.md), so it stays
// loaded between runs until memory pressure, a configuration change or removal.
// Memory pressure releases it once the active operation drains, since
// TranslateGemma holds 7.5 GB.
actor LocalEngine {
    static let shared = LocalEngine()
    static let promptHeadLimit = 3

    private let files: LocalModelFiles
    private let loader: any LocalLoading
    private let physicalMemory: UInt64
    private var loaded: (model: LocalModel, generator: any LocalGenerating)?
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseRequested = false
    private var pressure: DispatchSourceMemoryPressure?

    init(files: LocalModelFiles = .live, loader: any LocalLoading = MLXLoader(),
         physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.files = files
        self.loader = loader
        self.physicalMemory = physicalMemory
    }

    var loadedModel: LocalModel? { loaded?.model }
    var queuedOperations: Int { waiters.count }

    // Actors reenter across awaits. Keep model loading, generation and deletion
    // exclusive for the whole operation, including the SDK producer's drain.
    private func acquire() async {
        if occupied { await withCheckedContinuation { waiters.append($0) } } else { occupied = true }
    }

    private func finishOperation() {
        if releaseRequested {
            releaseRequested = false
            unloadNow()
        }
        if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
    }

    func remove(_ model: LocalModel) async throws {
        try Task.checkCancellation()
        await acquire()
        defer { finishOperation() }
        try Task.checkCancellation()
        if loaded?.model == model { unloadNow() }
        try files.remove(model)
    }

    // Prepare only installed assets, without generating or sending user text.
    // This shares the same exclusive queue as a foreground run and removal.
    func prepare(model: LocalModel, systems: [String]) async throws {
        try Task.checkCancellation()
        await acquire()
        defer { finishOperation() }
        try Task.checkCancellation()
        if loaded?.model != model { unloadNow() }
        let generator = try await generator(for: model)
        for system in systems {
            try Task.checkCancellation()
            // Let a waiting foreground operation build its own head immediately.
            guard waiters.isEmpty else { break }
            try await generator.prepare(head: model.promptHead(system: system))
        }
    }

    func complete(system: String, text: String, model: LocalModel) async throws -> String {
        try Task.checkCancellation()
        await acquire()
        defer { finishOperation() }
        try Task.checkCancellation()
        let generator = try await generator(for: model)
        try Task.checkCancellation()
        return try await generator.complete(model.prompt(system: system, text: text),
                                            head: model.promptHead(system: system),
                                            maxTokens: LocalModel.maxTokens(inputCharacters: text.count))
    }

    // A different model replaces the resident one after the preceding run drains.
    private func generator(for model: LocalModel) async throws -> any LocalGenerating {
        guard model.fits(physicalMemory: physicalMemory) else { throw LocalModelError.insufficientMemory(model) }
        guard files.isInstalled(model) else { throw LocalModelError.notDownloaded(model) }
        if let loaded, loaded.model == model { return loaded.generator }
        unloadNow()
        startPressureMonitor()
        let started = ContinuousClock.now
        let generator = try await loader.load(model, from: files.root(for: model),
                                              drafter: files.drafterRoot(for: model))
        try Task.checkCancellation()
        let elapsed = started.duration(to: .now)
        log.notice("Local model \(model.rawValue, privacy: .public) loaded in \(elapsed, privacy: .public)")
        loaded = (model, generator)
        return generator
    }

    func releaseIfIdle(reason: String) {
        guard !occupied else { releaseRequested = true; return }
        guard let model = loaded?.model else { return }
        log.notice("Local model \(model.rawValue, privacy: .public) released: \(reason, privacy: .public)")
        unloadNow()
    }

    private func unloadNow() {
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
    // Tokens per drafting round, one of them the previous round's bonus; 3
    // was as fast as 4 with more drafts accepted (docs/local-model-candidates.md).
    static let draftBlock = 3

    func load(_ model: LocalModel, from directory: URL, drafter: URL?) async throws -> any LocalGenerating {
        guard MLXKernels.use() else { throw CocoaError(.fileNoSuchFile) }
        // MLX otherwise keeps freed buffers up to the memory limit.
        Memory.cacheLimit = 64 << 20
        let container = model.loadsThroughVLM
            ? try await VLMModelFactory.shared.loadContainer(from: directory, using: TokenizerLoader())
            : try await LLMModelFactory.shared.loadContainer(from: directory, using: TokenizerLoader())
        let maskIDs = await container.perform { (context: ModelContext) in
            model.maskedTokens.compactMap { context.tokenizer.convertTokenToId($0) }
        }
        if maskIDs.count != model.maskedTokens.count {
            log.error("Local model \(model.rawValue, privacy: .public) lacks a token it must mask")
        }
        var draft: Draft?
        if let drafter {
            await Gemma4AssistantRegistration.register()
            draft = Draft(model: try await MTPDrafterModelFactory.shared.load(from: drafter,
                                                                              using: TokenizerLoader()).model)
        }
        return Generator(container: container, heads: PromptHeads(), draft: draft, maskIDs: maskIDs)
    }

    func release() { Memory.clearCache() }

    // The draft model is not Sendable; it is used only inside the target's
    // `ModelContainer.perform`, which runs one generation at a time.
    final class Draft: @unchecked Sendable {
        let model: any MTPDrafterModel
        init(model: any MTPDrafterModel) { self.model = model }
    }

    private struct Generator: LocalGenerating {
        let container: ModelContainer
        let heads: PromptHeads
        let draft: Draft?
        let maskIDs: [Int]

        func prepare(head: String) async throws {
            try await container.perform { (context: ModelContext) in
                try Task.checkCancellation()
                let parameters = GenerateParameters(maxTokens: 1, temperature: 0.3, topP: 0.95)
                let tokens = context.tokenizer.encode(text: head, addSpecialTokens: false)
                guard !tokens.isEmpty else { return }
                _ = try heads.prepare(tokens, model: context.model, parameters: parameters)
            }
        }

        // The sampling of the benchmark (temperature 0.3, top-p 0.95). A
        // cancelled run drains the SDK producer before releasing the model.
        func complete(_ prompt: String, head: String, maxTokens: Int) async throws -> String {
            try await container.perform { (context: ModelContext) in
                var context = context
                context.configuration.extraEOSTokens = LocalModel.stopTokens
                let tokens = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
                try Task.checkCancellation()
                let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0.3, topP: 0.95)
                let (cache, rest) = try heads.split(tokens, head: context.tokenizer.encode(text: head,
                    addSpecialTokens: false), model: context.model, parameters: parameters)
                let input = LMInput(tokens: MLXArray(rest))
                let ids = maskIDs
                let components = ids.isEmpty ? GenerationComponents()
                    : GenerationComponents(logitProcessorFactory: { TokenMask(ids: ids) })
                func start<Iterator: TokenIteratorProtocol>(_ iterator: Iterator)
                    -> (AsyncStream<Generation>, Task<Void, Never>) {
                    generateTask(promptTokenCount: tokens.count, modelConfiguration: context.configuration,
                                 tokenizer: context.tokenizer, iterator: iterator)
                }
                let (stream, producer) = if let draft {
                    start(try MTPSpeculativeTokenIterator(input: input, mainModel: context.model,
                        drafter: draft.model, mainCache: cache, parameters: parameters, blockSize: MLXLoader.draftBlock,
                        components: components))
                } else {
                    start(try TokenIterator(input: input, model: context.model, cache: cache,
                                            parameters: parameters, components: components))
                }
                return try await LocalGeneration.collect(stream, producer: producer)
            }
        }
    }

    // Rules tokens out of the answer by a bias no logit can overcome. The
    // bias spans the vocabulary, so it is built once per generation; the
    // speculative iterator's copies share it, as they share the generation.
    struct TokenMask: LogitProcessor {
        let ids: [Int]
        private let bias = TokenMaskBias()

        init(ids: [Int]) { self.ids = ids }

        mutating func prompt(_ prompt: MLXArray) {}

        func process(logits: MLXArray) -> MLXArray {
            if let values = bias.values, values.dim(-1) == logits.dim(-1), values.dtype == logits.dtype {
                return logits + values
            }
            var values = [Float](repeating: 0, count: logits.dim(-1))
            for id in ids where id < values.count { values[id] = -1e9 }
            let built = MLXArray(values).asType(logits.dtype)
            bias.values = built
            return logits + built
        }

        mutating func didSample(token: MLXArray) {}
    }

    // The instructions open every prompt, about 360 of TranslateGemma's 380
    // tokens. Their cache is computed once per pair or preset and copied into
    // each run, which took 1.7-3.7 s off the first token with identical output
    // (docs/local-translation.md). Each costs 141 MB on TranslateGemma, so only
    // the latest three are kept. Used only inside `ModelContainer.perform`,
    // which runs one generation at a time.
    final class PromptHeads: @unchecked Sendable {
        private var entries: [(head: [Int], cache: [KVCache])] = []

        // A copy of the cache after `head` and the tokens still to process, or
        // no cache when the prompt's tokens do not begin with the head's.
        func split(_ tokens: [Int], head: [Int], model: any LanguageModel,
                   parameters: GenerateParameters) throws -> ([KVCache]?, [Int]) {
            guard !head.isEmpty, tokens.count > head.count, tokens.starts(with: head) else { return (nil, tokens) }
            let cache = try prepare(head, model: model, parameters: parameters)
            return (cache.map { $0.copy() }, Array(tokens[head.count...]))
        }

        // Return the resident cache; only a generation needs its own copies.
        func prepare(_ head: [Int], model: any LanguageModel,
                     parameters: GenerateParameters) throws -> [KVCache] {
            let cache: [KVCache]
            if let index = entries.firstIndex(where: { $0.head == head }) {
                cache = entries.remove(at: index).cache
            } else {
                cache = try model.newCache(parameters: parameters)
                // Chunked like the SDK's prefill; the logits are never evaluated.
                for start in stride(from: 0, to: head.count, by: 512) {
                    _ = model(MLXArray(Array(head[start..<min(start + 512, head.count)]))[.newAxis, .ellipsis],
                              cache: cache)
                    eval(cache)
                }
            }
            entries.append((head, cache))
            if entries.count > LocalEngine.promptHeadLimit { entries.removeFirst() }
            return cache
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

// One generation's mask bias, shared by the copies of its `TokenMask`.
final class TokenMaskBias {
    var values: MLXArray?
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
