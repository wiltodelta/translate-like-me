import AppKit
import ApplicationServices
import Observation
import os
import Sparkle
import SwiftUI
import TranslateLikeMeBridgeKit

private let bridgeAppLog = Logger.app("bridge")

@main
struct TranslateLikeMeBridgeApp: App {
    @NSApplicationDelegateAdaptor(BridgeAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
@Observable
final class BridgeSetupModel {
    var accessibilityTrusted = AXIsProcessTrusted()
    var launchAtLogin = ServiceLoginItem.isEnabled
    var loginItemError: String?
    var connectedClients = 0

    func refresh() {
        accessibilityTrusted = AXIsProcessTrusted()
        launchAtLogin = ServiceLoginItem.isEnabled
    }

    func grantAccessibility() {
        SelectionService.openAccessibilitySettings()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if try ServiceLoginItem.update(enabled) {
                loginItemError = String(localized: """
                    Allow Translate Like Me Bridge in System Settings > General > Login Items & Extensions.
                    """)
            } else {
                loginItemError = nil
            }
        } catch {
            bridgeAppLog.error("Bridge login item update failed: \(error.localizedDescription, privacy: .public)")
            loginItemError = error.localizedDescription
        }
        launchAtLogin = ServiceLoginItem.isEnabled
    }
}

@MainActor
final class BridgeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                               SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private let model = BridgeSetupModel()
    private var coordinator: BridgeHostCoordinator?
    private var server: BridgeServer?
    private var window: NSWindow?
    private var pollTimer: Timer?
    private var trustCheckTask: Task<Void, Never>?
    private var distributedObserver: NSObjectProtocol?
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstance() {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        registerLoginItemOnFirstRun()
        startServer()
        startUpdaterIfConfigured()
        startTrustMonitor()
        if !model.accessibilityTrusted {
            showSetupWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetupWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        trustCheckTask?.cancel()
        pollTimer?.invalidate()
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
        server?.stop()
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === window {
            pollTimer?.invalidate()
            pollTimer = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func activateExistingInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != currentPID }) else {
            return false
        }
        other.activate()
        return true
    }

    private func registerLoginItemOnFirstRun() {
        let key = "didRegisterBridgeLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        _ = try? ServiceLoginItem.update(true)
        model.launchAtLogin = ServiceLoginItem.isEnabled
    }

    private func startServer() {
        let host = BridgeHostCoordinator()
        let socketURL = BridgeConfig.defaultSocketURL()
        let ipcServer = BridgeServer(
            socketURL: socketURL,
            policy: .production,
            onClientCountChanged: { [weak self] count in
                Task { @MainActor in self?.model.connectedClients = count }
            },
            onClientDisconnected: { [weak host] clientID in
                Task { @MainActor in host?.clientDisconnected(clientID) }
            },
            onRequest: { [weak host] clientID, request in
                guard let host else { return .ack }
                return await host.handle(clientID: clientID, request: request)
            }
        )
        host.sendEvent = { [weak ipcServer] event in
            ipcServer?.broadcast(event)
        }
        coordinator = host
        server = ipcServer
        if ipcServer.start() {
            bridgeAppLog.notice("Bridge listening at \(socketURL.path, privacy: .public)")
        }
    }

    private func startUpdaterIfConfigured() {
        guard let feed = Bundle.main.infoDictionary?["SUFeedURL"] as? String, !feed.isEmpty else { return }
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                         userDriverDelegate: self)
    }

    private func startTrustMonitor() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.window?.isVisible == true {
                    self.model.launchAtLogin = ServiceLoginItem.isEnabled
                }
                self.checkTrustChange()
            }
        }
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCoalescedTrustCheck() }
        }
    }

    private func scheduleCoalescedTrustCheck() {
        trustCheckTask?.cancel()
        trustCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.checkTrustChange()
        }
    }

    private func checkTrustChange() {
        let wasTrusted = model.accessibilityTrusted
        let trusted = AXIsProcessTrusted()
        model.accessibilityTrusted = trusted
        updateFallbackPollTimer()
        if trusted != wasTrusted {
            coordinator?.broadcastTrustIfChanged(trusted)
        }
    }

    private func updateFallbackPollTimer() {
        let shouldPoll = window?.isVisible == true && !model.accessibilityTrusted
        if shouldPoll, pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkTrustChange() }
            }
        } else if !shouldPoll {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func showSetupWindow() {
        model.refresh()
        if window == nil {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.title = "Translate Like Me Bridge"
            created.contentView = NSHostingView(rootView: BridgeSetupView(model: model) { [weak created] in
                created?.close()
            })
            created.center()
            window = created
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        updateFallbackPollTimer()
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }
}
