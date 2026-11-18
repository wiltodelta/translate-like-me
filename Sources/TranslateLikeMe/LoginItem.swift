import Foundation
import os

private let log = Logger.app("login-item")

// Wraps "launch at login" via SMAppService; the service is the only record of
// whether it is on.
enum LoginItem {
    static var isEnabled: Bool { ServiceLoginItem.isEnabled }

    // Returns the error to show the user, or nil when the change took effect.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if try ServiceLoginItem.update(enabled) {
                return String(localized: """
                    Allow Translate Like Me in System Settings > General > Login Items & Extensions.
                    """)
            }
            return nil
        } catch {
            log.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
            return String(localized: "Couldn't change this: \(error.localizedDescription)",
                          comment: "The placeholder is the system's error message")
        }
    }
}
