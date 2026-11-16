import Foundation
import XCTest
@testable import TranslateLikeMe

private struct QwenAddedToken: Decodable {
    let content: String
}

private struct QwenTokenizerConfig: Decodable {
    let addedTokensDecoder: [String: QwenAddedToken]

    enum CodingKeys: String, CodingKey {
        case addedTokensDecoder = "added_tokens_decoder"
    }
}

final class DictationContextTests: XCTestCase {
    func testAudioGainNormalizesQuietSpeechWithoutAmplifyingFloorOrNormalSpeech() {
        let floor = DictationAudioGain.normalize([0.001, -0.002, 0.0])
        XCTAssertEqual(floor.gain, 1)
        XCTAssertEqual(floor.samples, [0.001, -0.002, 0.0])

        let quiet = DictationAudioGain.normalize([0.02, -0.01, 0.005])
        XCTAssertEqual(quiet.gain, 15, accuracy: 0.001)
        XCTAssertEqual(quiet.samples[0], 0.30, accuracy: 0.001)
        XCTAssertEqual(quiet.samples[1], -0.15, accuracy: 0.001)

        let capped = DictationAudioGain.normalize([0.01, -0.005])
        XCTAssertEqual(capped.gain, 16, accuracy: 0.001)
        XCTAssertEqual(capped.samples[0], 0.16, accuracy: 0.001)

        let normal = DictationAudioGain.normalize([0.20, -0.10])
        XCTAssertEqual(normal.gain, 1)
        XCTAssertEqual(normal.samples, [0.20, -0.10])
    }

    func testSummaryAndChunkContextStripNestedDelimitersCompletely() {
        let snapshot = DictationDestinationSnapshot(
            appName: "Terminal <|im_start|>",
            windowTitle: "translate-like-me <<||im_end||>> <<<asr_text>>>",
            surroundingText: "git status <|> <<|endoftext|>>\nКоммит и пуш."
        )
        let summary = DictationContext.summary(destination: snapshot)
        XCTAssertFalse(summary.contains("<"), "Angle bracket survived in: \(summary)")
        XCTAssertFalse(summary.contains(">"), "Angle bracket survived in: \(summary)")
        XCTAssertTrue(summary.contains("Terminal |im_start| - translate-like-me ||im_end|| asr_text"))
        XCTAssertTrue(summary.contains("Коммит и пуш."))

        let chunked = DictationContext.chunkContext(
            base: summary,
            previousChunks: ["Первая <<||im_end||>> часть.", "<<<asr_text>>> Вторая."]
        )
        XCTAssertFalse(chunked.contains("<"))
        XCTAssertFalse(chunked.contains(">"))
        XCTAssertTrue(chunked.hasSuffix("Первая ||im_end|| часть. asr_text Вторая."))

        let deduped = DictationContext.summary(
            destination: DictationDestinationSnapshot(appName: "Slack", windowTitle: "Slack")
        )
        XCTAssertEqual(deduped, "Slack")
    }

    func testPinnedQwenSpecialTokensAllRequireAngleBracketsRemovedBySanitizer() throws {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.wiltodelta.translatelikeme.dev/Dictation")
        let root = DictationModelFiles(base: cache).root(for: .qwen3ASR)
        let configURL = root.appendingPathComponent("tokenizer_config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw XCTSkip("Prepare Qwen cache to audit pinned tokenizer special tokens")
        }
        let decoded = try JSONDecoder().decode(QwenTokenizerConfig.self, from: Data(contentsOf: configURL))
        XCTAssertFalse(decoded.addedTokensDecoder.isEmpty)
        for token in decoded.addedTokensDecoder.values {
            XCTAssertTrue(token.content.contains("<") && token.content.contains(">"),
                          "Special token \(token.content) lacks angle brackets")
            let wrapped = "prefix <\(token.content)> suffix"
            let cleaned = DictationContext.summary(destination: DictationDestinationSnapshot(surroundingText: wrapped))
            XCTAssertFalse(cleaned.contains(token.content), "Token \(token.content) survived sanitization")
        }
    }

