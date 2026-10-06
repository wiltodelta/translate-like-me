import AppKit
import SwiftUI
import ApplicationServices

// Owns the AppKit pieces: the status-bar item and its menu (StatusMenu), global
// hotkeys (Carbon), the Accessibility prompt, and the onboarding and settings
// windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem!
    private let statusMenu = StatusMenu()
    // One model for both windows, so an edit in one shows in the other.
    private lazy var store = SettingsStore()
    private var settingsWindow: NSWindow?
    private var settingsTabs: SettingsTabViewController?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Before anything reads the pairs, and before the first-run flag below,
        // which the migration reads as "an earlier version ran here".
        Settings.persistLanguagePairs()
        Settings.moveStyleIntoPairs()
        Settings.removeAPIKeys()

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
        showOnboardingOnFirstRun()
        Updater.shared.start()
    }

    // Until onboarding has been finished or closed once, it opens at launch: a
    // new user has no language pairs and no engine checked yet.
    private func showOnboardingOnFirstRun() {
        guard !Settings.didCompleteFirstRun else { return }
        DispatchQueue.main.async { [weak self] in self?.showOnboarding() }
    }

    private func showOnboarding() {
        let window = Onboarding.makeWindow(store: store) { [weak self] in
            self?.onboardingWindow?.close()
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        onboardingWindow = window
        show(window)
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
            let (window, tabs) = SettingsTabViewController.makeWindow(store: store)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
            settingsTabs = tabs
        }
        settingsTabs?.select(pane)
        settingsWindow.map(show)
    }

    // An accessory app must briefly become regular to show and focus a window.
    private func show(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // Back to a menu-bar-only app once neither window is open. Closing
    // onboarding, with Done or the close button, finishes it for good.
    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if closing === onboardingWindow {
            Settings.didCompleteFirstRun = true
            onboardingWindow = nil
        }
        let stillOpen = [settingsWindow, onboardingWindow].contains { $0 !== closing && $0?.isVisible == true }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: - Accessibility

    private func ensureAccessibilityPermission() {
        // Triggers the system Accessibility prompt when not yet trusted. Kept
        // non-blocking: a modal here would stall app launch (and the status item)
        // until dismissed. The status menu surfaces the same need.
        SelectionService.promptForAccessibility()
    }
}
