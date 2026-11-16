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
                    context: String = "", vocabulary: DictationVocabulary = .empty,
                    isShortUtterance: Bool = false) throws -> String {
        guard let model, let tokenizer = model.tokenizer else { throw DictationError.notReady }
        let endTokens = Set(["<|im_end|>", "<|endoftext|>"].compactMap { tokenizer.convertTokenToId($0) })
        guard endTokens.count == 2 else { throw DictationError.notReady }
        defer {
            Stream.gpu.synchronize()
            Memory.clearCache()
        }
        let names = preference.resolvedNames(supported: model.config.supportLanguages).sorted()
        let chunks = splitAudioIntoChunks(MLXArray(samples), sampleRate: 16_000, chunkDuration: 30)
        let shortMode = isShortUtterance && chunks.count == 1
        let startTokens = tokenizer.encode(text: "language")
        let encodedPreferred = names.map { (name: $0, tokens: tokenizer.encode(text: "language " + $0)) }
        let weight = shortMode
            ? DictationLanguagePreference.shortQwenLogWeight
            : DictationLanguagePreference.logWeight
        let languagePrefix = DictationLanguagePrefix(
            start: startTokens,
            preferred: encodedPreferred.map(\.tokens),
            noSpeech: tokenizer.encode(text: "language None"),
            logWeight: weight
        )
        var preferredFirstTokens: [String: Int] = [:]
        if shortMode, encodedPreferred.count >= 2 {
            for entry in encodedPreferred where entry.tokens.starts(with: startTokens) &&
                entry.tokens.count > startTokens.count {
                preferredFirstTokens[entry.name] = entry.tokens[startTokens.count]
            }
        }
        let decoder = ChunkDecoder(model: model, embed: Self.textEmbedding(of: model),
                                   prefix: languagePrefix, preferredFirstTokens: preferredFirstTokens,
                                   endTokens: endTokens)
        var transcripts: [String] = []
        // Use the SDK's low-energy boundaries to bound prefill memory on long
        // recordings. Each chunk has a fresh decoder cache and automatic language.
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

    fileprivate struct PreparedAudio {
        let features: MLXArray
        let mask: MLXArray
        let cached: (embeddings: MLXArray, embed: Embedding)?
        let count: Int
    }

    fileprivate struct DecoderSession {
        let prefill: (MLXArray) -> MLXArray
        let step: (MLXArray) -> MLXArray
        let rewind: (Int) -> Void
    }

    private struct ChunkDecoder {
        let model: Qwen3ASRModel
        let embed: Embedding?
        let prefix: DictationLanguagePrefix
        let preferredFirstTokens: [String: Int]
        let endTokens: Set<Int>

        // Contextual prompts bias Qwen's language token toward the prompt's script if
        // `language` is unset. Detect the spoken language without context first, then
        // decode the transcript with that language locked and destination context set,
        // sharing the single audioTower encoding across both passes.
        func decode(_ audio: MLXArray, context: String) throws -> String {
            guard let tokenizer = model.tokenizer else { throw DictationError.notReady }
            let raw = model.preprocessAudio(audio)
            let canRescoreShort = preferredFirstTokens.count >= 2 && embed != nil
            let cached: (embeddings: MLXArray, embed: Embedding)?
            if !context.isEmpty || canRescoreShort, let embed {
                let encoded = model.getAudioFeatures(raw.0, featureAttentionMask: raw.1)
                asyncEval(encoded)
                cached = (encoded, embed)
            } else {
                cached = nil
            }
            let prepared = PreparedAudio(features: raw.0, mask: raw.1, cached: cached, count: raw.2)
            if canRescoreShort {
                return try ShortChunkRescorer(model: model, audio: prepared, prefix: prefix,
                                              preferredFirstTokens: preferredFirstTokens, endTokens: endTokens)
                    .decode(context: context)
            }
            var prompt = model.buildPrompt(numAudioTokens: prepared.count)
            var activePrefix = prefix
            if !context.isEmpty {
                let session = DictationQwen.makeSession(model, audio: prepared)
                let scan = try DictationQwen.scanHeader(model, session: session, prompt: prompt,
                                                        prefix: prefix, endTokens: endTokens)
                switch scan.outcome {
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

    fileprivate static func scanHeader(
        _ model: Qwen3ASRModel, session: DecoderSession, prompt: MLXArray,
        prefix: DictationLanguagePrefix, firstTokens: [String: Int] = [:], endTokens: Set<Int>
    ) throws -> (outcome: DictationQwenDecoding.HeaderOutcome, languageLogits: [String: Float]) {
        guard let tokenizer = model.tokenizer else { throw DictationError.notReady }
        let asrTextToken = tokenizer.convertTokenToId("<asr_text>")
        let ordered = firstTokens.sorted { $0.key < $1.key }
        var header: [Int] = []
        var languageLogits: [String: Float] = [:]
        for _ in 0..<12 {
            try Task.checkCancellation()
            let logits = stepInput(header.last).map(session.step) ?? session.prefill(prompt)
            let next = Self.nextToken(logits: logits, generated: header, prefix: prefix)
            if header == prefix.start, !ordered.isEmpty {
                let picks = ordered.map { logits[0, -1, $0.value].asType(.float32) }
                eval([next] + picks)
                for (entry, pick) in zip(ordered, picks) {
                    languageLogits[entry.key] = pick.item(Float.self)
                }
            }
            let value = next.item(Int.self)
            if endTokens.contains(value) { break }
            header.append(value)
            if let asrTextToken, value != asrTextToken { continue }
            let decoded = tokenizer.decode(tokens: header)
            if decoded.contains("<asr_text>") {
                let outcome = DictationQwenDecoding.headerOutcome(decoded, supported: model.config.supportLanguages)
                return (outcome, languageLogits)
            }
        }
        return (.fallback, languageLogits)
    }

    // Greedy decoding of one chunk with a fresh decoder cache.
    fileprivate static func decodePrompt(_ model: Qwen3ASRModel, audio: PreparedAudio,
                                         prompt: MLXArray, prefix: DictationLanguagePrefix,
                                         endTokens: Set<Int>) throws -> [Int] {
        let session = makeSession(model, audio: audio)
        let reach = prefix.reach
        var generated: [Int] = []
        var ahead: MLXArray?
        return try DictationQwenDecoding.decode(endTokens: endTokens) { previous in
            let token: MLXArray
            if let ahead {
                token = ahead
            } else {
                let logits = stepInput(previous).map(session.step) ?? session.prefill(prompt)
                token = Self.nextToken(logits: logits, generated: generated, prefix: prefix)
            }
            // Once no language preference can apply, queue the following
            // step on the GPU before reading this token: about 10% faster
            // on phrases of 30+ tokens, identical tokens (docs/dictation-latency.md).
            ahead = nil
            if generated.count + 1 >= reach {
                let following = session.step(token.reshaped(1, 1).asType(.int32))[0, -1, 0...]
                    .argMax(axis: -1)
                asyncEval(following)
                ahead = following
            }
            let value = token.item(Int.self)
            generated.append(value)
            return value
        }
    }

    fileprivate static func makeSession(_ model: Qwen3ASRModel, audio: PreparedAudio) -> DecoderSession {
        let cache = model.makeCache()
        return DecoderSession(
            prefill: { prompt in
                if let cached = audio.cached {
                    let merged = mergedAudioEmbeddings(model, prompt: prompt, audioFeatures: cached.embeddings,
                                                       embed: cached.embed)
                    return model(inputIds: prompt, inputEmbeddings: merged, cache: cache)
                }
                return model(inputIds: prompt, inputFeatures: audio.features,
                             featureAttentionMask: audio.mask, cache: cache)
            },
            step: { inputIds in model(inputIds: inputIds, cache: cache) },
            rewind: { target in
                for layer in cache where layer.offset > target {
                    _ = layer.trim(layer.offset - target)
                }
            }
        )
    }

    fileprivate static func stepInput(_ token: Int) -> MLXArray {
        MLXArray([Int32(token)]).expandedDimensions(axis: 0)
    }

    fileprivate static func stepInput(_ previous: Int?) -> MLXArray? {
        previous.map(stepInput)
    }

    // Lazy, so the caller decides when the GPU result is read.
    static func nextToken(logits: MLXArray, generated: [Int], prefix: DictationLanguagePrefix) -> MLXArray {
        let nextLogits = logits[0, -1, 0...]
        for token in prefix.nextTokens(after: generated) {
            nextLogits[token] += MLXArray(prefix.logWeight)
        }
        if let noSpeech = prefix.noSpeechToken(after: generated) {
            nextLogits[noSpeech] += MLXArray(prefix.noSpeechBoost)
        }
        return nextLogits.argMax(axis: -1)
    }

    func unload() {
        model = nil
        Stream.gpu.synchronize()
        Memory.clearCache()
    }
}

private struct ShortChunkRescorer {
    let model: Qwen3ASRModel
    let audio: DictationQwen.PreparedAudio
    let prefix: DictationLanguagePrefix
    let preferredFirstTokens: [String: Int]
    let endTokens: Set<Int>

    func decode(context: String) throws -> String {
        guard let tokenizer = model.tokenizer else { throw DictationError.notReady }
        let uncondPrompt = model.buildPrompt(numAudioTokens: audio.count)
        var uncondSession: DictationQwen.DecoderSession? = DictationQwen.makeSession(model, audio: audio)
        let scan = try DictationQwen.scanHeader(
            model, session: uncondSession!, prompt: uncondPrompt,
            prefix: prefix, firstTokens: preferredFirstTokens, endTokens: endTokens
        )
        switch scan.outcome {
        case .noSpeech:
            return ""
        case .fallback:
            uncondSession = nil
            let tokens = try DictationQwen.decodePrompt(model, audio: audio, prompt: uncondPrompt,
                                                        prefix: prefix, endTokens: endTokens)
            return DictationQwenDecoding.transcript(tokenizer.decode(tokens: tokens))
        case .language(let detected):
            return try decodeDetected(detected, context: context, languageLogits: scan.languageLogits,
                                      uncondSession: &uncondSession, uncondOffset: uncondPrompt.dim(1))
        }
    }

    private func decodeDetected(
        _ detected: String, context: String, languageLogits: [String: Float],
        uncondSession: inout DictationQwen.DecoderSession?, uncondOffset: Int
    ) throws -> String {
        guard let tokenizer = model.tokenizer else { throw DictationError.notReady }
        let challenger = runnerUpLanguage(after: detected, logits: languageLogits)
        let session: DictationQwen.DecoderSession
        let baseOffset: Int
        let fusedPrompt: MLXArray?
        if context.isEmpty, let existing = uncondSession {
            session = existing
            baseOffset = uncondOffset
            fusedPrompt = nil
        } else {
            uncondSession = nil
            session = DictationQwen.makeSession(model, audio: audio)
            let fullPrompt = model.buildPrompt(numAudioTokens: audio.count, context: context, language: detected)
            baseOffset = fullPrompt.dim(1) - tokenizer.encode(text: "language \(detected)<asr_text>").count
            fusedPrompt = fullPrompt
        }
        let primary = try decodeCandidate(language: detected, session: session, baseOffset: baseOffset,
                                          fusedPrompt: fusedPrompt, computeConfidence: challenger != nil)
        guard let challenger, DictationQwenDecoding.needsChallengerRescore(primary: primary) else {
            return primary.text
        }
        let alternate = try decodeCandidate(language: challenger, session: session, baseOffset: baseOffset,
                                            fusedPrompt: nil, computeConfidence: true)
        return DictationQwenDecoding.selectShortCandidate(primary: primary, challenger: alternate,
                                                          context: context).text
    }

    private func runnerUpLanguage(after detected: String, logits: [String: Float]) -> String? {
        guard let primaryLogit = logits[detected] else { return nil }
        let runnerUp = preferredFirstTokens.keys.sorted()
            .filter { $0 != detected }
            .compactMap { name in logits[name].map { (name: name, logit: $0) } }
            .max { $0.logit < $1.logit }
        guard let runnerUp,
              primaryLogit - runnerUp.logit <= DictationQwenDecoding.rescoreMarginLimit else { return nil }
        return runnerUp.name
    }

    private func decodeCandidate(language: String, session: DictationQwen.DecoderSession, baseOffset: Int,
                                 fusedPrompt: MLXArray?,
                                 computeConfidence: Bool) throws -> DictationQwenDecoding.ShortCandidate {
        guard let tokenizer = model.tokenizer else { throw DictationError.notReady }
        let rawStep0: MLXArray
        if let fusedPrompt {
            rawStep0 = session.prefill(fusedPrompt)[0, -1, 0...]
        } else {
            session.rewind(baseOffset)
            let headerIds = tokenizer.encode(text: "language \(language)<asr_text>")
            rawStep0 = session.step(MLXArray(headerIds.map(Int32.init)).expandedDimensions(axis: 0))[0, -1, 0...]
        }
        let step0Token = rawStep0.argMax(axis: -1)
        let confidencePair: (logits: MLXArray, lse: MLXArray)?
        if computeConfidence {
            let logits = rawStep0.asType(.float32)
            let lse = MLX.logSumExp(logits, axis: -1)
            eval(logits, step0Token, lse)
            confidencePair = (logits, lse)
        } else {
            eval(step0Token)
            confidencePair = nil
        }
        let firstToken = step0Token.item(Int.self)
        guard !endTokens.contains(firstToken) else { return .init(language: language, text: "", confidence: -99) }
        let tokens = try continueCandidate(after: firstToken, session: session)
        let text = DictationQwenDecoding.transcript(tokenizer.decode(tokens: tokens))
        guard let confidencePair else { return .init(language: language, text: text, confidence: 0) }
        let confidence = wordStartConfidence(text: text, language: language, firstToken: firstToken,
                                             logits: confidencePair.logits, lse: confidencePair.lse.item(Float.self))
        return .init(language: language, text: text, confidence: confidence)
    }

    private func continueCandidate(after firstToken: Int, session: DictationQwen.DecoderSession) throws -> [Int] {
        return try DictationQwenDecoding.decode(endTokens: endTokens, maximumTokens: 64) { previous in
            guard let previous else { return firstToken }
            return session.step(DictationQwen.stepInput(previous))[0, -1, 0...].argMax(axis: -1).item(Int.self)
        }
    }

    private func wordStartConfidence(text: String, language: String, firstToken: Int,
                                     logits: MLXArray, lse: Float) -> Float {
        guard let tokenizer = model.tokenizer else { return -99 }
        let orderedIds = DictationQwenDecoding.caseVariantStartTokens(
            for: text, language: language, greedyFirstToken: firstToken
        ) {
            tokenizer.encode(text: $0)
        }.sorted()
        let picked = logits[MLXArray(orderedIds.map(Int32.init))].asArray(Float.self)
        var probSum: Float = 0
        for value in picked { probSum += exp(value - lse) }
        return probSum > 0 ? log(min(1, probSum)) : -99
    }
}
