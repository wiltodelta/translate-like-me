import CryptoKit
import Foundation
@preconcurrency import MLX
@preconcurrency import MLXAudioSTT
@preconcurrency import MLXNN
@preconcurrency import WhisperKit
import XCTest
@testable import TranslateLikeMe

final class DictationQwenTests: XCTestCase {
    func testGreedyDecoderStopsAtAnEndTokenWithoutConsumingMoreSteps() throws {
        var calls = 0
        let tokens = try DictationQwenDecoding.decode(endTokens: [9], maximumTokens: 4) { previous in
            calls += 1
            XCTAssertEqual(previous, calls == 1 ? nil : calls - 1)
            return calls == 3 ? 9 : calls
        }
        XCTAssertEqual(tokens, [1, 2])
        XCTAssertEqual(calls, 3)
    }

    func testDecoderLimitRejectsPartialText() {
        var calls = 0
        XCTAssertThrowsError(try DictationQwenDecoding.decode(endTokens: [9], maximumTokens: 2) { _ in
            calls += 1
            return calls
        }) { XCTAssertEqual($0 as? DictationQwenDecoding.Failure, .tokenLimit(2)) }
        XCTAssertEqual(calls, 2)
    }

    func testRepetitionBackstopRejectsPartialText() {
        var calls = 0
        XCTAssertThrowsError(try DictationQwenDecoding.decode(endTokens: [9]) { _ in
            calls += 1
            return 1
        }) { XCTAssertEqual($0 as? DictationQwenDecoding.Failure, .repetition(24)) }
        XCTAssertEqual(calls, 24)
    }

    func testCancellationStopsBeforeTheNextPrediction() async throws {
        let task = Task { @Sendable in
            var calls = 0
            do {
                _ = try DictationQwenDecoding.decode(endTokens: [9]) { _ in
                    calls += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                    return 1
                }
            } catch is CancellationError { return calls }
            return -1
        }
        let calls = try await task.value
        XCTAssertEqual(calls, 1)
    }

    func testLanguagePrefixRemovalPreservesRussianAndLiteralMarkersInSpeech() {
        XCTAssertEqual(DictationQwenDecoding.transcript(" language Russian<asr_text>Привет, MLX. "), "Привет, MLX.")
        XCTAssertEqual(DictationQwenDecoding.transcript("language English<asr_text>Say <asr_text> literally."),
                       "Say <asr_text> literally.")
        XCTAssertEqual(DictationQwenDecoding.transcript("  Привет, мир.  "), "Привет, мир.")
    }

