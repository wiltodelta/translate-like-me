import AppKit
import SwiftUI

enum SettingsPane: Int {
    case general
    case translation
    case rewrite
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
    static func makeWindow(store: SettingsStore) -> (window: NSWindow, tabs: SettingsTabViewController) {
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addPane("General", symbol: "gearshape", GeneralSettingsView(store: store))
        tabs.addPane("Translation", symbol: "translate", TranslationSettingsView(store: store))
        tabs.addPane("Rewrite", symbol: "text.bubble", RewriteSettingsView(store: store))
        let window = SettingsWindow(contentViewController: tabs)
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

    // Shows `pane`, or the last viewed one when nil. Restoring the last pane is
    // not a choice, so it is not written back: capture-screenshots.sh passes it
    // for one launch, and the write put that pane into the real settings.
    func select(_ pane: SettingsPane?) {
        let index = pane?.rawValue ?? UserDefaults.standard.integer(forKey: Self.lastPaneKey)
        let records = recordsSelection
        recordsSelection = pane != nil && records
        selectedTabViewItemIndex = min(max(index, 0), tabViewItems.count - 1)
        recordsSelection = records
        clearFocus()
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if recordsSelection {
            UserDefaults.standard.set(selectedTabViewItemIndex, forKey: Self.lastPaneKey)
        }
        clearFocus()
    }

    // AppKit gives a pane's first text field the focus, and the Rewrite pane's
    // first is a preset's name: opened with its text selected, the next key
    // typed renamed the preset. Nothing is focused until clicked or tabbed to.
    // Async, because the window picks its first responder after this returns.
    private func clearFocus() {
        DispatchQueue.main.async { [weak self] in self?.view.window?.makeFirstResponder(nil) }
    }
}

// The settings window grows downward from where it was centred whenever its pane
// grows (another language pair, a switch to a taller pane),
// which put its bottom under the Dock. Every frame it is given, the tab
// controller's animation steps included, is kept inside the screen's visible
// frame by moving it up. Correcting after the animation instead was measured
// racy: one run in three still ended 6 pt under the Dock.
final class SettingsWindow: NSWindow {
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(keptOnScreen(frameRect), display: flag)
    }

    private func keptOnScreen(_ rect: NSRect) -> NSRect {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return rect }
        var kept = rect
        // Bottom above the Dock, then top below the menu bar, which wins for a
        // window taller than the visible frame.
        kept.origin.y = min(max(rect.minY, visible.minY), visible.maxY - rect.height)
        return kept
    }
}
