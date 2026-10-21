import AppKit
import SwiftUI
import XCTest
@testable import TranslateLikeMe

@MainActor
final class SettingsPaneTests: XCTestCase {
    func testPaneIdentitiesSurviveToolbarReordering() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "settingsSelectedPane")
        defer { defaults.set(saved, forKey: "settingsSelectedPane") }
        let (window, tabs) = SettingsTabViewController.makeWindow(
            store: SettingsStore(refreshCatalog: { _ in }),
            generalContent: AnyView(Text("Synthetic general settings")))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let names = [String(localized: "General"), String(localized: "Dictation"),
                     String(localized: "Translation"), String(localized: "Rewrite")]
        XCTAssertEqual(tabs.tabViewItems.map(\.label), names)
        for (pane, title) in [(SettingsPane.general, names[0]), (.dictation, names[1]),
                              (.translation, names[2]), (.rewrite, names[3])] {
            tabs.select(pane)
            XCTAssertEqual(tabs.tabView.selectedTabViewItem?.label, title)
            XCTAssertEqual(defaults.integer(forKey: "settingsSelectedPane"), pane.rawValue)
            defaults.set(pane.rawValue, forKey: "settingsSelectedPane")
            tabs.select(nil)
            XCTAssertEqual(tabs.tabView.selectedTabViewItem?.label, title)
        }
    }
}