    func testVerifiedQwenSnapshotRejectsCorruptionAndMissingWeightsOffline() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tlm-qwen-assets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = DictationQwen.source
        let root = ModelDownloader(config: source).localRepoLocation(downloadBase: base)
        let bytes = Data("fixture".utf8)
        let hash = Insecure.SHA1.hash(data: Data("blob \(bytes.count)\0".utf8) + bytes)
            .map { String(format: "%02x", $0) }.joined()
        for name in DictationQwen.files {
            let file = root.appendingPathComponent(name)
            let metadata = root.appendingPathComponent(".cache/huggingface/download/\(name).metadata")
            try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try bytes.write(to: file)
            try "\(source.revision)\n\(hash)\n1\n".write(to: metadata, atomically: true, encoding: .utf8)
        }
        let engine = DictationEngine(directory: base)
        let verified = try await engine.prepareModels(model: .qwen3ASR, in: base, download: false) { _ in }
        XCTAssertEqual(verified, root)
        let weights = root.appendingPathComponent("model.safetensors")
        try Data("corrupt".utf8).write(to: weights)
        XCTAssertEqual(try Data(contentsOf: weights), Data("corrupt".utf8))
        do {
            _ = try await engine.prepareModels(model: .qwen3ASR, in: base, download: false) { _ in }
            XCTFail("Same-size corruption must fail even with matching Hub metadata")
        } catch DictationError.notReady {}
        try FileManager.default.removeItem(at: weights)
        do {
            _ = try await engine.prepareModels(model: .qwen3ASR, in: base, download: false) { _ in }
            XCTFail("A partial snapshot must fail offline")
        } catch DictationError.notReady {}
    }

    func testCachedAudioFeaturesMatchFullModelForwardOnSyntheticQwenGraph() throws {
        try DictationQwenTestSupport.configure()
        let config = Qwen3ASRConfig(
            audioConfig: Qwen3AudioEncoderConfig(
                numMelBins: 16, encoderLayers: 1, encoderAttentionHeads: 2,
                encoderFfnDim: 32, dModel: 16, maxSourcePositions: 64,
                nWindow: 8, outputDim: 16, nWindowInfer: 16,
                convChunksize: 16, downsampleHiddenSize: 8
            ),
            textConfig: Qwen3TextConfig(
                vocabSize: 64, hiddenSize: 16, intermediateSize: 32,
                numHiddenLayers: 1, numAttentionHeads: 2, numKeyValueHeads: 2, headDim: 8
            ),
            audioTokenId: 60, audioStartTokenId: 58, audioEndTokenId: 59,
            supportLanguages: ["English", "Russian"]
        )
        let model = Qwen3ASRModel(config)
        let embed = try XCTUnwrap(DictationQwen.textEmbedding(of: model))
        let samples = MLXArray((0..<16_000).map { Float(sin(Double($0) * 0.05) * 0.2) })
        let raw = model.preprocessAudio(samples)
        let prompt = MLXArray([Int32(1), 58] + Array(repeating: Int32(60), count: raw.2) + [59, 2])
            .expandedDimensions(axis: 0)

        let baselineLogits = model(inputIds: prompt, inputFeatures: raw.0,
                                   featureAttentionMask: raw.1, cache: model.makeCache())[0, -1, 0...]
        let cachedFeatures = model.getAudioFeatures(raw.0, featureAttentionMask: raw.1)
        let merged = DictationQwen.mergedAudioEmbeddings(model, prompt: prompt,
                                                         audioFeatures: cachedFeatures, embed: embed)
        let cachedLogits = model(inputIds: prompt, inputEmbeddings: merged,
                                 cache: model.makeCache())[0, -1, 0...]
        eval(baselineLogits, cachedLogits)
        let baselineValues = baselineLogits.asArray(Float.self)
        let cachedValues = cachedLogits.asArray(Float.self)
        XCTAssertEqual(baselineValues.count, 64)
        for (lhs, rhs) in zip(baselineValues, cachedValues) {
            XCTAssertEqual(lhs, rhs, accuracy: 1e-4)
        }
    }

    func testShortCandidateRescoreSwitchesUncertainPrimaryWithoutFlippingCognatesOrNoise() {
        typealias Candidate = DictationQwenDecoding.ShortCandidate
        XCTAssertFalse(DictationQwenDecoding.needsChallengerRescore(
            primary: Candidate(language: "Russian", text: "Привет.", confidence: -0.02)
        ))
        XCTAssertTrue(DictationQwenDecoding.needsChallengerRescore(
            primary: Candidate(language: "Russian", text: "...", confidence: -0.01)
        ))
        let uncertainPrimary = Candidate(language: "English", text: "Yeah.", confidence: -0.56)
        let russianChallenger = Candidate(language: "Russian", text: "Да.", confidence: -0.16)
        XCTAssertTrue(DictationQwenDecoding.needsChallengerRescore(primary: uncertainPrimary))
        XCTAssertEqual(
            DictationQwenDecoding.selectShortCandidate(primary: uncertainPrimary, challenger: russianChallenger),
            russianChallenger
        )
        for (ruLoan, enLoan) in [("Коммит.", "Commit."), ("Пуш", "Push."), ("Ладно.", "Ladna."), ("Стоп.", "Stop.")] {
            let primary = Candidate(language: "Russian", text: ruLoan, confidence: -0.50)
            let challenger = Candidate(language: "English", text: enLoan, confidence: -0.03)
            XCTAssertTrue(DictationQwenDecoding.arePhoneticCognates(ruLoan, enLoan), "\(ruLoan) vs \(enLoan)")
            XCTAssertEqual(
                DictationQwenDecoding.selectShortCandidate(
                    primary: primary, challenger: challenger, context: "Terminal\ngit status && git diff"
                ),
                primary
            )
        }
        let spoken = Candidate(language: "Russian", text: "Да.", confidence: -0.70)
        let punctuationOnly = Candidate(language: "English", text: "...", confidence: -0.01)
        XCTAssertEqual(DictationQwenDecoding.selectShortCandidate(primary: spoken, challenger: punctuationOnly), spoken)
        let emptyPrimary = Candidate(language: "English", text: "", confidence: -99)
        let rescued = Candidate(language: "Russian", text: "Нет.", confidence: -0.40)
        let weakChallenger = Candidate(language: "Russian", text: "Нет.", confidence: -1.20)
        XCTAssertEqual(DictationQwenDecoding.selectShortCandidate(primary: emptyPrimary, challenger: rescued), rescued)
        XCTAssertEqual(
            DictationQwenDecoding.selectShortCandidate(primary: emptyPrimary, challenger: weakChallenger),
            emptyPrimary
        )
    }

    func testShortCandidateContextScriptTieBreakerIgnoresWindowHeaderAndVocabularyLine() {
        typealias Candidate = DictationQwenDecoding.ShortCandidate
        let primary = Candidate(language: "English", text: "The.", confidence: -0.30)
        let nearTie = Candidate(language: "Russian", text: "Да.", confidence: -0.27)
        XCTAssertEqual(DictationQwenDecoding.selectShortCandidate(primary: primary, challenger: nearTie), primary)
        XCTAssertEqual(
            DictationQwenDecoding.selectShortCandidate(
                primary: primary, challenger: nearTie, context: "Vocabulary: Да, Привет\nСообщения — рабочий чат"
            ),
            primary
        )
        XCTAssertEqual(
            DictationQwenDecoding.selectShortCandidate(
                primary: primary, challenger: nearTie,
                context: "Сообщения — рабочий чат команды разработки\nok go"
            ),
            primary
        )
        XCTAssertEqual(
            DictationQwenDecoding.selectShortCandidate(
                primary: primary, challenger: nearTie, context: "Slack\nПривет, проверь сборку"
            ),
            nearTie
        )
        let slightChallengerLead = Candidate(language: "Russian", text: "Да.", confidence: -0.23)
        XCTAssertEqual(
            DictationQwenDecoding.selectShortCandidate(
                primary: primary, challenger: slightChallengerLead, context: "Slack\nPlease check the build"
            ),
            primary
        )
    }

    func testCaseVariantStartTokensUnifyCapitalizedAndLowercaseWordInitialPaths() {
        let table: [String: [Int]] = [
            "Да.": [24_110, 999],
            "да.": [39_490, 13]
        ]
        let tokens = DictationQwenDecoding.caseVariantStartTokens(for: "Да.", greedyFirstToken: 24_110) { text in
            table[text] ?? []
        }
        XCTAssertEqual(tokens, [24_110, 39_490])
        XCTAssertEqual(
            DictationQwenDecoding.caseVariantStartTokens(for: "   ", greedyFirstToken: 7) { _ in [99] },
            [7]
        )
    }
}
