import Foundation
import XCTest
@testable import TranslateLikeMe

final class ModelResolverTests: XCTestCase {
    // codexModel() reads $CODEX_HOME/models_cache.json. Point CODEX_HOME at a
    // throwaway directory so the test never depends on the real machine's cache.
    private func withCodexHome(_ json: String?, _ body: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let json {
            try? json.write(to: dir.appendingPathComponent("models_cache.json"),
                            atomically: true, encoding: .utf8)
        }
        setenv("CODEX_HOME", dir.path, 1)
        defer {
            unsetenv("CODEX_HOME")
            try? FileManager.default.removeItem(at: dir)
        }
        body()
    }

    func testCodexPicksNewestMini() {
        let json = """
        {"models":[{"slug":"gpt-5.2-mini"},{"slug":"gpt-7.1-mini"},{"slug":"gpt-5.3-mini"}]}
        """
        withCodexHome(json) {
            XCTAssertEqual(ModelResolver.codexModel(), "gpt-7.1-mini")
        }
    }

    func testCodexIgnoresNonMiniSlugs() {
        // gpt-9.9 has a higher version but is not a "mini"; the mini must win.
        let json = """
        {"models":[{"slug":"gpt-9.9"},{"slug":"gpt-5.1-mini"}]}
        """
        withCodexHome(json) {
            XCTAssertEqual(ModelResolver.codexModel(), "gpt-5.1-mini")
        }
    }

    func testCodexFallbackWhenCacheMissing() {
        withCodexHome(nil) {
            XCTAssertEqual(ModelResolver.codexModel(), "gpt-5.4-mini")
        }
    }

    func testCodexFallbackWhenNoMiniPresent() {
        let json = """
        {"models":[{"slug":"gpt-9.9"},{"slug":"o3"}]}
        """
        withCodexHome(json) {
            XCTAssertEqual(ModelResolver.codexModel(), "gpt-5.4-mini")
        }
    }

    func testPickAnthropicPrefersSonnet() {
        let ids = ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5"]
        XCTAssertEqual(ModelResolver.pick(provider: .anthropic, from: ids), "claude-sonnet-4-6")
    }

    func testPickOpenAIExcludesSpecialisedMinis() {
        // audio / realtime variants contain "mini" but must be skipped.
        let ids = ["gpt-5.4-audio-mini", "gpt-5.4-realtime-mini", "gpt-5.4-mini", "gpt-5.4"]
        XCTAssertEqual(ModelResolver.pick(provider: .openai, from: ids), "gpt-5.4-mini")
    }
}
