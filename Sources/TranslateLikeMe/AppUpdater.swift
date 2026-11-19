import AppKit
import Foundation
import Observation

// Edition-aware wrapper around Updater so Updater.swift stays byte-for-byte
// shared with watch-me-sleep and rota, while Mac App Store builds omit Sparkle.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    #if canImport(Sparkle)
    private var sparkle: Updater? { AppEdition.current.supportsSelfUpdate ? .shared : nil }
    // Read AppEdition directly without touching Updater.shared: StatusMenu's
    // default showsUpdates evaluates this in xctest, where starting Sparkle
    // raises a modal SUFeedURL alert during later tests.
    var isAvailable: Bool { AppEdition.current.supportsSelfUpdate }
    var pendingVersion: String? { sparkle?.pendingVersion }
    var automaticallyChecks: Bool {
        get { sparkle?.automaticallyChecks ?? false }
        set { sparkle?.automaticallyChecks = newValue }
    }
    func start() { sparkle?.start() }
    func checkForUpdates() { sparkle?.checkForUpdates() }
    #else
    var isAvailable: Bool { false }
    var pendingVersion: String? { nil }
    var automaticallyChecks: Bool {
        get { false }
        set { _ = newValue }
    }
    func start() {}
    func checkForUpdates() {}
    #endif
}
