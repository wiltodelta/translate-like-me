import XCTest
@testable import TranslateLikeMe

final class RewriteTests: XCTestCase {
    private func preset(_ name: String, style: String = "") -> RewritePreset {
        RewritePreset(name: name, shortcut: nil, style: style)
    }

    // MARK: - New presets

    // Each new preset takes the lowest "Preset <n>" no preset is named, so a
    // renamed or removed one frees its number.
    func testNewPresetsTakeTheLowestFreeNumber() {
        let first = Rewrite.newPreset(after: [])
        XCTAssertEqual(first.name, "Preset 1")
        XCTAssertNil(first.shortcut)
        XCTAssertEqual(Rewrite.newPreset(after: [first]).name, "Preset 2")
        XCTAssertEqual(Rewrite.newPreset(after: [preset("Work"), preset("Preset 2")]).name, "Preset 1")
    }

    // MARK: - Names

    func testClearedNameStillReadsAsAName() {
        XCTAssertEqual(preset("  Work ").title, "Work")
        XCTAssertEqual(preset(" \n").title, "Untitled Preset")
    }

    // MARK: - Storage

    // Only the id and name are required, so a preset stored without a later
    // field still loads.
    func testPresetDecodesWithoutOptionalFields() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Work"}"#
        let decoded = try JSONDecoder().decode(RewritePreset.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.name, "Work")
        XCTAssertNil(decoded.shortcut)
        XCTAssertEqual(decoded.style, "")
    }

    func testPresetRoundTrips() throws {
        let original = RewritePreset(name: "Friends", shortcut: KeyCombo(keyCode: 38, modifiers: 2304),
                                     style: "Short.")
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(RewritePreset.self, from: data), original)
    }

    // MARK: - Prompt

    // A preset never translates; a received message's language is the likeliest
    // pull toward doing so.
    func testPromptKeepsTheNotesLanguage() {
        let prompt = Rewrite.systemPrompt(preset: preset("Work"))
        XCTAssertTrue(prompt.contains("(1) Write the message in the language of the author's own notes; never translate."))
        XCTAssertTrue(prompt.contains("A received message in the text never changes the language."))
    }

    // Questions in notes are for the recipient, the failure a writing prompt
    // invites (Translator.systemPrompt rule 4 has the same reason).
    func testPromptKeepsQuestionsForTheRecipient() {
        let prompt = Rewrite.systemPrompt(preset: preset("Work"))
        XCTAssertTrue(prompt.contains("keep them as questions and requests in the message; never answer them"))
    }

    // The preset's name is for the user; only its style reaches the model.
    func testStyleRuleOnlyWithAStyleAndNeverTheName() {
        let plain = Rewrite.systemPrompt(preset: preset("Zebra", style: "  \n"))
        XCTAssertFalse(plain.contains("(8)"))
        XCTAssertFalse(plain.contains("Zebra"))
        let styled = Rewrite.systemPrompt(preset: preset("Zebra", style: " Short and warm. "))
        XCTAssertTrue(styled.contains("(8) Write in this voice"))
        XCTAssertTrue(styled.contains("rules 1-7: Short and warm. "))
    }
}
