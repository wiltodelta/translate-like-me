import AppKit
import SwiftUI
import ApplicationServices

// Owns the AppKit pieces: the status-bar item and its click-through panel, the
// right-click quick menu, global hotkeys (Carbon), the Accessibility prompt, and
// the settings window.
//
// A custom NSStatusItem is used instead of SwiftUI's MenuBarExtra because
// MenuBarExtra cannot show a separate context menu on a right-click - the status
// item swallows the click to open its window. With a plain NSStatusItem a left
// click opens the panel and a right click pops up an NSMenu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var panel: MenuBarPanelController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        setUpStatusItem()
        panel = MenuBarPanelController(rootView: MenuContentView(),
                                       size: NSSize(width: 320, height: 420))

        // Swap the icon when a translation starts or finishes.
        NotificationCenter.default.addObserver(
            forName: .translationActivityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }

        // The panel posts this instead of dismissing itself (there is no
        // MenuBarExtra dismiss now); showSettings() closes the panel first.
        NotificationCenter.default.addObserver(
            forName: .openSettings, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings() }
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

    // On the very first launch, open Settings so the user picks a provider and
    // languages before using the hotkeys.
    private func openSettingsOnFirstRun() {
        let key = "didCompleteFirstRun"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.async { [weak self] in self?.showSettings() }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePanel)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItem()
    }

    // Template images tint themselves for the light/dark menu bar.
    private func updateStatusItem() {
        statusItem.button?.image = TranslationActivity.shared.isBusy
            ? MenuBarIcon.busyImage
            : MenuBarIcon.image
    }

    @objc private func togglePanel() {
        // Right-click shows the quick menu instead of the panel.
        if NSApp.currentEvent?.type == .rightMouseUp {
            panel.close()
            showQuickMenu()
            return
        }
        guard let button = statusItem.button else { return }
        if panel.isShown {
            panel.close()
        } else {
            panel.show(relativeTo: button)
        }
    }

    // MARK: - Right-click quick menu

    private func showQuickMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettingsFromMenu),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Translate Like Me", action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func showSettingsFromMenu() { showSettings() }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        HotKeyManager.shared.reload()
    }

    // MARK: - Settings window (SwiftUI content hosted in an AppKit window)

    func showSettings() {
        // Close the dropdown so it doesn't linger behind the settings window.
        panel?.close()

        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Translate Like Me — Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        // An accessory app must briefly become regular to show and focus a window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func closeSettings() {
        settingsWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Accessibility

    private func ensureAccessibilityPermission() {
        // Triggers the system Accessibility prompt when not yet trusted. Kept
        // non-blocking: a modal here would stall app launch (and the status item)
        // until dismissed. The panel's Status card surfaces the same need.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
