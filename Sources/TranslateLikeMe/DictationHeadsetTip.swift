import CoreAudio
import Foundation

// Wispr Flow, Willow and Spokenly warn that AirPods and other Bluetooth headsets
// dictate less accurately than the built-in microphone, and recordings here agreed
// (docs/dictation-device-compatibility.md). The input stays the user's choice.
struct DictationHeadsetTip {
    private static let interval = Duration.seconds(3_600)
    private var shown: ContinuousClock.Instant?

    // The input a hold records from, resolved as the capture worker resolves it.
    static func usesHeadset(_ chosen: String?) -> Bool {
        audioDeviceIsBluetooth(DictationInputRoute.resolve(chosen)?.device)
    }

    // At most once per interval; ask only for holds that record from a headset.
    mutating func due(at now: ContinuousClock.Instant) -> Bool {
        guard shown.map({ $0.duration(to: now) >= Self.interval }) ?? true else { return false }
        shown = now
        return true
    }
}
