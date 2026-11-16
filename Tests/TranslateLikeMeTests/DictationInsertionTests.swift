import Foundation
import XCTest
@testable import TranslateLikeMe

final class DictationInsertionTests: XCTestCase {
    private struct ContinuationCase {
        let before: String
        let transcript: String
        let langs: [String]
        let expected: String
    }

    func testSentenceStartsAndOutlineMarkersPreserveCapitalization() {
        let starts = [
            "", "First sentence. ", "First sentence.", "Really? ", "Wait… ",
            "Line one\n", "Line one\n  ", "- ", "  * ", "> ", "## ", "1. ", "2) ", "TODO: ", "He said \""
        ]
        for before in starts {
            let context = DictationInsertionContext(beforeSlice: before, afterSlice: "")
            let formatted = DictationInsertion.format("Save the document.", context: context,
                                                      languageIdentifiers: ["en"])
            XCTAssertEqual(formatted.trimmingCharacters(in: .whitespaces), "Save the document.",
                           "Unexpected lowercasing after \(before.debugDescription)")
        }
    }

    func testMidSentenceContinuationLowercasesAcrossBicameralScripts() {
        let cases = [
            ContinuationCase(before: "Please, ", transcript: "Save the document.",
                             langs: ["en"], expected: "save the document."),
            ContinuationCase(before: "Please,", transcript: "Save the document.",
                             langs: ["en"], expected: " save the document."),
            ContinuationCase(before: "First - ", transcript: "Continue tomorrow.",
                             langs: ["en"], expected: "continue tomorrow."),
            ContinuationCase(before: "D'abord, ", transcript: "Enregistre le fichier.",
                             langs: ["fr"], expected: "enregistre le fichier."),
            ContinuationCase(before: "D'abord, ", transcript: "C'est prêt.",
                             langs: ["fr"], expected: "c'est prêt."),
            ContinuationCase(before: "D'abord, ", transcript: "L'archive est prête.",
                             langs: ["fr"], expected: "l'archive est prête."),
            ContinuationCase(before: "Primero, ", transcript: "Guarda el archivo.",
                             langs: ["es"], expected: "guarda el archivo."),
            ContinuationCase(before: "Prima, ", transcript: "Salva il documento.",
                             langs: ["it"], expected: "salva il documento."),
            ContinuationCase(before: "Primeiro, ", transcript: "Salve o arquivo.",
                             langs: ["pt-BR"], expected: "salve o arquivo."),
            ContinuationCase(before: "Πρώτα, ", transcript: "Συνέχισε τώρα.",
                             langs: ["el"], expected: "συνέχισε τώρα."),
            ContinuationCase(before: "Նախ, ", transcript: "Շարունակիր հիմա։",
                             langs: ["hy"], expected: "շարունակիր հիմա։"),
            ContinuationCase(before: "Сначала, ", transcript: "Продолжай работу.",
                             langs: ["ru"], expected: "продолжай работу."),
            ContinuationCase(before: "Спочатку, ", transcript: "Продовжуй роботу.",
                             langs: ["uk"], expected: "продовжуй роботу.")
        ]
        for item in cases {
            let context = DictationInsertionContext(beforeSlice: item.before, afterSlice: "")
            XCTAssertEqual(
                DictationInsertion.format(item.transcript, context: context, languageIdentifiers: item.langs),
                item.expected, "Failed for \(item.langs) on \(item.transcript)"
            )
        }
    }

    func testTurkishDottedAndDotlessILowercaseWithTurkicRules() {
        let context = DictationInsertionContext(beforeSlice: "Lütfen, ", afterSlice: "")
        let dotted = DictationInsertion.format("İlerleyelim.", context: context, languageIdentifiers: ["tr", "en"])
        XCTAssertEqual(dotted, "ilerleyelim.")
        XCTAssertEqual(dotted.first?.unicodeScalars.count, 1, "Must produce U+0069 without a combining dot")

        let dotless = DictationInsertion.format("Işık yak.", context: context, languageIdentifiers: ["tr", "en"])
        XCTAssertEqual(dotless, "ışık yak.")
    }

    func testPolishAndEnglishHandleStandaloneLatinI() {
        let context = DictationInsertionContext(beforeSlice: "Zapisz, ", afterSlice: "")
        XCTAssertEqual(
            DictationInsertion.format("I wyślij dokument.", context: context, languageIdentifiers: ["pl", "en"]),
            "i wyślij dokument."
        )
        XCTAssertEqual(
            DictationInsertion.format("I will send it.", context: context, languageIdentifiers: ["pl", "en"]),
            "I will send it."
        )
        XCTAssertEqual(
            DictationInsertion.format("I'm ready.", context: context, languageIdentifiers: ["en"]),
            "I'm ready."
        )
    }

