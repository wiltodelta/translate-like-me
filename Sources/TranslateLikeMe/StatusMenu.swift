import AppKit
import ApplicationServices

// The status item's menu. The HIG's menu bar extras guidance is "display a menu -
// not a popover - when people click your menu bar extra", so both clicks open this
// standard NSMenu, which the system draws with its own material, appearance and
// accessibility. It is rebuilt each time it opens, so it always reflects Settings,
// and it keeps the same set of items in every state (status rows change their text,
// they never disappear). The engine check runs off the main thread and updates its
// row in place while the menu is open.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()

    // The last check, tagged with the engine it was made for, so a result for
    // the previous engine is never shown after switching in Settings.
    private var engineStatus: (engine: String, readiness: EngineStatus.Readiness)?
    private var engineCheck: Task<Void, Never>?
    private weak var engineItem: NSMenuItem?

    private var currentEngine: String {
        "\(Settings.provider.rawValue)|\(Settings.effectiveAuthMode.rawValue)"
    }

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
        refreshEngine()
    }

    private func rebuild() {
        menu.removeAllItems()

        menu.addItem(.sectionHeader(title: "Status"))
        let engine = item("", action: #selector(openEngineSettings))
        engineItem = engine
        applyEngineStatus(to: engine)
        menu.addItem(engine)
        menu.addItem(accessibilityItem())

        // The app's key action: one item per language pair, showing its shortcut.
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Translate Selection"))
        for pair in Settings.languagePairs {
            menu.addItem(translateItem(pair))
        }

        // macOS 26 gives Settings… its standard gear icon, so its group gets an
        // icon on every item (HIG: uniform treatment within a group).
        menu.addItem(.separator())
        menu.addItem(item("Settings…", key: ",", action: #selector(openSettings)))
        let updates = item("Check for Updates…", action: #selector(checkForUpdates))
        updates.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        menu.addItem(updates)

        // The standard terminate(_:) selector, so the system treats it as Quit.
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Translate Like Me",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, key: String = "", action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Status

    private func refreshEngine() {
        engineCheck?.cancel()
        let engine = currentEngine
        engineCheck = Task {
            let result = await Task.detached { EngineStatus.check() }.value
            guard !Task.isCancelled else { return }
            engineStatus = (engine, result)
            if let engineItem { applyEngineStatus(to: engineItem) }
        }
    }

    // The subtitle carries the state and, when something is wrong, the fix. The
    // row stays enabled (full-contrast text) and opens the Translation pane,
    // where the engine is chosen.
    private func applyEngineStatus(to item: NSMenuItem) {
        let provider = Settings.provider
        let symbol: String
        let detail: String
        let readiness = engineStatus?.engine == currentEngine ? engineStatus?.readiness : nil
        switch readiness {
        case .ready:
            symbol = "checkmark.circle"
            detail = Settings.effectiveAuthMode == .subscription
                ? "Ready, using your subscription" : "Ready, using your API key"
        case .notLoggedIn(let service):
            symbol = "exclamationmark.triangle"
            detail = "Not signed in to \(service). Run \(provider.loginCommand) in Terminal."
        case .notInstalled(let cli):
            symbol = "exclamationmark.triangle"
            detail = "The \(cli) command-line tool was not found."
        case .noKey:
            symbol = "exclamationmark.triangle"
            detail = "No API key yet. Add it in Settings."
        case .none:
            symbol = "circle.dotted"
            detail = "Checking…"
        }
        item.title = provider.shortName
        item.subtitle = detail
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    // Enabled only while access is missing: it is the way to grant it.
    private func accessibilityItem() -> NSMenuItem {
        let trusted = AXIsProcessTrusted()
        let item = self.item(trusted ? "Accessibility" : "Allow Accessibility Access…",
                             action: #selector(requestAccessibility))
        item.subtitle = trusted ? "Allowed" : "Needed to copy and replace the selection"
        item.image = NSImage(systemSymbolName: trusted ? "checkmark.circle" : "exclamationmark.triangle",
                             accessibilityDescription: nil)
        item.isEnabled = !trusted
        return item
    }

    // MARK: - Commands

    // Carries the pair's id; the pair is looked up when chosen.
    private func translateItem(_ pair: LanguagePair) -> NSMenuItem {
        let item = self.item(pair.title, action: #selector(translateSelection(_:)))
        item.representedObject = pair.id
        if let equivalent = pair.shortcut.flatMap(Shortcut.menuKeyEquivalent) {
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.flags
        }
        return item
    }

    @objc private func translateSelection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let pair = Settings.languagePair(id: id) else { return }
        TranslationController.shared.run(pair: pair)
    }

    @objc private func requestAccessibility() { SelectionService.promptForAccessibility() }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }

    @objc private func openEngineSettings() {
        NotificationCenter.default.post(name: .openSettings, object: SettingsPane.translation)
    }

    @objc private func checkForUpdates() { UpdateChecker.shared.checkForUpdates(manual: true) }
}
