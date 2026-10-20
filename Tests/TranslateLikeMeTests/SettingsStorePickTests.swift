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
            let store = SettingsStore(refreshCatalog: { _ in })
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
        let store = SettingsStore(refreshCatalog: { _ in })
        store.pick = .init(model: "gemini-3.8-flash", effort: "high")
        XCTAssertEqual(store.effortOptions.map(\.id), ["low", "high"])
        XCTAssertEqual(Settings.harnessPick(for: .antigravity), .init(model: "gemini-3.8-flash", effort: "high"))

        store.pick.model = nil
        XCTAssertEqual(store.effortOptions, [])
        XCTAssertEqual(Settings.harnessPick(for: .antigravity), .init())
    }

    func testReadinessProbeUpdatesAnAlreadyOpenModelList() async throws {
        let savedProvider = Settings.provider, savedModels = Settings.antigravityModels
        let savedPick = Settings.harnessPick(for: .antigravity)
        let savedGrokHome = ProcessInfo.processInfo.environment["GROK_HOME"]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            if let savedGrokHome { setenv("GROK_HOME", savedGrokHome, 1) } else { unsetenv("GROK_HOME") }
            Settings.setHarnessPick(savedPick, for: .antigravity)
            Settings.antigravityModels = savedModels
            Settings.provider = savedProvider
            try? FileManager.default.removeItem(at: directory)
        }
        try grokCache.write(to: directory.appendingPathComponent("models_cache.json"),
                            atomically: true, encoding: .utf8)
        setenv("GROK_HOME", directory.path, 1)
        let binary = directory.appendingPathComponent("agy")
        try """
        #!/bin/sh
        test "$1" = models || exit 2
        printf 'gemini-3.8-flash-low\\tGemini 3.8 Flash (Low)\\n'
        printf 'gemini-3.8-flash-high\\tGemini 3.8 Flash (High)\\n'
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        Settings.antigravityModels = nil
        Settings.provider = .antigravity
        let store = SettingsStore(refreshCatalog: { _ in })
        XCTAssertTrue(store.catalog.models.isEmpty)

        let readiness = await EngineStatus.readiness(binary: binary.path, provider: .antigravity)

        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(HarnessModels.catalog(for: .antigravity).models.count, 1,
                       "The real probe must have populated the cache before checking the open list")
        XCTAssertEqual(store.catalog.models.map(\.id), ["gemini-3.8-flash"])
        store.pick.model = "gemini-3.8-flash"
        XCTAssertEqual(store.effortOptions.map(\.id), ["low", "high"])
        store.provider = .grok
        let otherCatalog = store.catalog
        XCTAssertEqual(otherCatalog.models.count, 2)
        let laterReadiness = await EngineStatus.readiness(binary: binary.path, provider: .antigravity)
        XCTAssertEqual(laterReadiness, .ready)
        XCTAssertEqual(store.catalog, otherCatalog, "A late probe must not replace another provider's models")
    }
}
