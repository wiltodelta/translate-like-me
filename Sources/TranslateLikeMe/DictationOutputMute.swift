import CoreAudio
import Foundation
import os

private let muteLog = Logger.app("dictation")

// Core Audio access to the default output device's master mute.
protocol DictationOutputControl {
    func defaultOutput() -> AudioObjectID?
    func isMuted(_ device: AudioObjectID) -> Bool?
    func setMuted(_ device: AudioObjectID, _ muted: Bool) -> Bool
    func uid(of device: AudioObjectID) -> String?
    func device(uid: String) -> AudioObjectID?
}

// Mutes media for the hold instead of voice-processing ducking, which cost
// about a second per press. The device UID is persisted while muted so a
// crash is undone at the next launch. Only a mute this hold applied is
// undone; a device the user unmuted meanwhile is left alone.
// Not thread-safe: the capture worker's serial queue owns it.
final class DictationOutputMute {
    static let key = "dictationMutedOutputDevice"
    private let control: DictationOutputControl
    private let store: UserDefaults
    private var holding = false

    init(control: DictationOutputControl = CoreAudioOutputControl(), store: UserDefaults = .standard) {
        self.control = control
        self.store = store
    }

    func engage() {
        guard !holding else { return }
        recoverInterrupted()
        guard store.string(forKey: Self.key) == nil, let device = control.defaultOutput(),
              control.isMuted(device) == false, let uid = control.uid(of: device) else { return }
        store.set(uid, forKey: Self.key)
        guard control.setMuted(device, true) else {
            store.removeObject(forKey: Self.key)
            muteLog.notice("Dictation could not mute the output device")
            return
        }
        holding = true
    }

    func release() {
        guard holding else { return }
        holding = false
        recoverInterrupted()
    }

    // Keep a failed or disconnected restoration pending. Resolve by UID, since
    // Core Audio can reuse a numeric device id after a device disappears.
    func recoverInterrupted() {
        guard !holding, let uid = store.string(forKey: Self.key),
              let device = control.device(uid: uid), let muted = control.isMuted(device) else { return }
        if muted {
            guard control.setMuted(device, false), control.isMuted(device) == false else {
                muteLog.error("Dictation output restoration remains pending")
                return
            }
            muteLog.notice("Dictation restored output muted by a hold")
        }
        store.removeObject(forKey: Self.key)
    }

}

struct CoreAudioOutputControl: DictationOutputControl {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static var mute: AudioObjectPropertyAddress {
        address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
    }

    func defaultOutput() -> AudioObjectID? { defaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    func isMuted(_ device: AudioObjectID) -> Bool? {
        var address = Self.mute
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    func setMuted(_ device: AudioObjectID, _ muted: Bool) -> Bool {
        var address = Self.mute
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
            return false
        }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    func uid(of device: AudioObjectID) -> String? {
        var address = Self.address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    func device(uid: String) -> AudioObjectID? {
        var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }
}

// The system's current default input or output device.
func defaultAudioDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                     &size, &device) == noErr,
          device != kAudioObjectUnknown else { return nil }
    return device
}
