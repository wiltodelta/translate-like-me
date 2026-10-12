import AppKit
import Observation // twin-local
import Sparkle

// twin: updater - translate-like-me, watch-me-sleep and rota keep this file
// identical except lines marked twin-local (claude-config bin/check-twins.py).
//
/// In-place updates through Sparkle: it reads the appcast each release publishes
/// (`SUFeedURL` in Info.plist), checks once a day, verifies the EdDSA signature
/// (`SUPublicEDKey`) and installs the new build on request.
///
/// The app lives in the menu bar, so a scheduled check must not steal focus
/// (Sparkle's gentle reminders): a found update is announced in the app's own
/// menu or panel instead, and Sparkle's window comes forward only when the user
/// chooses it or checks by hand.
@MainActor
@Observable // twin-local
final class Updater: NSObject, SPUStandardUserDriverDelegate { // twin-local
    static let shared = Updater()

    /// The version a scheduled check found and the user has not acted on yet.
    private(set) var pendingVersion: String? // twin-local

    @ObservationIgnored private var controller: SPUStandardUpdaterController! // twin-local

    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    override private init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                  userDriverDelegate: self)
    }

    /// Starts the scheduled checks; call once at launch.
    func start() {
        _ = controller
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// A user-initiated check, or bringing forward the update a scheduled check
    /// found; Sparkle shows its own progress and result window.
    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Show Sparkle's window only if the app is already in front (Settings is
        // open); otherwise the app's own UI announces it. Sparkle also reports
        // "immediate focus" for a check made right after launch, which for a login
        // item is exactly while the user is typing elsewhere: the window took focus
        // over their app (translate-like-me UX audit 2026-09-28, UX-T01).
        immediateFocus && MainActor.assumeIsolated { NSApp.isActive }
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
