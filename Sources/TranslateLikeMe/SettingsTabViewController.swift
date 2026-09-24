import AppKit
import SwiftUI

enum SettingsPane: Int {
    case general
    case translation
}

// The settings window's pane switcher: an NSTabViewController in toolbar style,
// each pane a SwiftUI view sized to its content, remembering the last pane.
final class SettingsTabViewController: NSTabViewController {
    // capture-screenshots.sh overrides this key by name.
    private static let lastPaneKey = "settingsSelectedPane"

    // Set once the window is built, so the selection the tab controller makes
    // while panes are added is not recorded as the user's choice.
    private var recordsSelection = false

    // HIG (Settings, macOS): panes in a noncustomizable toolbar that always shows
    // the active pane; the window title follows the pane (the tab controller
    // propagates each pane's title).
    static func makeWindow() -> (window: NSWindow, tabs: SettingsTabViewController) {
        let store = SettingsStore()
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addPane("General", symbol: "gearshape", GeneralSettingsView(store: store))
        tabs.addPane("Translation", symbol: "translate", TranslationSettingsView(store: store))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        tabs.recordsSelection = true
        return (window, tabs)
    }

    private func addPane(_ title: String, symbol: String, _ view: some View) {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        hosting.title = title
        let item = NSTabViewItem(viewController: hosting)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        addTabViewItem(item)
    }

    // Shows `pane`, or the last viewed one when nil.
    func select(_ pane: SettingsPane?) {
        let index = pane?.rawValue ?? UserDefaults.standard.integer(forKey: Self.lastPaneKey)
        selectedTabViewItemIndex = min(max(index, 0), tabViewItems.count - 1)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if recordsSelection {
            UserDefaults.standard.set(selectedTabViewItemIndex, forKey: Self.lastPaneKey)
        }
    }
}
