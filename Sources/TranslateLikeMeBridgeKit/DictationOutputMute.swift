import CoreAudio
import Foundation
import os

private let muteLog = Logger.app("dictation")

public protocol DictationMuting {
    func engage()
    func release()
    func recoverInterrupted()
}

// Core Audio access to the default output device's master mute.
public protocol DictationOutputControl {
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
public final class DictationOutputMute: DictationMuting {
    public static let key = "dictationMutedOutputDevice"
    private let control: DictationOutputControl
    private let store: UserDefaults
    private var holding = false

    public init(control: DictationOutputControl = CoreAudioOutputControl(), store: UserDefaults = .standard) {
        self.control = control
        self.store = store
    }

    public func engage() {
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

    public func release() {
        guard holding else { return }
        holding = false
        recoverInterrupted()
    }

    // Keep a failed or disconnected restoration pending. Resolve by UID, since
    // Core Audio can reuse a numeric device id after a device disappears.
    public func recoverInterrupted() {
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

public struct CoreAudioOutputControl: DictationOutputControl {
    public init() {}

    private static var mute: AudioObjectPropertyAddress {
        audioAddress(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
    }

    public func defaultOutput() -> AudioObjectID? { defaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    public func isMuted(_ device: AudioObjectID) -> Bool? {
        var address = Self.mute
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    public func setMuted(_ device: AudioObjectID, _ muted: Bool) -> Bool {
        var address = Self.mute
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
            return false
        }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    public func uid(of device: AudioObjectID) -> String? { audioDeviceUID(device) }

    public func device(uid: String) -> AudioObjectID? { audioDevice(uid: uid) }
}
