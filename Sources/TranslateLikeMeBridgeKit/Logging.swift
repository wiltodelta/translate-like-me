import os
import ServiceManagement
import SwiftUI

public extension Logger {
    // One subsystem for every log line: /usr/bin/log stream --predicate
    // 'subsystem == "com.wiltodelta.translatelikeme"'.
    static func app(_ category: String) -> Logger {
        Logger(subsystem: "com.wiltodelta.translatelikeme", category: category)
    }
}

public extension Color {
    // Secondary text the app draws, at 4.5:1 or more where `.secondary` is not
    // (CLAUDE.md, Interface; claude-config docs/macos-apps.md).
    static let secondaryText = Color.primary.opacity(0.66)
}

public enum ServiceLoginItem {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // Returns whether System Settings still requires manual user approval.
    public static func update(_ enabled: Bool) throws -> Bool {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        return enabled && SMAppService.mainApp.status == .requiresApproval
    }
}
