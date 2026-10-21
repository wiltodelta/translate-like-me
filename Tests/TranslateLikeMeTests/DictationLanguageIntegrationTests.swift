import Foundation
import XCTest
@testable import TranslateLikeMe

final class DictationLanguageIntegrationTests: XCTestCase {
    private struct Example: Decodable {
        let id: String
        let file: String
        let expected: String
        let language: String
    }

    // Existing verified caches only; no microphone, playback, downloads or personal audio.
    func testAllModelsWithAndWithoutTranslationLanguagePreference() async throws {
        guard let folder = ProcessInfo.processInfo.environment["TLM_LANGUAGE_PREFERENCE_CHECK"] else {
            throw XCTSkip("Set TLM_LANGUAGE_PREFERENCE_CHECK to a synthetic cases.json directory")
        }
        try DictationQwenTestSupport.configure()
        let root = URL(fileURLWithPath: folder)
        let examples = try JSONDecoder().decode([Example].self,
            from: Data(contentsOf: root.appendingPathComponent("cases.json")))
        XCTAssertFalse(examples.isEmpty)
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.wiltodelta.translatelikeme.dev/Dictation")
        var rows: [[String: String]] = []
        for model in DictationModel.allCases {
            for identifiers in [[], ["ru", "en"]] {
                let engine = DictationEngine(directory: cache, languageIdentifiers: { identifiers })
                try await engine.prepare(model: model, download: false) { _ in }
                let loaded = await engine.loadedModel
                XCTAssertEqual(loaded, model)
                for example in examples {
                    let text = try await engine.transcribe(URL(fileURLWithPath: example.file))
                    rows.append(["model": model.rawValue, "arm": identifiers.isEmpty ? "baseline" : "preferred",
                                 "id": example.id, "expected": example.expected, "actual": text,
                                 "language": example.language])
                    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                        .write(to: root.appendingPathComponent("preference-results.json"))
                }
                await engine.unload()
                let unloaded = await engine.loadedModel
                XCTAssertNil(unloaded)
            }
        }
        XCTAssertEqual(rows.count, examples.count * DictationModel.allCases.count * 2)
    }
}
