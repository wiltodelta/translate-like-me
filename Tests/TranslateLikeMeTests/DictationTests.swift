import AppKit
import Carbon.HIToolbox
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

    func testAXRangeDecoderRejectsMalformedRanges() throws {
        for (location, length) in [(-1, 0), (0, -1), (-1, -1), (0, 0), (0, 2)] {
            var range = CFRange(location: location, length: length)
            let value = try XCTUnwrap(AXValueCreate(.cfRange, &range))
            let decoded = SelectionTarget.selectionRange(from: value)
            if location < 0 || length < 0 {
                XCTAssertNil(decoded)
            } else {
                XCTAssertEqual(decoded?.location, location)
                XCTAssertEqual(decoded?.length, length)
            }
        }
        XCTAssertNil(SelectionTarget.selectionRange(from: nil))
        XCTAssertNil(SelectionTarget.selectionRange(from: "not an AX range" as CFString))
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
        let access = DictationAccess()
        access.state.withLock { $0.readDelay = .milliseconds(100) }
        let outcome = try await DictationDelivery(access: access, pause: { access.advance($0) })
            .insert("Привет, world!")
        XCTAssertEqual(outcome, .delivered)
        let state = access.state.withLock { $0 }
        XCTAssertEqual(state.pastes.map(\.text), ["Привет, world!"])
        XCTAssertEqual(state.pastes.map(\.pid), [41])
        XCTAssertEqual(state.clipboardAtRead, "Привет, world!")
        XCTAssertEqual(state.elapsed, .milliseconds(700))
        XCTAssertEqual(state.clipboard, "original rich clipboard")
    }

    func testDestinationIsTheFocusWhenTextIsReadyNotWhenRecordingStarted() async throws {
        let access = DictationAccess()
        access.state.withLock { $0.focused = 77 }
        _ = try await DictationDelivery(access: access, pause: { access.advance($0) }).insert("text")
        XCTAssertEqual(access.state.withLock { $0.pastes.map(\.pid) }, [77])
    }

    func testSlowDestinationReadsTheTranscriptNotTheRestoredClipboard() async throws {
        let access = DictationAccess()
        access.state.withLock { $0.readDelay = .seconds(2) }
        let outcome = try await DictationDelivery(access: access, pause: { access.advance($0) }).insert("text")
        XCTAssertEqual(outcome, .delivered)
        let state = access.state.withLock { $0 }
        XCTAssertEqual(state.clipboardAtRead, "text")
        XCTAssertEqual(state.elapsed, .milliseconds(2300))
        XCTAssertEqual(state.clipboard, "original rich clipboard")
    }

    func testUnreadPasteIsRetainedAtTheDeadlineWithoutRetrying() async throws {
        let access = DictationAccess()
        let outcome = try await DictationDelivery(access: access, pause: { access.advance($0) }).insert("text")
        XCTAssertEqual(outcome, .retained)
        let state = access.state.withLock { $0 }
        XCTAssertEqual(state.elapsed, .seconds(3))
        XCTAssertEqual(state.pastes.count, 1)
        XCTAssertEqual(state.clipboard, "original rich clipboard")
    }

    func testNoDestinationLeavesTheClipboardUntouched() async throws {
        let access = DictationAccess()
        access.state.withLock { $0.focused = nil }
        let outcome = try await DictationDelivery(access: access, pause: { access.advance($0) }).insert("text")
        XCTAssertEqual(outcome, .retained)
        XCTAssertEqual(access.changeCount, 0)
        XCTAssertTrue(access.state.withLock { $0.pastes.isEmpty })
    }

    func testCopyDuringSnapshotPreventsPasteAndPreservesNewCopy() async throws {
        let access = DictationAccess()
        access.state.withLock { $0.copyDuringSnapshot = true }
        let outcome = try await DictationDelivery(access: access, pause: { access.advance($0) }).insert("text")
        XCTAssertEqual(outcome, .retained)
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "new copy")
        XCTAssertTrue(access.state.withLock { $0.pastes.isEmpty })
    }

    func testNewCopyAfterPasteSurvivesRestore() async throws {
        let access = DictationAccess()
        access.state.withLock { $0.readDelay = .milliseconds(100) }
        let outcome = try await DictationDelivery(access: access, pause: {
            access.advance($0)
            if access.state.withLock({ $0.elapsed }) == .milliseconds(400) { access.userCopy() }
        }).insert("text")
        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "new copy")
    }

    func testCancellationAfterDispatchStillRestoresOwnedClipboard() async throws {
        let access = DictationAccess()
        let run = DictationDelivery(access: access, pause: { duration in
            access.advance(duration)
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let task = Task { try await run.insert("text") }
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertEqual(access.state.withLock { $0.pastes.count }, 1)
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original rich clipboard")
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

    @MainActor
    func testPasteKeyFollowsTheASCIICapableLayout() throws {
        let expected: [String: CGKeyCode] = ["com.apple.keylayout.US": 9, "com.apple.keylayout.Dvorak": 47,
                                             "com.apple.keylayout.DVORAK-QWERTYCMD": 9]
        for (id, code) in expected {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
            let source = try XCTUnwrap(sources?.first, id)
            XCTAssertEqual(KeyboardLayout.keyCode(typing: "v", in: source), code, id)
        }
    }
}

private struct DictationAccess: DictationPasteAccess {
    struct State {
        var focused: pid_t? = 41
        var clipboard = "original rich clipboard"
        var count = 0
        var pastes: [(text: String, pid: pid_t)] = []
        var receipt: PasteReceipt?
        var readDelay: Duration?
        var clipboardAtRead: String?
        var copyDuringSnapshot = false
        var elapsed: Duration = .zero
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    var changeCount: Int { state.withLock { $0.count } }
    func snapshot() -> String {
        let snapshot = state.withLock { $0.clipboard }
        if state.withLock({ $0.copyDuringSnapshot }) { userCopy() }
        return snapshot
    }
    func restore(_ snapshot: String, ifUnchangedSince mark: Int) {
        state.withLock { if $0.count == mark { $0.clipboard = snapshot; $0.count += 1 } }
    }
    func userCopy() { state.withLock { $0.clipboard = "new copy"; $0.count += 1 } }
    // The destination reads the clipboard once its delay has passed.
    func advance(_ duration: Duration) {
        state.withLock {
            $0.elapsed += duration
            guard let delay = $0.readDelay, let receipt = $0.receipt, !receipt.wasRead,
                  $0.elapsed >= delay else { return }
            receipt.recordRead()
            $0.clipboardAtRead = $0.clipboard
        }
    }
    func destination() -> pid_t? { state.withLock { $0.focused } }
    func paste(_ text: String, to pid: pid_t, ifUnchangedSince mark: Int) -> DictationPaste? {
        state.withLock {
            guard $0.count == mark else { return nil }
            let receipt = PasteReceipt(text: text)
            $0.clipboard = text
            $0.count += 1
            $0.pastes.append((text, pid))
            $0.receipt = receipt
            return DictationPaste(changeCount: $0.count, receipt: receipt)
        }
    }
}
