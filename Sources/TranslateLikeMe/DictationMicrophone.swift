import CoreAudio
import Foundation
import Observation

// An input device chosen for dictation. The UID identifies it across
// reconnections (Core Audio reuses numeric ids); the name labels it in
// Settings while it is disconnected.
struct DictationMicrophone: Codable, Hashable, Sendable {
    let uid: String
    let name: String

    // The chosen device while it is connected, otherwise the system input:
    // a disconnected choice falls back silently and returns when reconnected.
    static func resolve(_ preferred: String?, device: (String) -> AudioDeviceID? = audioDevice(uid:),
                        system: () -> AudioDeviceID? = {
                            defaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice)
                        }) -> AudioDeviceID? {
        preferred.flatMap(device) ?? system()
    }
}

// Visible devices with input streams, as the Settings picker lists them, and
// the current system input. Core Audio notifies on its own queue.
@MainActor
@Observable
final class DictationMicrophones {
    static let shared = DictationMicrophones()
    private(set) var available: [DictationMicrophone] = []
    private(set) var systemName: String?

    private init() {
        refresh()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = audioAddress(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                MainActor.assumeIsolated { DictationMicrophones.shared.refresh() }
            }
        }
    }

    // Engine builds add and remove private aggregates, so most notifications
    // change nothing visible; assign only real changes to spare the picker.
    private func refresh() {
        let devices = audioDevices().filter { !isHidden($0) && DictationInputRoute.read($0) != nil }
        let available = devices.compactMap { device -> DictationMicrophone? in
            guard let uid = audioDeviceUID(device), let name = audioDeviceName(device) else { return nil }
            return DictationMicrophone(uid: uid, name: name)
        }
        let systemName = defaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice).flatMap(audioDeviceName)
        if available != self.available { self.available = available }
        if systemName != self.systemName { self.systemName = systemName }
    }

    private func audioDevices() -> [AudioDeviceID] {
        var address = audioAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    // Engines and other apps create private aggregate devices; never list them.
    private func isHidden(_ device: AudioDeviceID) -> Bool {
        var address = audioAddress(kAudioDevicePropertyIsHidden)
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &hidden) == noErr && hidden != 0
    }
}
