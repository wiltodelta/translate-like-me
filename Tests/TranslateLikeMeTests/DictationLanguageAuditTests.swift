import Foundation
import os
@preconcurrency import WhisperKit
import XCTest
@testable import TranslateLikeMe

@MainActor
final class DictationLanguageAuditTests: XCTestCase {
    private struct Example: Decodable {
        let id: String
        let file: String
        let expected: String
    }

    private struct Profile {
        let name: String
        let pairs: [LanguagePair]
        let example: Example
    }

    func testLiveConfigurationInventoriesSilenceAndCancellation() async throws {
        guard let folder = ProcessInfo.processInfo.environment["TLM_LANGUAGE_AUDIT"] else {
            throw XCTSkip("Set TLM_LANGUAGE_AUDIT to the retained synthetic language fixture")
        }
        try DictationQwenTestSupport.configure()
        let root = URL(fileURLWithPath: folder)
        let profiles = try profiles(root: root)
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.wiltodelta.translatelikeme.dev/Dictation")
        var report: [[String: Any]] = []
        for model in DictationModel.allCases {
            let reads = OSAllocatedUnfairLock(initialState: 0)
            let engine = DictationEngine(directory: cache, languageIdentifiers: {
                reads.withLock { $0 += 1 }
                return DictationLanguagePreference.configuredIdentifiers
            })
            try await engine.prepare(model: model, download: false) { _ in }
            XCTAssertEqual(reads.withLock { $0 }, 0)
            report.append(try inventory(model: model, cache: cache))
            for profile in profiles {
                let example = profile.example
                var domain = saved
                domain["languagePairs"] = try JSONEncoder().encode(profile.pairs)
                defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
                let before = reads.withLock { $0 }
                let text = try await engine.transcribe(URL(fileURLWithPath: example.file))
                XCTAssertEqual(reads.withLock { $0 }, before + 1,
                               "Read the current pairs at the real transcription seam")
                XCTAssertEqual(normalized(text), normalized(example.expected), "\(model.rawValue): \(profile.name)")
                let loaded = await engine.loadedModel
                XCTAssertEqual(loaded, model)
                report.append(["model": model.rawValue, "profile": profile.name, "actual": text,
                               "expected": example.expected, "pairReads": reads.withLock { $0 }])
                try write(report, root: root)
            }
            var checks = try await checkEarlyExits(engine: engine, reads: reads, root: root)
            await engine.unload()
            let unloaded = await engine.loadedModel
            XCTAssertNil(unloaded)
            checks["unloaded"] = unloaded == nil
            report.append(["model": model.rawValue, "checks": checks])
            try write(report, root: root)
        }
        XCTAssertEqual(report.count, DictationModel.allCases.count * (profiles.count + 2))
    }

    private func profiles(root: URL) throws -> [Profile] {
        let examples = try JSONDecoder().decode([Example].self,
            from: Data(contentsOf: root.appendingPathComponent("base-cases.json")))
        let yes = try XCTUnwrap(examples.first { $0.id == "7" })
        let russian = try XCTUnwrap(examples.first { $0.id == "0" })
        let chinese = try XCTUnwrap(examples.first { $0.id == "11" })
        let english = Example(id: "long-en", file: root.appendingPathComponent("history-en.aiff").path,
            expected: "Today we are checking how dictation works. " +
                "Please save the document and send the completed report tomorrow morning.")
        return [
            Profile(name: "no-pairs", pairs: [], example: yes),
            Profile(name: "incomplete", pairs: [pair("ru", "")], example: yes),
            Profile(name: "three-pairs",
                    pairs: [pair("ru", "en"), pair("zh-Hans", "zh-Hant"), pair("pt-BR", "pt-PT")], example: russian),
            Profile(name: "unsupported", pairs: [pair("zz", "en")], example: chinese),
            Profile(name: "outside-language", pairs: [pair("de", "zh-Hans")], example: english),
            Profile(name: "changed-back", pairs: [pair("ru", "en")], example: russian)
        ]
    }

    private func checkEarlyExits(engine: DictationEngine, reads: OSAllocatedUnfairLock<Int>,
                                 root: URL) async throws -> [String: Bool] {
        let before = reads.withLock { $0 }
        let silent = try await engine.transcribe(root.appendingPathComponent("audit-silence.wav"))
        XCTAssertTrue(silent.isEmpty)
        XCTAssertEqual(reads.withLock { $0 }, before)
        let audio = root.appendingPathComponent("history-en.aiff")
        let cancelled = Task { @Sendable in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.transcribe(audio)
        }
        var didCancel = false
        do {
            _ = try await cancelled.value
            XCTFail("Cancellation must reach the real engine before language selection")
        } catch is CancellationError { didCancel = true }
        XCTAssertEqual(reads.withLock { $0 }, before)
        return ["silence": silent.isEmpty, "cancellation": didCancel,
                "preferenceSkipped": reads.withLock { $0 } == before]
    }

    private func inventory(model: DictationModel, cache: URL) throws -> [String: Any] {
        let identifiers = Languages.all.map(\.code)
        let native: Set<String>
        let covered: Set<String>
        let offered: Set<String>
        if let tokenizer = model.tokenizer {
            let config = ModelDownloadConfig(modelRepo: tokenizer.repository, revision: tokenizer.revision)
            let root = ModelDownloader(config: config).localRepoLocation(downloadBase: cache)
            let data = try Data(contentsOf: root.appendingPathComponent("tokenizer_config.json"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let added = try XCTUnwrap(object["added_tokens_decoder"] as? [String: [String: Any]])
            native = Set(added.values.compactMap { token in
                guard let text = token["content"] as? String else { return nil }
                let code = text.trimmingCharacters(in: CharacterSet(charactersIn: "<|>"))
                return Constants.languageCodes.contains(code) ? code : nil
            })
            covered = Set(identifiers.flatMap {
                DictationLanguagePreference(identifiers: [$0]).resolvedCodes(supported: native)
            })
            let identities = Set(identifiers.flatMap { DictationLanguagePreference(identifiers: [$0]).codes })
            offered = Set(native.filter {
                !DictationLanguagePreference(identifiers: [$0]).codes.isDisjoint(with: identities)
            })
        } else {
            let root = ModelDownloader(config: DictationQwen.source).localRepoLocation(downloadBase: cache)
            let data = try Data(contentsOf: root.appendingPathComponent("config.json"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let names = try XCTUnwrap(object["support_languages"] as? [String])
            native = Set(names)
            offered = native
            covered = Set(identifiers.flatMap {
                DictationLanguagePreference(identifiers: [$0]).resolvedNames(supported: names)
            })
        }
        XCTAssertFalse(native.isEmpty)
        let missing = offered.subtracting(covered).sorted()
        XCTAssertTrue(missing.isEmpty, "Unmapped native languages in \(model.rawValue): \(missing)")
        return ["model": model.rawValue, "uiIdentifiers": identifiers.count,
                "nativeLanguages": native.count, "offeredLanguages": offered.count,
                "coveredLanguages": covered.count, "notOffered": native.subtracting(offered).sorted(),
                "unmapped": missing]
    }

    private func pair(_ first: String, _ second: String) -> LanguagePair {
        LanguagePair(first: first, second: second, shortcut: nil)
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "[\\W_]+", with: "", options: .regularExpression)
    }

    private func write(_ rows: [[String: Any]], root: URL) throws {
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("configuration-audit-results.json"))
    }
}