    func testGermanPreservesNounsWhileLowercasingAdverbsAndParticles() {
        let context = DictationInsertionContext(beforeSlice: "Bitte, ", afterSlice: "")
        XCTAssertEqual(
            DictationInsertion.format("Haus und Garten.", context: context, languageIdentifiers: ["de", "en"]),
            "Haus und Garten."
        )
        XCTAssertEqual(
            DictationInsertion.format("Datei wurde gespeichert.", context: context, languageIdentifiers: ["de", "en"]),
            "Datei wurde gespeichert."
        )
        XCTAssertEqual(
            DictationInsertion.format("Schnell erledigt.", context: context, languageIdentifiers: ["de", "en"]),
            "schnell erledigt."
        )
        XCTAssertEqual(
            DictationInsertion.format("Heute passt es.", context: context, languageIdentifiers: ["de", "en"]),
            "heute passt es."
        )
    }

    func testVocabularyAcronymsMixedCaseAndProperNamesStayCapitalized() {
        let vocabulary = DictationVocabulary("Veedma, Claude Code, Wiltodelta")
        let context = DictationInsertionContext(beforeSlice: "Check ", afterSlice: "")
        for preserved in [
            "Veedma deployment.", "Claude Code session.", "CI failed again.", "GitHub actions passed.",
            "L'Oréal campaign.", "3D preview.", "John called yesterday.", "Madrid está lejos.", "¿Cómo estás?"
        ] {
            XCTAssertEqual(
                DictationInsertion.format(preserved, context: context, vocabulary: vocabulary,
                                          languageIdentifiers: ["en", "es", "fr"]),
                preserved, "Unexpectedly lowercased: \(preserved)"
            )
        }
    }

    func testParentheticalAutoPeriodRemovalAcrossSpacedAndUnspacedScripts() {
        XCTAssertEqual(
            DictationInsertion.format("Session.", context: .init(beforeSlice: "Current (", afterSlice: ")"),
                                      languageIdentifiers: ["en"]), "session"
        )
        XCTAssertEqual(
            DictationInsertion.format("セッション。", context: .init(beforeSlice: "現在の(", afterSlice: ")"),
                                      languageIdentifiers: ["ja"]), "セッション"
        )
        XCTAssertEqual(
            DictationInsertion.format("继续。", context: .init(beforeSlice: "今天（", afterSlice: "）"),
                                      languageIdentifiers: ["zh-Hans"]), "继续"
        )
        XCTAssertEqual(
            DictationInsertion.format("आगे बढ़ो।", context: .init(beforeSlice: "स्थिति (", afterSlice: ")"),
                                      languageIdentifiers: ["hi"]), "आगे बढ़ो"
        )
        XCTAssertEqual(
            DictationInsertion.format("جاهزة.", context: .init(beforeSlice: "الحالة (", afterSlice: ")"),
                                      languageIdentifiers: ["ar"]), "جاهزة"
        )
    }

    func testMidLineSpacingAndPreservedTerminalPunctuation() {
        XCTAssertEqual(
            DictationInsertion.format("Save.", context: .init(beforeSlice: "Please ", afterSlice: "the file."),
                                      languageIdentifiers: ["en"]), "save "
        )
        XCTAssertEqual(
            DictationInsertion.format("Save.", context: .init(beforeSlice: "Please", afterSlice: " the file."),
                                      languageIdentifiers: ["en"]), " save"
        )
        XCTAssertEqual(
            DictationInsertion.format("The build.", context: .init(beforeSlice: "", afterSlice: " is green."),
                                      languageIdentifiers: ["en"]), "The build"
        )
        XCTAssertEqual(
            DictationInsertion.format("The build.", context: .init(beforeSlice: "Header\n  ", afterSlice: "is green."),
                                      languageIdentifiers: ["en"]), "The build "
        )
        XCTAssertEqual(
            DictationInsertion.format(
                "Second sentence.",
                context: .init(beforeSlice: "First sentence. ", afterSlice: "Third sentence."),
                languageIdentifiers: ["en"]
            ), "Second sentence. "
        )
        XCTAssertEqual(
            DictationInsertion.format("Really?", context: .init(beforeSlice: "Wait (", afterSlice: ")"),
                                      languageIdentifiers: ["en"]), "really?"
        )
        XCTAssertEqual(
            DictationInsertion.format("e.g.", context: .init(beforeSlice: "Tools (", afterSlice: ")"),
                                      languageIdentifiers: ["en"]), "e.g."
        )
        XCTAssertEqual(
            DictationInsertion.format("First. Second.", context: .init(beforeSlice: "Note: ", afterSlice: " Done."),
                                      languageIdentifiers: ["en"]), "First. Second."
        )
    }

    func testUTF16ExtractionPreservesSlicesAroundEmojiAndFieldStart() {
        let text = "Hi 🚀 (world)"
        let insideParens = NSRange(location: 7, length: 0)
        let context = DictationContext.insertionContext(in: text, selection: insideParens)
        XCTAssertEqual(context.beforeSlice, "Hi 🚀 (")
        XCTAssertEqual(context.afterSlice, "world)")
        XCTAssertTrue(context.hasCompleteLinePrefix)

        let atStart = DictationContext.insertionContext(in: text, selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(atStart.beforeSlice, "")
        XCTAssertEqual(atStart.afterSlice, text)
    }
}
