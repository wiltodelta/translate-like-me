import Carbon
import Foundation
import os

private let log = Logger.app("hotkey")

// Registers global hotkeys via the Carbon Event Manager. RegisterEventHotKey is the
// reliable way to get system-wide hotkeys for a background (accessory) app.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {}

    // (Re)registers one hotkey per language pair, then per Rewrite preset, that
    // has a shortcut. Call after launch and whenever either list changes. A
    // combo is registered once even if stored entries repeat it (the recorder
    // refuses that, a hand edit may not); a pair wins over a preset.
    func reload(pairs: [LanguagePair] = Settings.languagePairs,
                presets: [RewritePreset] = Settings.rewritePresets) {
        unregisterAll()
        // Each entry is looked up at fire time, so a run uses it as it is now.
        let entries: [(KeyCombo?, @MainActor () -> Void)] = pairs.map { pair in
            (pair.shortcut, { @MainActor [id = pair.id] in
                if let pair = Settings.languagePair(id: id) { TranslationController.shared.run(pair: pair) }
            })
        } + presets.map { preset in
            (preset.shortcut, { @MainActor [id = preset.id] in
                if let preset = Settings.rewritePreset(id: id) { TranslationController.shared.rewrite(preset: preset) }
            })
        }
        var registered: [KeyCombo] = []
        for case let (combo?, action) in entries where !registered.contains(combo) {
            registered.append(combo)
            register(keyCode: UInt32(combo.keyCode), modifiers: UInt32(combo.modifiers), action: action)
        }
    }

    // Hotkeys are registered on the app's own event target, so the CURRENTLY
    // active combo is intercepted there before a local NSEvent monitor (e.g. the
    // shortcut recorder in Settings) ever sees it - trying to "re-enter" the
    // shortcut that's already active would silently fire it instead of being
    // captured. Call pause() before recording a new shortcut, resume() after.
    func pause() {
        unregisterAll()
    }

    func resume() {
        reload()
    }

    private func unregisterAll() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        actions.removeAll()
        nextID = 1
    }

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        actions[id] = action

        let hotKeyID = EventHotKeyID(signature: OSType(0x544C_4D45), id: id) // 'TLME'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs.append(ref)
        } else {
            log.error("Failed to register hotkey \(keyCode) \(modifiers): status \(status)")
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotKeyID)
            // Handlers on the application event target run on the main thread.
            MainActor.assumeIsolated { HotKeyManager.shared.fire(id: hotKeyID.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(id: UInt32) {
        actions[id]?()
    }
}
