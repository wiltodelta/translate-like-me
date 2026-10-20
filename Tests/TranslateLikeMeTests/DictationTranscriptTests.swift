import Foundation
@preconcurrency import WhisperKit
import XCTest
@testable import TranslateLikeMe

final class DictationTranscriptTests: XCTestCase {
    func testRemovesTrailingBlankAudioFromLongDictation() {
        let sentence = String(repeating: "Это длинное предложение, в котором нужно сохранить каждое слово. ", count: 20)
        XCTAssertEqual(transcript([sentence, " [BLANK_AUDIO]\n"]), sentence.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(transcript(["Hello, мир! [BLANK_AUDIO] [BLANK_AUDIO]\n"]), "Hello, мир!")
    }

    func testBlankAudioAloneDoesNotBecomeDictation() {
        XCTAssertEqual(transcript([" [BLANK_AUDIO]\n", "[BLANK_AUDIO]"]), "")
        XCTAssertEqual(transcript([]), "")
        XCTAssertEqual(transcript([" ... "]), "")
    }

    func testPreservesSpeechPunctuationAndOtherBracketedText() {
        for text in ["Привет, world!", "Текст [в скобках]", "Use [BLANK_AUDIO] as an example.",
                     "[BLANK_AUDIO] is a label.", "Keep [BLANK_AUDIO_SUFFIX]"] {
            XCTAssertEqual(transcript([text]), text)
        }
        XCTAssertEqual(transcript(["First sentence.", "Второе предложение."]), "First sentence. Второе предложение.")
    }

    private func transcript(_ chunks: [String]) -> String {
        DictationEngine.transcript(from: chunks.map {
            TranscriptionResult(text: $0, segments: [], language: "ru", timings: TranscriptionTimings())
        })
    }
}
