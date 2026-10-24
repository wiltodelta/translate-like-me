import Foundation
import MLX
import XCTest
@testable import TranslateLikeMe

final class LocalModelIntegrationTests: XCTestCase {
    private struct Sample: Sendable {
        let text: String
        let pair: LanguagePair
        let terms: [[String]]
    }

    private static let samples = [
        Sample(text: "The build fails on CI after the dependency update.",
               pair: LanguagePair(first: "en", second: "ru", shortcut: nil),
               terms: [["сбор", "построен"], ["ci", "непрерывн"], ["обнов"]]),
        Sample(text: "Сборка падает на CI после обновления зависимостей.",
               pair: LanguagePair(first: "ru", second: "en", shortcut: nil),
               terms: [["build"], ["ci", "continuous integration"], ["dependenc"]])
    ]

    func testCachedModelsTranslateSyntheticTextThroughTheNativeEngine() async throws {
        guard let report = ProcessInfo.processInfo.environment["TLM_LOCAL_CHECK_REPORT"],
              let library = ProcessInfo.processInfo.environment["TLM_LOCAL_METALLIB"] else {
            throw XCTSkip("Opt in with TLM_LOCAL_CHECK_REPORT and TLM_LOCAL_METALLIB after downloading every model")
        }
        GPU.metallib = URL(fileURLWithPath: library)
        let base = ProcessInfo.processInfo.environment["TLM_LOCAL_MODELS_BASE"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.wiltodelta.translatelikeme.dev/Translation")
        let files = LocalModelFiles(base: base, availableStorage: LocalModelFiles.live.availableStorage)
        if ProcessInfo.processInfo.environment["TLM_LOCAL_CHECK_DOWNLOAD"] == "YES" {
            for model in LocalModel.allCases where !files.isInstalled(model) {
                try await files.download(model) { _ in }
            }
        }
        let engine = LocalEngine(files: files)
        var rows: [[String: Any]] = []
        for model in LocalModel.allCases {
            for (index, sample) in Self.samples.enumerated() {
                for repetition in 1...3 {
                    let text = try await Translator.translateLocally(sample.text, pair: sample.pair) { system in
                        try await engine.complete(system: system, text: sample.text, model: model)
                    }
                    let matched = sample.terms.filter { terms in
                        terms.contains { text.lowercased().contains($0) }
                    }.count
                    XCTAssertFalse(text.isEmpty)
                    XCTAssertEqual(matched, sample.terms.count,
                                   "Missing synthetic terms for \(model), case \(index): \(text)")
                    rows.append(["model": model.rawValue, "case": index, "repetition": repetition,
                                 "matchedTerms": matched, "requiredTerms": sample.terms.count])
                }
            }
        }
        await engine.releaseIfIdle(reason: "integration check")
        let loaded = await engine.loadedModel
        XCTAssertNil(loaded)
        try JSONSerialization.data(withJSONObject: ["rows": rows, "unloaded": loaded == nil],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: report))
    }
}
