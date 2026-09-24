import Foundation
import os
import ServiceManagement

private let log = Logger.app("login-item")

// Wraps "launch at login" via SMAppService; the service is the only record of
// whether it is on.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // Returns the error to show the user, or nil when the change took effect.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            // Registered, but switched off by the user in Login Items: no error
            // is thrown, so say where to allow it.
            if enabled, SMAppService.mainApp.status == .requiresApproval {
                return "allow Translate Like Me in System Settings > General > Login Items."
            }
            return nil
        } catch {
            log.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }
}
