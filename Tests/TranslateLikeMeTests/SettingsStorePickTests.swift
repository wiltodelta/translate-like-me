import Foundation
import XCTest
@testable import TranslateLikeMe

@MainActor
final class SettingsStorePickTests: XCTestCase {
    // grok-4.5 lists no xhigh (real ~/.grok/models_cache.json, 2026-09-23).
    private let grokCache = """
    {"models": {
      "grok-4.7": {"info": {"id": "grok-4.7", "name": "Grok 4.7",
        "reasoning_efforts": [{"value": "xhigh"}, {"value": "high"}, {"value": "low"}]}},
      "grok-4.5": {"info": {"id": "grok-4.5", "name": "Grok 4.5",
        "reasoning_efforts": [{"value": "high"}, {"value": "low"}]}}
    }}
    """

    func testModelChangeResetsAnEffortTheModelDoesNotAccept() {
        let savedProvider = Settings.provider
        defer {
            Settings.setHarnessPick(.init(), for: .grok)
            Settings.provider = savedProvider
        }
        withConfigDir("GROK_HOME", file: "models_cache.json", contents: grokCache) {
            Settings.provider = .grok
            let store = SettingsStore()
            // grok's default model is not known to the app, so no effort is offered.
            XCTAssertEqual(store.effortOptions, [])

            store.pick = .init(model: "grok-4.7", effort: "xhigh")
            XCTAssertEqual(Settings.harnessPick(for: .grok), .init(model: "grok-4.7", effort: "xhigh"))

            store.pick.model = "grok-4.5"
            XCTAssertNil(store.pick.effort)
            XCTAssertEqual(store.effortOptions.map(\.id), ["high", "low"])
            XCTAssertEqual(Settings.harnessPick(for: .grok), .init(model: "grok-4.5", effort: nil))
        }
    }

    // agy prints no default model, so Default hides the Effort picker and an
    // effort picked with a model goes with it.
    func testDefaultModelDropsAnEffortItsPickerHides() {
        let savedProvider = Settings.provider, savedModels = Settings.antigravityModels
        defer {
            Settings.setHarnessPick(.init(), for: .antigravity)
            Settings.antigravityModels = savedModels
            Settings.provider = savedProvider
        }
        Settings.antigravityModels = "gemini-3.8-flash-low\tGemini 3.8 Flash (Low)\n"
            + "gemini-3.8-flash-high\tGemini 3.8 Flash (High)"
        Settings.provider = .antigravity
        let store = SettingsStore()
        store.pick = .init(model: "gemini-3.8-flash", effort: "high")
        XCTAssertEqual(store.effortOptions.map(\.id), ["low", "high"])
        XCTAssertEqual(Settings.harnessPick(for: .antigravity), .init(model: "gemini-3.8-flash", effort: "high"))

        store.pick.model = nil
        XCTAssertEqual(store.effortOptions, [])
        XCTAssertEqual(Settings.harnessPick(for: .antigravity), .init())
    }
}
