import CoreAudio
import Foundation
import XCTest
@testable import TranslateLikeMe

final class DictationOutputMuteTests: XCTestCase {
    private let speakers: AudioObjectID = 41

    func testHoldMutesAndRestoresAnUnmutedOutput() throws {
        let (control, store) = try fixture()
        let mute = DictationOutputMute(control: control, store: store)
        mute.engage()
        XCTAssertEqual(control.muted[speakers], true)
        XCTAssertEqual(store.string(forKey: DictationOutputMute.key), "speakers-uid")
        mute.release()
        XCTAssertEqual(control.muted[speakers], false)
        XCTAssertNil(store.string(forKey: DictationOutputMute.key))
        XCTAssertEqual(control.writes, 2)
    }

    func testAlreadyMutedOutputStaysMutedAfterRelease() throws {
        let (control, store) = try fixture(muted: true)
        let mute = DictationOutputMute(control: control, store: store)
        mute.engage()
        mute.release()
        XCTAssertEqual(control.muted[speakers], true)
        XCTAssertEqual(control.writes, 0)
        XCTAssertNil(store.string(forKey: DictationOutputMute.key))
    }

    func testUserUnmuteDuringTheHoldIsNotOverwritten() throws {
        let (control, store) = try fixture()
        let mute = DictationOutputMute(control: control, store: store)
        mute.engage()
        control.muted[speakers] = false
        mute.release()
        XCTAssertEqual(control.muted[speakers], false)
        XCTAssertEqual(control.writes, 1)
    }

    func testUnsettableMuteLeavesNoRecoveryRecord() throws {
        let (control, store) = try fixture()
        control.settable = false
        let mute = DictationOutputMute(control: control, store: store)
        mute.engage()
        XCTAssertEqual(control.muted[speakers], false)
        XCTAssertNil(store.string(forKey: DictationOutputMute.key))
        mute.release()
        XCTAssertEqual(control.muted[speakers], false)
    }

    func testLaunchUndoesAMuteLeftByAnInterruptedHold() throws {
        let (control, store) = try fixture()
        DictationOutputMute(control: control, store: store).engage()
        XCTAssertEqual(control.muted[speakers], true)
        DictationOutputMute(control: control, store: store).recoverInterrupted()
        XCTAssertEqual(control.muted[speakers], false)
        XCTAssertNil(store.string(forKey: DictationOutputMute.key))
    }

    func testLaunchLeavesAnOutputTheUserAlreadyUnmuted() throws {
        let (control, store) = try fixture()
        DictationOutputMute(control: control, store: store).engage()
        control.muted[speakers] = false
        let writes = control.writes
        DictationOutputMute(control: control, store: store).recoverInterrupted()
        XCTAssertEqual(control.writes, writes)
        XCTAssertNil(store.string(forKey: DictationOutputMute.key))
    }

    func testFailedRestoreKeepsRecoveryUntilItSucceeds() throws {
        let (control, store) = try fixture()
        let mute = DictationOutputMute(control: control, store: store)
        mute.engage()
        control.settable = false
        mute.release()
        XCTAssertEqual(control.muted[speakers], true)
        XCTAssertEqual(store.string(forKey: DictationOutputMute.key), "speakers-uid")
        control.settable = true
        mute.recoverInterrupted()
        XCTAssertEqual(control.muted[speakers], false)
        XCTAssertNil(store.string(forKey: DictationOutputMute.key))
    }

    func testDisconnectedOutputCanRecoverAfterItReturns() throws {
        let (control, store) = try fixture()
        let mute = DictationOutputMute(control: control, store: store)
        mute.engage()
        control.available = false
        mute.release()
        XCTAssertEqual(store.string(forKey: DictationOutputMute.key), "speakers-uid")
        control.available = true
        mute.recoverInterrupted()
        XCTAssertEqual(control.muted[speakers], false)
        XCTAssertNil(store.string(forKey: DictationOutputMute.key))
    }

    func testRestorationFollowsTheUIDWhenTheDeviceIDChanges() throws {
        let (control, store) = try fixture()
        let mute = DictationOutputMute(control: control, store: store)
        mute.engage()
        control.device = 99
        control.muted[99] = true
        control.muted[speakers] = true // Another device reused the old id.
        mute.release()
        XCTAssertEqual(control.muted[99], false)
        XCTAssertEqual(control.muted[speakers], true)
        XCTAssertNil(store.string(forKey: DictationOutputMute.key))
    }

    private func fixture(muted: Bool = false) throws -> (FakeOutputControl, UserDefaults) {
        let name = "DictationOutputMuteTests-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let control = FakeOutputControl(device: speakers, uid: "speakers-uid")
        control.muted[speakers] = muted
        return (control, store)
    }
}

private final class FakeOutputControl: DictationOutputControl {
    var device: AudioObjectID
    let deviceUID: String
    var muted: [AudioObjectID: Bool] = [:]
    var available = true
    var settable = true
    var writes = 0

    init(device: AudioObjectID, uid: String) {
        self.device = device
        deviceUID = uid
    }

    func defaultOutput() -> AudioObjectID? { device }
    func isMuted(_ device: AudioObjectID) -> Bool? { available ? muted[device] : nil }
    func setMuted(_ device: AudioObjectID, _ value: Bool) -> Bool {
        guard available, settable else { return false }
        writes += 1
        muted[device] = value
        return true
    }
    func uid(of device: AudioObjectID) -> String? { device == self.device ? deviceUID : nil }
    func device(uid: String) -> AudioObjectID? { available && uid == deviceUID ? device : nil }
}
