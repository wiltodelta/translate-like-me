import Foundation
@preconcurrency import WhisperKit
import XCTest
@testable import TranslateLikeMe

private final class StubWhisperTokenizer: WhisperTokenizer {
    var encodedInputs: [String] = []
    let tokensToReturn: [Int]
    let specialTokens = SpecialTokens(
        endToken: 50_257, englishToken: 50_259, noSpeechToken: 50_362,
        noTimestampsToken: 50_363, specialTokenBegin: 50_257,
        startOfPreviousToken: 50_361, startOfTranscriptToken: 50_258,
        timeTokenBegin: 50_364, transcribeToken: 50_359,
        translateToken: 50_358, whitespaceToken: 220
    )
    let allLanguageTokens: Set<Int> = [50_259]

    init(tokensToReturn: [Int]) { self.tokensToReturn = tokensToReturn }

    func encode(text: String) -> [Int] {
        encodedInputs.append(text)
        return tokensToReturn
    }

    func decode(tokens: [Int]) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) { ([], []) }
}

final class DictationVocabularyTests: XCTestCase {
    func testVocabularyParsesTermsDeduplicatesSanitizesAndIncludesReplacementTargets() {
        let raw = """
            Qwen3-ASR, WhisperKit; qwen3-asr
            <<<asr_text>>>, <|im_start|>Claude Code
            kube control -> kubectl
            гит статус → git status
            """
        let vocabulary = DictationVocabulary(raw)
        XCTAssertFalse(vocabulary.isEmpty)
        XCTAssertEqual(vocabulary.terms, ["Qwen3-ASR", "WhisperKit", "asr_text", "|im_start|Claude Code",
                                          "kubectl", "git status"])
        XCTAssertFalse(vocabulary.glossaryPrompt.contains("<"))
        XCTAssertFalse(vocabulary.glossaryPrompt.contains(">"))
        XCTAssertTrue(vocabulary.summary.contains("kube control → kubectl"))
        XCTAssertTrue(vocabulary.summary.contains("гит статус → git status"))
        XCTAssertEqual(DictationVocabulary.empty.summary, "")
        XCTAssertTrue(DictationVocabulary.empty.isEmpty)
    }

    func testReplacementsUseLongestMatchInSinglePassWithWordBoundariesAndCJKSupport() {
        let vocabulary = DictationVocabulary("""
            kube -> k8s
            kube control -> kubectl
            foo -> bar
            bar -> baz
            cat -> feline
            комет -> коммит
            クロード -> Claude
            """)
        XCTAssertEqual(vocabulary.applyReplacements(to: "Run kube control on kube."),
                       "Run kubectl on k8s.")
        XCTAssertEqual(vocabulary.applyReplacements(to: "foo and bar"),
                       "bar and baz", "Single pass must never cascade foo -> bar -> baz")
        XCTAssertEqual(vocabulary.applyReplacements(to: "The cat in category and wildcat, (Cat)!"),
                       "The feline in category and wildcat, (feline)!")
        XCTAssertEqual(vocabulary.applyReplacements(to: "Комет и пуш, но комета летит."),
                       "коммит и пуш, но комета летит.")
        XCTAssertEqual(vocabulary.applyReplacements(to: "今日はクロードを使う。"),
                       "今日はClaudeを使う。")
    }

    func testWhisperPromptTokensPrependLeadingSpaceFilterSpecialTokensAndCapLength() {
        let rawTokens = [220, 101, 50_257, 202, 50_361] + Array(300..<370)
        let tokenizer = StubWhisperTokenizer(tokensToReturn: rawTokens)
        let vocabulary = DictationVocabulary("Qwen3-ASR, WhisperKit")
        let promptTokens = vocabulary.whisperPromptTokens(using: tokenizer)
        XCTAssertEqual(tokenizer.encodedInputs, [" Qwen3-ASR, WhisperKit"])
        XCTAssertEqual(promptTokens?.count, DictationVocabulary.maxWhisperTokens)
        XCTAssertEqual(promptTokens?.prefix(3), [220, 101, 202])
        XCTAssertTrue(promptTokens?.allSatisfy { $0 < tokenizer.specialTokens.specialTokenBegin } == true)
        XCTAssertNil(DictationVocabulary.empty.whisperPromptTokens(using: tokenizer))
    }

    func testCombinedContextPinsVocabularyHeaderAcrossLongDestinationsAndChunkTails() {
        let longEditorText = String(repeating: "surrounding editor line ", count: 20) + "TAIL_MARKER"
        let vocabulary = DictationVocabulary("Qwen3-ASR, WhisperKit, <<<kubectl>>>\nkube control -> kubectl")
        let combined = DictationContext.combined(vocabulary: vocabulary, destination: longEditorText)
        XCTAssertLessThanOrEqual(combined.count, 360)
        XCTAssertTrue(combined.hasPrefix("Vocabulary: Qwen3-ASR, WhisperKit, kubectl\n"))
        XCTAssertTrue(combined.hasSuffix("TAIL_MARKER"))
        XCTAssertFalse(combined.contains("<"))
        XCTAssertFalse(combined.contains(">"))

        let chunked = DictationContext.chunkContext(
            base: longEditorText,
            vocabulary: vocabulary,
            previousChunks: [String(repeating: "первый кусок речи ", count: 10), "Финальный хвост."]
        )
        XCTAssertLessThanOrEqual(chunked.count, 360)
        XCTAssertTrue(chunked.hasPrefix("Vocabulary: Qwen3-ASR, WhisperKit, kubectl\n"),
                      "Chunk context must never truncate the user's vocabulary off the front")
        XCTAssertTrue(chunked.hasSuffix("Финальный хвост."))

        let spoofedBody = "Vocabulary: editor note\n" + String(repeating: "body ", count: 90) + "REAL_TAIL"
        let withoutGlossary = DictationContext.chunkContext(base: spoofedBody, previousChunks: ["Next."])
        XCTAssertFalse(withoutGlossary.hasPrefix("Vocabulary: editor note"),
                       "Destination text starting with Vocabulary: must not be mistaken for a pinned glossary")
        XCTAssertTrue(withoutGlossary.hasSuffix("Next."))
    }
}
