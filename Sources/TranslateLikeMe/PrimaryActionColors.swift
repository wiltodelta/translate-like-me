import AppKit
import SwiftUI

// Keep the system accent, choosing the more readable text color for its backing.
// Selection colors can still be bright (notably yellow), even in Dark Mode.
enum PrimaryActionColors {
    static let text = Color(nsColor: NSColor(name: nil) { appearance in
        var foreground = NSColor.white
        appearance.performAsCurrentDrawingAppearance {
            foreground = textColor(on: .selectedContentBackgroundColor)
        }
        return foreground
    })

    static func textColor(on background: NSColor) -> NSColor {
        guard let rgb = background.usingColorSpace(.sRGB) else { return .white }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { component in
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        let whiteContrast = 1.05 / (luminance + 0.05)
        let blackContrast = (luminance + 0.05) / 0.05
        return blackContrast > whiteContrast ? .black : .white
    }
}

private struct PrimaryActionText: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive
    let enabled: Bool

    func body(content: Content) -> some View {
        content.foregroundStyle(enabled ? (appearsActive ? PrimaryActionColors.text : Color.primary)
                                : Color.secondaryText)
    }
}

extension View {
    func primaryActionText(enabled: Bool = true) -> some View {
        modifier(PrimaryActionText(enabled: enabled))
    }

    func primaryActionTint() -> some View {
        tint(Color(nsColor: .selectedContentBackgroundColor))
    }
}
