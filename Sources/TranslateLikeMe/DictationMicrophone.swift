import CoreAudio
import Foundation
import Observation

// An input device chosen for dictation. The UID identifies it across
// reconnections (Core Audio reuses numeric ids); the name labels it in
// Settings while it is disconnected.
struct DictationMicrophone: Codable, Hashable, Sendable {
    let uid: String
    let name: String

    // The chosen device while it is connected, otherwise the automatic input:
    // non-Bluetooth system inputs win, Bluetooth falls back to built-in or wired
    // local hardware when available, and a disconnected choice returns on reconnect.
    static func resolve(_ preferred: String?) -> AudioDeviceID? {
        DictationInputRoute.resolve(preferred)?.device
    }
}

// Visible devices with input streams, as the Settings picker lists them, and
// the current automatic input. Core Audio notifies on its own queue.
@MainActor
@Observable
final class DictationMicrophones {
    private struct Registration {
        let device: AudioObjectID
        var address: AudioObjectPropertyAddress
    }
    static let shared = DictationMicrophones()
    private(set) var available: [DictationMicrophone] = []
    private(set) var automaticName: String?
    @ObservationIgnored private var watchedIDs: [AudioDeviceID] = []
    @ObservationIgnored private var deviceListeners: [Registration] = []
    @ObservationIgnored private let listener: AudioObjectPropertyListenerBlock = { _, _ in
        MainActor.assumeIsolated { DictationMicrophones.shared.refresh() }
    }

    private init() {
        refresh()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = audioAddress(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    // Engine builds add and remove private aggregates, so most notifications
    // change nothing visible; assign only real changes to spare the picker.
    private func refresh() {
        let devices = visibleAudioDevices()
        watchDevices(devices)
        var routesByID: [AudioDeviceID: DictationInputRoute] = [:]
        var namesByID: [AudioDeviceID: String] = [:]
        var available: [DictationMicrophone] = []
        for device in devices {
            guard let route = DictationInputRoute.read(device), let name = audioDeviceName(device) else { continue }
            routesByID[device] = route
            namesByID[device] = name
            available.append(DictationMicrophone(uid: route.uid, name: name))
        }
        let resolved = DictationInputRoute.resolve(
            nil, candidates: { devices }, snapshot: { routesByID[$0] ?? DictationInputRoute.read($0) }
        )
        let automaticName = resolved.flatMap { namesByID[$0.device] ?? audioDeviceName($0.device) }
        if available != self.available { self.available = available }
        if automaticName != self.automaticName { self.automaticName = automaticName }
    }

    private func watchDevices(_ devices: [AudioDeviceID]) {
        guard devices != watchedIDs else { return }
        for var entry in deviceListeners {
            AudioObjectRemovePropertyListenerBlock(entry.device, &entry.address, .main, listener)
        }
        deviceListeners.removeAll()
        watchedIDs = devices
        let properties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
        ]
        for device in devices {
            for (selector, scope) in properties {
                var address = audioAddress(selector, scope)
                guard AudioObjectHasProperty(device, &address),
                      AudioObjectAddPropertyListenerBlock(device, &address, .main, listener) == noErr else { continue }
                deviceListeners.append(Registration(device: device, address: address))
            }
        }
    }
}
