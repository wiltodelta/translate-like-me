import AppKit
import Foundation
import os
import XCTest
@testable import TranslateLikeMe

final class DictationTests: XCTestCase {
    func testFocusedPIDFallsBackToFrontmostOnlyWhenAccessibilityCannotAnswer() {
        // A nonactivating panel holds focus over the frontmost app: AX names it.
        XCTAssertEqual(SelectionTarget.focusedPID(accessibility: 41, frontmost: 52_802), 41)
        XCTAssertEqual(SelectionTarget.focusedPID(accessibility: nil, frontmost: 52_802), 52_802)
        XCTAssertNil(SelectionTarget.focusedPID(accessibility: nil, frontmost: nil))
    }

    func testCaptureStartupStopsOnReleaseAndCancellationRejectsLateStart() {
        var session = DictationSession()
        let id = session.begin(.starting)
        XCTAssertEqual(session.releaseAction(), .stop)
        _ = session.begin(.cancelling)
        XCTAssertFalse(session.transition(.recording, for: id))
        XCTAssertEqual(session.releaseAction(), .ignore)
    }

    func testReleaseStopsCapturedAudioAndNeverStopsAnUnrelatedOperation() {
        var session = DictationSession()
        _ = session.begin(.starting)
        XCTAssertEqual(session.releaseAction(), .stop)
        _ = session.begin(.recording)
        XCTAssertEqual(session.releaseAction(), .stop)
        for phase: DictationSession.Phase in [.disabled, .preparing, .ready, .recognizing, .failed] {
            _ = session.begin(phase)
            XCTAssertEqual(session.releaseAction(), .ignore)
        }
    }

    func testCancellationRejectsLateRecognitionAndNewSessionUsesNewIdentity() {
        var session = DictationSession()
        let cancelled = session.begin(.recognizing)
        _ = session.begin(.cancelling)
        XCTAssertFalse(session.transition(.ready, for: cancelled))
        XCTAssertFalse(session.accepts(cancelled, in: .recognizing))
        let next = session.begin(.starting)
        XCTAssertNotEqual(next, cancelled)
        XCTAssertFalse(session.transition(.recording, for: cancelled))
        XCTAssertTrue(session.transition(.recording, for: next))
    }

    func testQueuedMeterCallbackCannotReturnRecognitionToRecording() {
        var session = DictationSession()
        let id = session.begin(.starting)
        XCTAssertTrue(session.transition(.recording, for: id))
        XCTAssertTrue(session.transition(.recognizing, for: id))
        XCTAssertFalse(session.transition(.recording, for: id))
        XCTAssertEqual(session.phase, .recognizing)
    }

    func testDeliveryPastesOnceAtTheCurrentFocusAndRestoresAfterTheRead() async throws {
        let access = FakePasteAccess()
        access.state.withLock { $0.readDelay = .milliseconds(100) }
        let delivered = try await PasteDelivery(access: access, pause: { access.advance($0) })
            .insert("Привет, world!")
        XCTAssertTrue(delivered)
        let state = access.state.withLock { $0 }
        XCTAssertEqual(state.pastes.map(\.text), ["Привет, world!"])
        XCTAssertEqual(state.pastes.map(\.pid), [41])
        XCTAssertEqual(state.clipboardAtRead, "Привет, world!")
        XCTAssertEqual(state.elapsed, .milliseconds(700))
        XCTAssertEqual(state.clipboard, "original clipboard")
    }

    func testDestinationIsTheFocusWhenTextIsReadyNotWhenRecordingStarted() async throws {
        let access = FakePasteAccess()
        access.state.withLock { $0.destination = 77 }
        _ = try await PasteDelivery(access: access, pause: { access.advance($0) }).insert("text")
        XCTAssertEqual(access.state.withLock { $0.pastes.map(\.pid) }, [77])
    }