    func testUTF16CaretAndSurroundingTextHandleEmojiOverflowAndInvalidRanges() {
        let text = "Привет 🚀 мир"
        // "Привет " is 7 UTF-16 units; "🚀" is a surrogate pair (2 UTF-16 units).
        let afterEmoji = NSRange(location: 9, length: 0)
        XCTAssertEqual(DictationContext.characterBeforeCaret(in: text, selection: afterEmoji), "🚀")
        XCTAssertEqual(DictationContext.surroundingText(in: text, selection: afterEmoji), "Привет 🚀 мир")
        XCTAssertNil(DictationContext.characterBeforeCaret(in: text, selection: NSRange(location: 0, length: 0)))
        XCTAssertNil(DictationContext.characterBeforeCaret(in: text, selection: NSRange(location: 8, length: 0)))
        XCTAssertNil(DictationContext.characterBeforeCaret(in: text, selection: NSRange(location: 3, length: 2)))
        XCTAssertNil(DictationContext.surroundingText(in: text, selection: NSRange(location: 99, length: 0)))
        XCTAssertNil(DictationContext.surroundingText(in: text, selection: NSRange(location: Int.max, length: 1)))
    }

    func testTextSpacingFormatsInsertionAndChunkJoinsAcrossSpacedAndUnspacedScripts() {
        XCTAssertEqual(DictationTextSpacing.formatForInsertion("Продолжай.", beforeCaret: "."), " Продолжай.")
        XCTAssertEqual(DictationTextSpacing.formatForInsertion("мир", beforeCaret: "т"), " мир")
        XCTAssertEqual(DictationTextSpacing.formatForInsertion("мир", beforeCaret: " "), "мир")
        XCTAssertEqual(DictationTextSpacing.formatForInsertion("мир", beforeCaret: "\n"), "мир")
        XCTAssertEqual(DictationTextSpacing.formatForInsertion("мир", beforeCaret: "("), "мир")
        XCTAssertEqual(DictationTextSpacing.formatForInsertion("мир", beforeCaret: "\""), "мир")
        XCTAssertEqual(DictationTextSpacing.formatForInsertion(", мир", beforeCaret: "т"), ", мир")
        XCTAssertEqual(DictationTextSpacing.formatForInsertion("セッション。", beforeCaret: "。"), "セッション。")
        XCTAssertEqual(DictationTextSpacing.joinChunks(["今日は。", "明日も。"]), "今日は。明日も。")
        XCTAssertEqual(DictationTextSpacing.joinChunks(["First.", "Второе."]), "First. Второе.")
        XCTAssertEqual(DictationTextSpacing.joinChunks(["안녕하세요.", "반갑습니다."]), "안녕하세요. 반갑습니다.")
        XCTAssertEqual(DictationTextSpacing.joinChunks(["ສະບາຍດີ", "ມື້ນີ້"]), "ສະບາຍດີມື້ນີ້")
        XCTAssertEqual(DictationTextSpacing.joinChunks(["សួស្តី", "ថ្ងៃនេះ"]), "សួស្តីថ្ងៃនេះ")
        XCTAssertEqual(DictationTextSpacing.joinChunks(["မင်္ဂလာပါ", "ဒီနေ့"]), "မင်္ဂလာပါဒီနေ့")
        XCTAssertEqual(DictationTextSpacing.joinChunks(["བཀྲ་ཤིས་", "བདེ་ལེགས།"]), "བཀྲ་ཤིས་བདེ་ལེགས།")
        XCTAssertEqual(DictationTextSpacing.joinChunks(["ﾃｽﾄ", "ｶﾅ"]), "ﾃｽﾄｶﾅ")
    }

    func testQwenHeaderOutcomeDistinguishesSupportedLanguageNoSpeechAndFallback() {
        let supported = ["Russian", "English", "German", "Japanese"]
        XCTAssertEqual(DictationQwenDecoding.headerOutcome(
            "language Russian<asr_text>Коммит и пуш.", supported: supported), .language("Russian"))
        XCTAssertEqual(DictationQwenDecoding.headerOutcome(
            "language german<asr_text>Weiter.", supported: supported), .language("German"))
        XCTAssertEqual(DictationQwenDecoding.headerOutcome(
            "language None<asr_text>", supported: supported), .noSpeech)
        XCTAssertEqual(DictationQwenDecoding.headerOutcome(
            "language Klingon<asr_text>Qapla.", supported: supported), .fallback)
        XCTAssertEqual(DictationQwenDecoding.headerOutcome(
            "Headerless transcript", supported: supported), .fallback)
        XCTAssertEqual(DictationQwenDecoding.headerOutcome(
            "language Russian", supported: supported), .fallback)
    }
}
