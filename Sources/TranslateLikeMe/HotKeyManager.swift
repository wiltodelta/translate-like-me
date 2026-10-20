import AppKit
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
    private var refs: [EventHotKeyRef] = []
    // Never reuse an id: a queued event from a removed shortcut
    // registration must not run a different action after reload.
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private var paused = false
    private var optionGesture: OptionKeyGesture?
    private var optionMonitors: [Any] = []
    private var optionMonitorID: UUID?

    private init() {}

    // (Re)registers one hotkey per language pair, then per Rewrite preset, that
    // has a shortcut. Call after launch and whenever either list changes. A
    // combo is registered once even if stored entries repeat it (the recorder
    // refuses that, a hand edit may not); a pair wins over a preset.
    func reload(pairs: [LanguagePair] = Settings.languagePairs,
                presets: [RewritePreset] = Settings.rewritePresets) {
        unregisterAll()
        guard !paused else { return }
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
        if Settings.dictationEnabled, let combo = Settings.dictationShortcut {
            registered.append(combo)
            if Shortcut.isOptionOnly(combo) {
                monitorOption(keyCode: combo.keyCode)
            }
        }
        for case let (combo?, action) in entries where !registered.contains(combo) {
            registered.append(combo)
            register(keyCode: UInt32(combo.keyCode), modifiers: UInt32(combo.modifiers), action: action)
        }
        log.notice("Shortcuts registered: \(self.refs.count), Accessibility \(AXIsProcessTrusted())")
    }

    // Hotkeys are registered on the app's own event target, so the CURRENTLY
    // active combo is intercepted there before a local NSEvent monitor (e.g. the
    // shortcut recorder in Settings) ever sees it - trying to "re-enter" the
    // shortcut that's already active would silently fire it instead of being
    // captured. Call pause() before recording a new shortcut, resume() after.
    func pause() {
        paused = true
        unregisterAll()
    }

    func resume() {
        paused = false
        reload()
    }

    private func unregisterAll() {
        let cancelled = optionGesture?.cancel() == .cancel
        optionMonitorID = nil
        for monitor in optionMonitors { NSEvent.removeMonitor(monitor) }
        optionMonitors.removeAll()
        optionGesture = nil
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
        if cancelled {
            log.notice("Dictation hold cancelled by shortcut reload")
            DictationController.shared.shortcutCancelled()
        }
    }

    private func monitorOption(keyCode: Int) {
        let id = UUID()
        optionMonitorID = id
        optionGesture = OptionKeyGesture(keyCode: keyCode, initialFlags: NSEvent.modifierFlags)
        let observe: @Sendable (NSEvent) -> Void = { event in
            let changed = event.type == .flagsChanged
            let code = changed ? Int(event.keyCode) : 0
            let flags = event.modifierFlags
            let eventType = event.type.rawValue
            MainActor.assumeIsolated {
                let manager = HotKeyManager.shared
                guard manager.optionMonitorID == id else { return }
                let action = changed
                    ? manager.optionGesture?.flagsChanged(keyCode: code, flags: flags)
                    : manager.optionGesture?.cancel()
                if action == .cancel {
                    // Classify cancellation without logging typed keys or characters.
                    log.notice("Dictation input cancellation: event type \(eventType), modifiers \(flags.rawValue)")
                }
                manager.apply(action)
            }
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: OptionKeyGesture.events, handler: observe)
        if let global {
            optionMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: OptionKeyGesture.events, handler: { event in
            observe(event)
            return event
        }) { optionMonitors.append(local) }
        log.notice("""
            Dictation hold monitor: key \(keyCode), global \(global != nil), monitors \(self.optionMonitors.count)
            """)
    }

    private func apply(_ action: OptionKeyGesture.Action?) {
        switch action {
        case .press: DictationController.shared.shortcutPressed()
        case .release: DictationController.shared.shortcutReleased()
        case .cancel: DictationController.shared.shortcutCancelled()
        case nil: break
        }
    }

    private func register(keyCode: UInt32, modifiers: UInt32,
                          action: @escaping @MainActor () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        actions[id] = action

        let hotKeyID = EventHotKeyID(signature: OSType(0x544C_4D45), id: id) // 'TLME'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
        } else {
            actions.removeValue(forKey: id)
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
        // Carbon consumes our registered combinations before NSEvent monitors
        // receive the key, so explicitly disqualify that Option press too.
        let cancelled = optionGesture?.cancel()
        if cancelled == .cancel { log.notice("Dictation hold cancelled by another registered shortcut") }
        apply(cancelled)
        actions[id]?()
    }
}