    func testSlowDestinationReadsTheTranscriptNotTheRestoredClipboard() async throws {
        let access = FakePasteAccess()
        access.state.withLock { $0.readDelay = .seconds(2) }
        let delivered = try await PasteDelivery(access: access, pause: { access.advance($0) }).insert("text")
        XCTAssertTrue(delivered)
        let state = access.state.withLock { $0 }
        XCTAssertEqual(state.clipboardAtRead, "text")
        XCTAssertEqual(state.elapsed, .milliseconds(2300))
        XCTAssertEqual(state.clipboard, "original clipboard")
    }

    func testReadNearTheDeadlineStillGetsTheFullHoldBeforeRestore() async throws {
        let access = FakePasteAccess()
        access.state.withLock { $0.readDelay = .milliseconds(2950) }
        let delivered = try await PasteDelivery(access: access, pause: { access.advance($0) }).insert("text")
        XCTAssertTrue(delivered)
        XCTAssertEqual(access.state.withLock { $0.elapsed }, .milliseconds(3250))
        XCTAssertEqual(access.state.withLock { $0.clipboardAtRead }, "text")
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original clipboard")
    }

    func testCancellationWhileResolvingTheDestinationCannotPostPaste() async {
        let access = FakePasteAccess()
        access.state.withLock { $0.cancelOnDestination = true }
        let run = Task { try await PasteDelivery(access: access, pause: { access.advance($0) }).insert("text") }
        do {
            _ = try await run.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(access.state.withLock { $0.pastes.isEmpty })
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original clipboard")
    }

    func testUnreadPasteIsRetainedAtTheDeadlineWithoutRetrying() async throws {
        let access = FakePasteAccess()
        let delivered = try await PasteDelivery(access: access, pause: { access.advance($0) }).insert("text")
        XCTAssertFalse(delivered)
        let state = access.state.withLock { $0 }
        XCTAssertEqual(state.elapsed, .seconds(3))
        XCTAssertEqual(state.pastes.count, 1)
        XCTAssertEqual(state.clipboard, "original clipboard")
    }

    func testNoDestinationLeavesTheClipboardUntouched() async throws {
        let access = FakePasteAccess()
        access.state.withLock { $0.destination = nil }
        let delivered = try await PasteDelivery(access: access, pause: { access.advance($0) }).insert("text")
        XCTAssertFalse(delivered)
        XCTAssertEqual(access.changeCount, 0)
        XCTAssertTrue(access.state.withLock { $0.pastes.isEmpty })
    }

    func testCopyDuringSnapshotPreventsPasteAndPreservesNewCopy() async throws {
        let access = FakePasteAccess()
        access.state.withLock { $0.copyDuringSnapshot = true }
        let delivered = try await PasteDelivery(access: access, pause: { access.advance($0) }).insert("text")
        XCTAssertFalse(delivered)
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "new copy")
        XCTAssertTrue(access.state.withLock { $0.pastes.isEmpty })
    }

    func testNewCopyAfterPasteSurvivesRestore() async throws {
        let access = FakePasteAccess()
        access.state.withLock { $0.readDelay = .milliseconds(100) }
        let delivered = try await PasteDelivery(access: access, pause: {
            access.advance($0)
            if access.state.withLock({ $0.elapsed }) == .milliseconds(400) { access.userCopy() }
        }).insert("text")
        XCTAssertTrue(delivered)
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "new copy")
    }

    func testCancellationAfterDispatchStillRestoresOwnedClipboard() async throws {
        let access = FakePasteAccess()
        let run = PasteDelivery(access: access, pause: { duration in
            access.advance(duration)
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let task = Task { try await run.insert("text") }
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertEqual(access.state.withLock { $0.pastes.count }, 1)
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original clipboard")
    }

    func testPromisedStringRecordsTheReadThroughTheRealPasteboard() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("TranslateLikeMeTests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let receipt = PasteReceipt(text: "Привет")
        _ = SelectionService.writeTransient(receipt.promisedItem(), on: board)
        XCTAssertTrue(board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)
        XCTAssertFalse(receipt.wasRead)
        XCTAssertEqual(board.string(forType: .string), "Привет")
        XCTAssertTrue(receipt.wasRead)
    }
}
