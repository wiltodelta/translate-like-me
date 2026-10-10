import SwiftUI
import AppKit

@main
struct TranslateLikeMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The app is a menu-bar accessory: the status item, its menu, and the
    // settings window are all created and owned by AppDelegate. This scene only
    // satisfies the App requirement.
    var body: some Scene {
        // Fully qualified: the app also has its own `Settings` (a UserDefaults
        // wrapper), which would otherwise shadow SwiftUI.Settings here.
        SwiftUI.Settings { EmptyView() }
    }
}

// The menu-bar icons (scripts/make-menubar-icons.py): template images, so macOS
// tints them for light and dark menu bars. `image` is the app icon's face as an
// outline; `busyImage` is the same face as a solid tile with the features cut
// out, shown while a translation runs.
enum MenuBarIcon {
    static let image = glyph(named: "MenuBarIcon", fallbackSymbol: "character.bubble")
    static let busyImage = glyph(named: "MenuBarBusy", fallbackSymbol: "ellipsis")

    private static func glyph(named name: String, fallbackSymbol: String) -> NSImage {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)  // 72 px drawn at 4x
            image.isTemplate = true
            return image
        }
        let fallback = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: nil) ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }
}
