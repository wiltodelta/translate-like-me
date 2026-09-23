import AppKit
import SwiftUI
import XCTest
@testable import TranslateLikeMe

// The recipe for the README screenshots: renders the real status menu and the
// Translation settings pane in the light appearance and captures each window
// (screencapture -o, transparent corners). It opens windows on screen, so it
// only runs when asked:
//   TLM_SCREENSHOTS="$PWD/screenshots" swift test --filter ScreenshotRecipe
final class ScreenshotRecipe: XCTestCase {
    private func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private static func capture(windowNumber: Int, to path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(windowNumber)", path]
        try? process.run()
        process.waitUntilExit()
    }

    @MainActor
    func testRenderScreenshots() throws {
        guard let out = ProcessInfo.processInfo.environment["TLM_SCREENSHOTS"] else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        let screen = NSScreen.screens[0].visibleFrame

        // Status menu, popped up in-process so it takes the app appearance. The
        // capture runs off the main thread while the menu tracks.
        let statusMenu = StatusMenu()
        statusMenu.menuNeedsUpdate(statusMenu.menu)
        pump(1.5) // engine status check
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            let pid = ProcessInfo.processInfo.processIdentifier
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            if let menuWindow = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid
                                                         && ($0[kCGWindowLayer as String] as? Int ?? 0) > 20 }),
               let number = menuWindow[kCGWindowNumber as String] as? Int {
                Self.capture(windowNumber: number, to: "\(out)/menu.png")
            }
            DispatchQueue.main.async { statusMenu.menu.cancelTracking() }
        }
        statusMenu.menu.popUp(positioning: nil, at: NSPoint(x: screen.minX + 100, y: screen.maxY - 40), in: nil)

        // Settings, Translation pane, built exactly as the app builds it.
        let (window, tabs) = SettingsTabViewController.makeWindow()
        tabs.select(.translation)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.setFrameTopLeftPoint(NSPoint(x: screen.minX + 60, y: screen.maxY - 20))
        window.orderFrontRegardless()
        pump(1.2)
        Self.capture(windowNumber: window.windowNumber, to: "\(out)/settings.png")
        window.orderOut(nil)
    }
}
