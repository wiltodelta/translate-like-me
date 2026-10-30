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
    private var engineStatus: (engine: Provider, readiness: EngineStatus.Readiness)?
    private var engineCheck: Task<Void, Never>?
    private weak var engineItem: NSMenuItem?

    private let results: LastResults
    private let dictation: () -> DictationController
    // Read lazily: touching Updater starts Sparkle, which alerts without an app bundle.
    private let pendingUpdate: () -> String?
    private let copyResult: (String) -> Void

    init(results: LastResults = .shared, dictation: @escaping () -> DictationController = { .shared },
         pendingUpdate: @escaping () -> String? = { Updater.shared.pendingVersion },
         copyResult: @escaping (String) -> Void = { SelectionService.copyToClipboard($0) }) {
        self.results = results
        self.dictation = dictation
        self.pendingUpdate = pendingUpdate
        self.copyResult = copyResult
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
        refreshEngine()
    }

    func rebuild() {
        menu.removeAllItems()

        // One status row per thing setup prepares (onboarding's models and
        // permissions), titled by the feature it serves.
        let dictation = dictation()
        menu.addItem(.sectionHeader(title: String(localized: "Status")))
        menu.addItem(dictationStatusItem(dictation))
        let engine = item(String(localized: "Translation"), action: #selector(openEngineSettings))
        engineItem = engine
        applyEngineStatus(to: engine)
        menu.addItem(engine)
        menu.addItem(accessibilityItem())

        // The features in the order they chain, as the README and onboarding
        // tell them: dictate, polish the notes, translate the message.
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "Dictate at cursor")))
        menu.addItem(dictateItem(dictation))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "Rewrite selection")))
        let presets = Settings.rewritePresets
        for preset in presets { menu.addItem(rewriteItem(preset)) }
        if presets.isEmpty {
            menu.addItem(item(String(localized: "Add a Rewrite Preset…"), action: #selector(openRewriteSettings)))
        }

        // The app's key action: one item per language pair, showing its shortcut.
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "Translate selection")))
        let pairs = Settings.languagePairs
        for pair in pairs {
            let shared = pairs.contains { $0.id != pair.id && $0.first == pair.first && $0.second == pair.second }
            menu.addItem(translateItem(pair, showsStyle: shared))
        }
        if pairs.isEmpty {
            menu.addItem(item(String(localized: "Add a Language Pair…"), action: #selector(openLanguageSettings)))
        }

        menu.addItem(.separator())
        menu.addItem(lastResultsItem())

        // macOS 26 gives Settings… its standard gear icon, so its group gets an
        // icon on every item (HIG: uniform treatment within a group).
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Settings…"), key: ",", action: #selector(openSettings)))
        menu.addItem(updatesItem())

        // The standard terminate(_:) selector, so the system treats it as Quit.
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit Translate Like Me"),
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
        let engine = Settings.provider
        engineCheck = Task {
            let result = await EngineStatus.check(provider: engine)
            guard !Task.isCancelled else { return }
            engineStatus = (engine, result)
            if let engineItem { applyEngineStatus(to: engineItem) }
        }
    }

    // The subtitle carries the engine and its state or, when something is wrong,
    // the fix. The row stays enabled (full-contrast text) and opens the
    // Translation pane, where the engine is chosen; Rewrite runs on it too.
    private func applyEngineStatus(to item: NSMenuItem) {
        let provider = Settings.provider
        let symbol: String
        let detail: String
        let readiness = engineStatus?.engine == provider ? engineStatus?.readiness : nil
        switch readiness {
        case .ready:
            symbol = "checkmark.circle"
            detail = Self.status(provider.name, EngineStatus.readyText)
        case .notLoggedIn:
            symbol = "exclamationmark.triangle"
            detail = provider.notSignedInHint
        case .notInstalled:
            symbol = "exclamationmark.triangle"
            detail = provider.notInstalledHint
        case .failed(let message):
            symbol = "exclamationmark.triangle"
            detail = message
        case .none:
            symbol = "circle.dotted"
            detail = Self.status(provider.name, EngineStatus.checkingText)
        }
        item.subtitle = detail
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        showsImage(item)
    }

    // A ready or pending row names what serves the feature; a problem row's
    // sentence already does.
    private static func status(_ name: String, _ state: String) -> String {
        String(localized: "\(name) · \(state)",
               comment: "Menu status subtitle: an engine or model name, then its state, such as Ready")
    }

    // Opens the Dictation pane, where dictation is turned on, its model chosen
    // and a failed setup retried.
    private func dictationStatusItem(_ dictation: DictationController) -> NSMenuItem {
        let item = self.item(String(localized: "Dictation"), action: #selector(openDictationSettings))
        let model = dictation.model.title
        let (symbol, subtitle): (String, String) = if !dictation.enabled {
            ("minus.circle", String(localized: "Off", comment: "Dictation status in the menu"))
        } else {
            switch dictation.phase {
            case .failed:
                ("exclamationmark.triangle", dictation.error ?? String(localized: "Dictation is not ready."))
            // Enabled but not loaded yet: launch restores it right away.
            case .disabled, .preparing: ("circle.dotted", Self.status(model, String(localized: "Preparing…")))
            default: ("checkmark.circle", Self.status(model, EngineStatus.readyText))
            }
        }
        item.subtitle = subtitle
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        showsImage(item)
        return item
    }

    // macOS 27 hides menu item images unless an item asks for them (NSMenuItem
    // .preferredImageVisibility). These symbols carry state (ready, warning, update
    // found), and Settings… keeps its system gear, so a hidden image left a warning
    // with no sign and a group with one icon (HIG Menus: all or none in a group).
    // Set through the Objective-C runtime: the property exists from the macOS 27 SDK
    // on, and CI still builds with an older one. 1 is NSMenuItemImageVisibilityVisible
    // (AppKit NSMenuItem.h); on earlier systems the item has no such property and
    // shows its image anyway.
    private func showsImage(_ item: NSMenuItem) {
        guard item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) else { return }
        item.setValue(1, forKey: "preferredImageVisibility")
    }

    // Enabled only while access is missing: it is the way to grant it.
    private func accessibilityItem() -> NSMenuItem {
        let trusted = AXIsProcessTrusted()
        let item = self.item(trusted ? String(localized: "Accessibility", comment: "The macOS permission")
                                : String(localized: "Allow Accessibility Access…"),
                             action: #selector(requestAccessibility))
        item.subtitle = trusted ? String(localized: "Allowed", comment: "Accessibility permission status")
            : String(localized: "Needed to copy and replace the selection")
        item.image = NSImage(systemSymbolName: trusted ? "checkmark.circle" : "exclamationmark.triangle",
                             accessibilityDescription: nil)
        item.isEnabled = !trusted
        showsImage(item)
        return item
    }

    // MARK: - Commands

    // Carries the pair's id; the pair is looked up when chosen. Pairs that share
    // languages are told apart by whether they apply a style.
    private func translateItem(_ pair: LanguagePair, showsStyle: Bool) -> NSMenuItem {
        let item = self.item(pair.title, action: #selector(translateSelection(_:)))
        item.representedObject = pair.id
        if !pair.isComplete {
            // Opens General > Languages, where the language is chosen.
            item.action = #selector(openLanguageSettings)
            item.subtitle = String(localized: "Choose the second language in Settings")
        } else if showsStyle {
            item.subtitle = pair.trimmedStyle.isEmpty ? String(localized: "Plain translation")
                : String(localized: "In your writing style")
        }
        show(pair.shortcut, on: item)
        return item
    }

    private func rewriteItem(_ preset: RewritePreset) -> NSMenuItem {
        let item = self.item(preset.title, action: #selector(rewriteSelection(_:)))
        item.representedObject = preset.id
        show(preset.shortcut, on: item)
        return item
    }

    // The global shortcut, shown as the item's key equivalent.
    private func show(_ shortcut: KeyCombo?, on item: NSMenuItem) {
        if let shortcut, Shortcut.isOptionOnly(shortcut) {
            item.subtitle = Shortcut.display(shortcut)
            return
        }
        guard let equivalent = shortcut.flatMap(Shortcut.menuKeyEquivalent) else { return }
        item.keyEquivalent = equivalent.key
        item.keyEquivalentModifierMask = equivalent.flags
    }

    @objc private func rewriteSelection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let preset = Settings.rewritePreset(id: id) else { return }
        TranslationController.shared.rewrite(preset: preset)
    }

    @objc private func translateSelection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let pair = Settings.languagePair(id: id) else { return }
        TranslationController.shared.run(pair: pair)
    }

    // Dictation starts only from its hold key, so once set up the row is a
    // dimmed reminder of that key (Status tells whether the model is ready);
    // the other states offer the next step.
    private func dictateItem(_ dictation: DictationController) -> NSMenuItem {
        if dictation.isActive {
            return item(String(localized: "Cancel Dictation"), action: #selector(cancelDictation))
        }
        let shortcut = Settings.dictationShortcut
        if dictation.enabled, dictation.phase != .failed, let shortcut {
            let hint = item(String(localized: "Hold \(Shortcut.display(shortcut)) to dictate",
                                   comment: "Menu item; the placeholder is a key, such as Right Option"),
                            action: #selector(openDictationSettings))
            hint.isEnabled = false
            return hint
        }
        let title = !dictation.enabled ? String(localized: "Set Up Dictation…")
            : dictation.phase == .failed ? String(localized: "Finish Dictation Setup…")
            : String(localized: "Set Dictation Shortcut…")
        return item(title, action: #selector(openDictationSettings))
    }

    @objc private func cancelDictation() { dictation().cancel() }

    // Always show all three actions so availability never changes their order.
    func lastResultsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: String(localized: "Copy Last Result"), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        showsImage(parent)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for kind in PopupController.ResultKind.allCases {
            let row = item(kind.copyTitle, action: #selector(copyLastResult(_:)))
            row.representedObject = kind
            row.isEnabled = results[kind] != nil
            submenu.addItem(row)
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func copyLastResult(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? PopupController.ResultKind,
              let text = results[kind] else { return }
        copyResult(text)
    }

    @objc private func requestAccessibility() { SelectionService.promptForAccessibility() }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }

    @objc private func openLanguageSettings() {
        NotificationCenter.default.post(name: .openSettings, object: SettingsPane.general)
    }

    @objc private func openDictationSettings() {
        NotificationCenter.default.post(name: .openSettings, object: SettingsPane.dictation)
    }

    @objc private func openRewriteSettings() {
        NotificationCenter.default.post(name: .openSettings, object: SettingsPane.rewrite)
    }

    @objc private func openEngineSettings() {
        NotificationCenter.default.post(name: .openSettings, object: SettingsPane.translation)
    }

    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }

    // Also the gentle reminder for an update a scheduled check found (Updater):
    // the title changes rather than a window taking focus.
    private func updatesItem() -> NSMenuItem {
        let pending = pendingUpdate()
        let title = pending == nil ? String(localized: "Check for Updates…") : String(localized: "Install Update…")
        let updates = item(title, action: #selector(checkForUpdates))
        updates.subtitle = pending.map { String(localized: "Version \($0) is available") }
        updates.image = NSImage(systemSymbolName: pending == nil ? "arrow.triangle.2.circlepath"
                                    : "arrow.down.circle", accessibilityDescription: nil)
        showsImage(updates)
        return updates
    }
}
