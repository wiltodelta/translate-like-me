import AppKit
import XCTest
@testable import TranslateLikeMe

@MainActor
final class StatusMenuTests: XCTestCase {
    private let keys = ["languagePairs", "rewritePresets", "dictationShortcut"]
    private var saved: [Any?] = []

    override func setUp() async throws {
        saved = keys.map { UserDefaults.standard.object(forKey: $0) }
    }

    override func tearDown() async throws {
        for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
    }

    // Status names features, and the feature sections follow the order they
    // chain in: dictate, rewrite, translate.
    func testSectionsFollowTheFeatureOrderAndRewriteAlwaysHasOne() {
        _ = NSApplication.shared
        Settings.languagePairs = [LanguagePair(first: "en", second: "ru", shortcut: nil)]
        Settings.rewritePresets = []
        let menu = StatusMenu(results: LastResults(), dictation: { Self.disabledDictation() },
                              pendingUpdate: { nil }, copyResult: { _ in })
        menu.rebuild()
        let items = menu.menu.items
        XCTAssertEqual(items.filter(\.isSectionHeader).map(\.title),
                       ["Status", "Dictate at cursor", "Rewrite selection", "Translate selection"])
        let status = rows(after: "Status", in: items)
        // The Accessibility row's title depends on this process's grant.
        XCTAssertEqual(status.map(\.title).prefix(2), ["Dictation", "Translation"])
        XCTAssertEqual(status.count, 3)
        XCTAssertEqual(status.first?.subtitle, "Off")
        XCTAssertEqual(rows(after: "Dictate at cursor", in: items).map(\.title), ["Set Up Dictation…"])
        XCTAssertEqual(rows(after: "Rewrite selection", in: items).map(\.title), ["Add a Rewrite Preset…"])

        Settings.rewritePresets = [RewritePreset(name: "Work", shortcut: nil)]
        menu.rebuild()
        XCTAssertEqual(rows(after: "Rewrite selection", in: menu.menu.items).map(\.title), ["Work"])
    }

    private func rows(after header: String, in items: [NSMenuItem]) -> [NSMenuItem] {
        guard let start = items.firstIndex(where: { $0.isSectionHeader && $0.title == header }) else { return [] }
        return Array(items[(start + 1)...].prefix { !$0.isSeparatorItem })
    }

    private static func disabledDictation() -> DictationController {
        DictationController(enabled: false, engine: ControlledDictationEngine(),
                            recorder: ControlledDictationRecorder(),
                            interaction: DictationInteraction(endCapture: {}, showError: { _ in },
                                                              showResult: { _ in }),
                            saveModel: { _ in })
    }
}
