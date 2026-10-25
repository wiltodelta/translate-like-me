import Foundation
import os
import XCTest
@testable import TranslateLikeMe

@MainActor
final class LocalPreparationTests: XCTestCase {
    func testSettingsChangesRequestPreparationAfterPersistingTheSelection() {
        let defaults = UserDefaults.standard
        let keys = ["provider", "localModel", "languagePairs", "rewritePresets"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        Settings.provider = .local
        Settings.localModel = .gemma4E2B
        Settings.languagePairs = [LanguagePair(first: "en", second: "ru", shortcut: nil)]
        Settings.rewritePresets = [RewritePreset(name: "Work", shortcut: nil)]
        var changes = 0
        let store = SettingsStore(refreshCatalog: { _ in }, localConfigurationChanged: {
            changes += 1
        })
        XCTAssertEqual(changes, 0, "Construction must not launch live model work in tests")
        store.localModel = .gemma4Model12B
        XCTAssertEqual(Settings.localModel, .gemma4Model12B)
        store.pairs[0].style = "Brief"
        store.rewritePresets[0].style = "Friendly"
        store.provider = .grok
        XCTAssertEqual(changes, 4)
        store.localModel = store.localModel
        store.pairs = store.pairs
        store.rewritePresets = store.rewritePresets
        store.provider = store.provider
        XCTAssertEqual(changes, 4, "Unchanged fields must not restart preparation")
    }

    func testSupersededPreparationDrainsBeforePreparingTheLatestSelection() async {
        let started = TestGate()
        let drain = TestGate()
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let preparation = LocalPreparation(prepare: { model, _ in
            events.withLock { $0.append("start " + model.rawValue) }
            if model == .gemma4E2B {
                await started.open()
                await drain.wait()
            }
            events.withLock { $0.append("end " + model.rawValue) }
        }, release: { events.withLock { $0.append("release") } }, sleep: {})
        preparation.update(model: .gemma4E2B, pairs: [], presets: [])
        await started.wait()
        preparation.update(model: .translateGemma12B, pairs: [], presets: [])
        XCTAssertEqual(events.withLock { $0 }, ["start gemma-4-e2b"])
        await drain.open()
        await preparation.operation?.value
        XCTAssertEqual(events.withLock { $0 }, ["start gemma-4-e2b", "end gemma-4-e2b",
                                               "start translategemma-12b", "end translategemma-12b"])
        preparation.update(model: nil, pairs: [], presets: [])
        await preparation.operation?.value
        XCTAssertEqual(events.withLock { $0.last }, "release")
    }

    func testPreparationUsesTheRealPromptsWithinTheExistingCacheBudget() async {
        let pair = LanguagePair(first: "en", second: "ru", shortcut: nil, style: "Keep it brief.")
        let presets = (1...3).map { RewritePreset(name: "Preset \($0)", shortcut: nil, style: "Style \($0)") }
        let preparation = LocalPreparation(prepare: { model, systems in
            XCTAssertEqual(model, .gemma4Model12B)
            XCTAssertEqual(systems, [Translator.systemPrompt(pair: pair)]
                + presets.prefix(2).map { Rewrite.systemPrompt(preset: $0) })
        }, release: { XCTFail("A selected model must be prepared") }, sleep: {})
        preparation.update(model: .gemma4Model12B, pairs: [pair], presets: presets)
        await preparation.operation?.value
    }

    func testCancelledDebounceNeverLoadsTheSupersededModel() async {
        let started = TestGate()
        let gate = TestGate()
        let preparation = LocalPreparation(prepare: { _, _ in XCTFail("Cancelled edits must not load a model") },
            release: {}, sleep: {
                await started.open()
                await gate.wait()
                try Task.checkCancellation()
            })
        preparation.update(model: .gemma4E2B, pairs: [], presets: [])
        await started.wait()
        preparation.update(model: nil, pairs: [], presets: [])
        await gate.open()
        await preparation.operation?.value
    }
}
