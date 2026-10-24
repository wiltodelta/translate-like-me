import CoreAudio
import Foundation
import os

protocol DictationInputWatching: AnyObject {
    func watch(_ route: DictationInputRoute?)
    func stop()
}

// Registration state belongs to the capture queue. HAL callbacks only enqueue
// a recheck; they never stop an engine or read the recorder's mutable state.
final class DictationInputObserver: DictationInputWatching {
    private struct Registration {
        let device: AudioObjectID
        var address: AudioObjectPropertyAddress
    }
    private let queue = DispatchQueue(label: "com.wiltodelta.translatelikeme.input-events")
    private let listener: AudioObjectPropertyListenerBlock
    private var system: [Registration] = []
    private var selected: [Registration] = []
    private var route: DictationInputRoute?

    init(changed: @escaping @Sendable () -> Void) {
        listener = { _, _ in changed() }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            register(AudioObjectID(kAudioObjectSystemObject), audioAddress(selector), into: &system)
        }
    }

    func watch(_ route: DictationInputRoute?) {
        guard route != self.route else { return }
        remove(&selected)
        self.route = route
        guard let route else { return }
        for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate] {
            register(route.device, audioAddress(selector), into: &selected)
        }
        for selector in [kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyDataSource] {
            let address = audioAddress(selector, kAudioObjectPropertyScopeInput)
            var property = address
            if AudioObjectHasProperty(route.device, &property) { register(route.device, address, into: &selected) }
        }
    }

    func stop() {
        remove(&selected)
        remove(&system)
        route = nil
    }

    deinit { stop() }

    private func register(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress,
                          into registrations: inout [Registration]) {
        var address = address
        let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, listener)
        guard status == noErr else {
            Logger.app("dictation").error("Dictation input listener registration failed: \(status)")
            return
        }
        registrations.append(Registration(device: device, address: address))
    }

    private func remove(_ registrations: inout [Registration]) {
        for var entry in registrations {
            let status = AudioObjectRemovePropertyListenerBlock(entry.device, &entry.address, queue, listener)
            if status != noErr {
                Logger.app("dictation").error("Dictation input listener removal failed: \(status)")
            }
        }
        registrations.removeAll()
    }
}
