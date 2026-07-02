import SwiftUI
import AppKit

@main
struct TranslateLikeMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The app is a menu-bar accessory: the status item, its click-through panel,
    // and the settings window are all created and owned by AppDelegate (a custom
    // NSStatusItem is used instead of MenuBarExtra so a right-click can show its
    // own NSMenu). This scene only satisfies the App requirement.
    var body: some Scene {
        // Fully qualified: the app also has its own `Settings` (a UserDefaults
        // wrapper), which would otherwise shadow SwiftUI.Settings here.
        SwiftUI.Settings { EmptyView() }
    }
}

// The plate-shaped menu-bar icons: template images (solid plate with symbols cut
// out as transparent holes), so macOS tints them automatically for light/dark
// menu bars and the cutouts show the bar's own background through. `image` is the
// idle plate (@!%$); `busyImage` is the same plate with three dots, shown while a
// translation runs.
enum MenuBarIcon {
    static let image = plate(named: "MenuBarIcon", fallbackSymbol: "character.bubble")
    static let busyImage = plate(named: "MenuBarBusy", fallbackSymbol: "ellipsis")

    private static func plate(named name: String, fallbackSymbol: String) -> NSImage {
        let barHeight: CGFloat = 16
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
            image.size = NSSize(width: barHeight * aspect, height: barHeight)
            image.isTemplate = true
            return image
        }
        let fallback = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: nil) ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }
}
