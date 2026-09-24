import AppKit
import SwiftUI
import ApplicationServices

// Owns the AppKit pieces: the status-bar item and its menu (StatusMenu), global
// hotkeys (Carbon), the Accessibility prompt, and the settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem!
    private let statusMenu = StatusMenu()
    private var settingsWindow: NSWindow?
    private var settingsTabs: SettingsTabViewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Before anything reads the pairs, and before the first-run flag below,
        // which the migration reads as "an earlier version ran here".
        Settings.persistLanguagePairs()

        setUpStatusItem()

        // Swap the icon when a translation starts or finishes.
        NotificationCenter.default.addObserver(
            forName: .translationActivityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }

        // Posted by the status menu and the popup's Open Settings action.
        NotificationCenter.default.addObserver(
            forName: .openSettings, object: nil, queue: .main
        ) { [weak self] note in
            let pane = note.object as? SettingsPane
            MainActor.assumeIsolated { self?.showSettings(pane: pane) }
        }

        registerHotKeys()
        ensureAccessibilityPermission()
        openSettingsOnFirstRun()
        checkForUpdatesOnLaunch()
    }

    // A short delay keeps launch snappy and avoids a modal racing the first-run
    // Settings window. Silent when already on the latest version.
    private func checkForUpdatesOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            UpdateChecker.shared.checkForUpdates()
        }
    }

    // On the very first launch, open Settings on the Translation pane so the
    // user picks an engine before using the hotkeys.
    private func openSettingsOnFirstRun() {
        guard !Settings.didCompleteFirstRun else { return }
        Settings.didCompleteFirstRun = true
        DispatchQueue.main.async { [weak self] in self?.showSettings(pane: .translation) }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.setAccessibilityLabel("Translate Like Me")
        statusItem.menu = statusMenu.menu
        updateStatusItem()
    }

    // Template images tint themselves for the light/dark menu bar.
    private func updateStatusItem() {
        statusItem.button?.image = TranslationActivity.shared.isBusy
            ? MenuBarIcon.busyImage
            : MenuBarIcon.image
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        HotKeyManager.shared.reload()
    }

    // MARK: - Settings window

    // `pane` is the pane to show, or nil for the last viewed one.
    func showSettings(pane: SettingsPane? = nil) {
        if settingsWindow == nil {
            let (window, tabs) = SettingsTabViewController.makeWindow()
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
            settingsTabs = tabs
        }
        settingsTabs?.select(pane)
        // An accessory app must briefly become regular to show and focus a window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Accessibility

    private func ensureAccessibilityPermission() {
        // Triggers the system Accessibility prompt when not yet trusted. Kept
        // non-blocking: a modal here would stall app launch (and the status item)
        // until dismissed. The status menu surfaces the same need.
        SelectionService.promptForAccessibility()
    }
}
