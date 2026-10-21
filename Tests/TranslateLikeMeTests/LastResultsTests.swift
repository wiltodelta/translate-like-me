import AppKit
import XCTest
@testable import TranslateLikeMe

@MainActor
final class LastResultsTests: XCTestCase {
    func testMenuKeepsMissingResultsVisibleAndCopiesEachActionIndependently() {
        _ = NSApplication.shared
        let results = LastResults()
        var copied: [String] = []
        let menu = StatusMenu(results: results, copyResult: { copied.append($0) })
        let empty = menu.lastResultsItem()
        XCTAssertTrue(empty.isEnabled)
        XCTAssertEqual(empty.submenu?.items.map(\.isEnabled), [false, false, false])
        results.record("Перевод", kind: .translation)
        results.record("Rewritten message", kind: .message)
        results.record("Spoken notes", kind: .dictation)
        results.record("New translation", kind: .translation)
        let rows = menu.lastResultsItem().submenu!.items
        XCTAssertEqual(rows.map(\.title), ["Translation", "Rewrite", "Dictation"])
        XCTAssertEqual(rows.map(\.isEnabled), [true, true, true])
        for row in rows {
            XCTAssertTrue(NSApp.sendAction(row.action!, to: row.target, from: row))
        }
        XCTAssertEqual(copied, ["New translation", "Rewritten message", "Spoken notes"])
        results.record(" \n", kind: .translation)
        XCTAssertEqual(results[.translation], "New translation")
        XCTAssertNil(LastResults()[.translation], "A new session has no persisted results")
    }

    func testPartialMenuDoesNotDependOnDictationBeingEnabled() {
        let results = LastResults()
        results.record("Translation only", kind: .translation)
        let menu = StatusMenu(results: results, copyResult: { _ in })
        XCTAssertEqual(menu.lastResultsItem().submenu?.items.map(\.isEnabled), [true, false, false])
    }
}
