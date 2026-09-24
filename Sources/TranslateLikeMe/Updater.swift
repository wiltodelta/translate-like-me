import AppKit
import Observation
import Sparkle

// Twin of watch-me-sleep's Updater.swift (same Sparkle setup, different
// observation wrapper); keep the two in step.
//
// In-place updates through Sparkle: it reads the appcast each release publishes
// (SUFeedURL in Info.plist), checks once a day, verifies the EdDSA signature
// (SUPublicEDKey) and installs the new build on request.
//
// The app lives in the menu bar, so a scheduled check must not steal focus while
// the user is typing in another app (Sparkle's "gentle reminders"): a found
// update is announced by the status menu's update item instead, and Sparkle's
// window comes forward only when the user chooses it or checks by hand.
@MainActor
@Observable
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updater()

    // The version a scheduled check found and the user has not acted on yet.
    private(set) var pendingVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!

    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    override private init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                  userDriverDelegate: self)
    }

    // Starts the scheduled checks; call once at launch.
    func start() {
        _ = controller
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    // A user-initiated check, or bringing forward the update a scheduled check
    // found; Sparkle shows its own progress and result window.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Show Sparkle's window only if the app is already in front (the user
        // is in Settings); otherwise the menu item announces it.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        let announce = !handleShowingUpdate && !state.userInitiated
        MainActor.assumeIsolated { pendingVersion = announce ? version : nil }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { pendingVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { pendingVersion = nil }
    }
}
