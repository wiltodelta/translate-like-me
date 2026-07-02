import ServiceManagement
import Foundation

// Wraps "launch at login" via SMAppService (macOS 13+).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("TranslateLikeMe: login item update failed: \(error.localizedDescription)")
        }
    }
}
