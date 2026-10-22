import AppKit
import XCTest
@testable import TranslateLikeMe

final class PrimaryActionColorsTests: XCTestCase {
    func testTextRemainsReadableOnBrightAndDarkAccentsInBothAppearances() {
        let accents: [NSColor] = [.systemYellow, .systemOrange, .systemGreen, .systemBlue,
                                  .systemPurple, .systemPink, .systemRed, .gray, .white, .black]
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                for background in accents {
                    let foreground = PrimaryActionColors.textColor(on: background)
                    XCTAssertGreaterThanOrEqual(contrast(foreground, background), 4.5,
                                                "Unreadable text on \(background) in \(name)")
                }
            }
        }
    }

    func testGrayBackingsAroundTextColorTransitionRemainReadable() {
        for value in stride(from: 0.35, through: 0.60, by: 0.01) {
            let background = NSColor(srgbRed: value, green: value, blue: value, alpha: 1)
            XCTAssertGreaterThanOrEqual(contrast(PrimaryActionColors.textColor(on: background), background), 4.5)
        }
    }

    private func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let rgb = color.usingColorSpace(.sRGB)!
            func linear(_ value: CGFloat) -> Double {
                let value = Double(value)
                if value <= 0.04045 { return value / 12.92 }
                return pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
                + 0.0722 * linear(rgb.blueComponent)
        }
        let values = [luminance(first), luminance(second)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }
}
