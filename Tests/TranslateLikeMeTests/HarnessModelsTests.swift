import XCTest
@testable import TranslateLikeMe

final class HarnessModelsTests: XCTestCase {
    // Trimmed from the real ~/.claude/cache/model-catalog/<account>-cc.json
    // (Claude Code 2.1.280, 2026-09-23): Haiku takes no effort setting.
    private let claudeCatalog = """
    {"version": 2, "catalog": {"surface": "cc",
      "config": {"models": [
        {"id": "claude-opus-5-5", "name": "Opus 5.5", "short_name": "Opus", "section": "main",
         "thinking": {"type": "effort", "effort_options": [{"id": "low", "name": "Low"}, {"id": "xhigh", "name": "Extra"}]}},
        {"id": "claude-haiku-4-5-20251001", "name": "Haiku 4.5", "section": "main",
         "thinking": {"type": "effort", "effort_options": []}}
      ]},
      "state": {"model": "claude-opus-5-5", "selection_source": "global_default"}}}
    """

    // Trimmed from the real ~/.codex/models_cache.json (codex-cli 0.156.1,
    // 2026-09-23): out of priority order, with one hidden entry.
    private let codexCache = """
    {"fetched_at": "2026-09-23T21:51:55Z", "models": [
      {"slug": "gpt-6-luna", "display_name": "GPT-6-Luna", "visibility": "list", "priority": 3,
       "supported_reasoning_levels": [{"effort": "low", "description": "Fast"}, {"effort": "max", "description": "Max"}]},
      {"slug": "gpt-reserve", "display_name": "GPT-Reserve", "visibility": "hide", "priority": 3,
       "supported_reasoning_levels": [{"effort": "low", "description": "Fast"}]},
      {"slug": "gpt-6-astra", "display_name": "GPT-6-Astra", "visibility": "list", "priority": 1,
       "supported_reasoning_levels": [{"effort": "low", "description": "Fast"}, {"effort": "ultra", "description": "Ultra"}]}
    ]}
    """

    // Trimmed from the real ~/.grok/models_cache.json (grok 1.0.41, 2026-09-23);
    // entries also carry api_key/env_key fields, which are never read.
    private let grokCache = """
    {"grok_version": "1.0.41", "models": {
      "grok-4.5": {"info": {"id": "grok-4.5", "name": "Grok 4.5", "hidden": false,
        "reasoning_efforts": [{"value": "high", "label": "High"}, {"value": "low", "label": "Low"}]},
        "api_key": null},
      "grok-internal": {"info": {"id": "grok-internal", "name": "Internal", "hidden": true}},
      "grok-4.7": {"info": {"id": "grok-4.7", "name": "Grok 4.7", "hidden": false,
        "reasoning_efforts": [{"value": "xhigh", "label": "Extra High"}, {"value": "high", "label": "High"}]}}
    }}
    """

    func testClaudeCatalogCarriesPerModelEffortsAndTheDefault() throws {
        let catalog = try XCTUnwrap(HarnessModels.parseClaude(Data(claudeCatalog.utf8)))
        XCTAssertEqual(catalog.models.map(\.name), ["Opus 5.5", "Haiku 4.5"])
        XCTAssertEqual(catalog.defaultModel, "claude-opus-5-5")
        XCTAssertEqual(catalog.efforts(for: "claude-opus-5-5"), [.init(id: "low", name: "Low"),
                                                                  .init(id: "xhigh", name: "Extra")])
        XCTAssertEqual(catalog.efforts(for: "claude-haiku-4-5-20251001"), [])
        XCTAssertNil(catalog.efforts(for: "unknown"))
    }

    func testUnreadableClaudeCatalogFallsBackToTheAliases() {
        XCTAssertNil(HarnessModels.parseClaude(Data("{}".utf8)))
        withConfigDir("CLAUDE_CONFIG_DIR", file: "cache/model-catalog/x-cc.json", contents: "not json") {
            XCTAssertEqual(HarnessModels.catalog(for: .anthropic), HarnessModels.claudeAliases)
        }
    }

    func testCodexListsVisibleModelsInPriorityOrder() {
        let catalog = HarnessModels.parseCodex(Data(codexCache.utf8))
        XCTAssertEqual(catalog.models.map(\.id), ["gpt-6-astra", "gpt-6-luna"])
        XCTAssertEqual(catalog.efforts(for: "gpt-6-luna")?.map(\.id), ["low", "max"])
        XCTAssertEqual(catalog.efforts(for: "gpt-6-luna")?.first?.name, "Low")
    }

    func testGrokListsVisibleModelsNewestFirstWithLabels() {
        let catalog = HarnessModels.parseGrok(Data(grokCache.utf8))
        XCTAssertEqual(catalog.models.map(\.id), ["grok-4.7", "grok-4.5"])
        XCTAssertEqual(catalog.efforts(for: "grok-4.7"), [.init(id: "xhigh", name: "Extra High"),
                                                          .init(id: "high", name: "High")])
    }

    // A changed or broken cache must yield no models, never a crash, so Settings
    // falls back to "Default" alone.
    func testUnreadableCachesYieldNoModels() {
        for text in ["", "not json", #"{"models": "nope"}"#, #"{"models": [{"no_slug": 1}]}"#] {
            XCTAssertEqual(HarnessModels.parseCodex(Data(text.utf8)), HarnessCatalog(), text)
            XCTAssertEqual(HarnessModels.parseGrok(Data(text.utf8)), HarnessCatalog(), text)
        }
    }

    // MARK: - HarnessChoice.resolve

    private let catalog = HarnessCatalog(models: [
        HarnessModel(id: "gpt-6-luna", name: "GPT-6-Luna", efforts: [.init(id: "low", name: "Low")])
    ])

    func testPickWinsOverConfiguredDefault() {
        let choice = HarnessChoice.resolve(picked: .init(model: "gpt-6-luna", effort: "low"),
                                           configured: .init(model: "gpt-5.6-sol", effort: "medium"),
                                           catalog: { self.catalog })
        XCTAssertEqual(choice, .init(model: "gpt-6-luna", effort: "low"))
    }

    // With no pick the user's own config passes through, and no cache is read.
    func testNoPickUsesTheConfigWithoutReadingTheCatalog() {
        let choice = HarnessChoice.resolve(picked: .init(), configured: .init(model: "gpt-5.6-sol", effort: "medium"),
                                           catalog: { XCTFail("catalog read without a pick"); return self.catalog })
        XCTAssertEqual(choice, .init(model: "gpt-5.6-sol", effort: "medium"))
    }

    func testEffortTheResolvedModelRejectsIsDropped() {
        let inherited = HarnessChoice.resolve(picked: .init(model: "gpt-6-luna"),
                                              configured: .init(model: "gpt-5.6-sol", effort: "medium"),
                                              catalog: { self.catalog })
        XCTAssertEqual(inherited, .init(model: "gpt-6-luna", effort: nil))
        // A stale pick is checked too, e.g. after the CLI's cache refreshed.
        let stale = HarnessChoice.resolve(picked: .init(model: "gpt-6-luna", effort: "ultra"),
                                          configured: .init(), catalog: { self.catalog })
        XCTAssertEqual(stale, .init(model: "gpt-6-luna", effort: nil))
    }

    func testUnknownModelKeepsTheEffort() {
        let choice = HarnessChoice.resolve(picked: .init(model: "gpt-9"), configured: .init(effort: "medium"),
                                           catalog: { self.catalog })
        XCTAssertEqual(choice, .init(model: "gpt-9", effort: "medium"))
    }
}
