import ApplicationServices
import Foundation
import os
import XCTest
@testable import TranslateLikeMe

final class DictationTests: XCTestCase {
    func testWindowCaptureRequiresDictationAndTheFocusedStandardWindow() {
        let chrome: [String?] = ["AXCloseButton", "AXFullScreenButton", "AXMinimizeButton"]
        XCTAssertTrue(SelectionTarget.permitsWindowCapture(
            allowingCaret: true, role: kAXWindowRole, subrole: kAXStandardWindowSubrole,
            isFocusedWindow: true, childSubroles: chrome))
        XCTAssertFalse(SelectionTarget.permitsWindowCapture(
            allowingCaret: false, role: kAXWindowRole, subrole: kAXStandardWindowSubrole,
            isFocusedWindow: true, childSubroles: chrome))
        XCTAssertFalse(SelectionTarget.permitsWindowCapture(
            allowingCaret: true, role: kAXWindowRole, subrole: kAXStandardWindowSubrole,
            isFocusedWindow: false, childSubroles: chrome))
        for role in [nil, kAXTextFieldRole, kAXTextAreaRole, kAXSheetRole] {
            XCTAssertFalse(SelectionTarget.permitsWindowCapture(
                allowingCaret: true, role: role, subrole: kAXStandardWindowSubrole,
                isFocusedWindow: true, childSubroles: chrome))
        }
        for subrole in [nil, "AXSecureTextField", kAXDialogSubrole] {
            XCTAssertFalse(SelectionTarget.permitsWindowCapture(
                allowingCaret: true, role: kAXWindowRole, subrole: subrole,
                isFocusedWindow: true, childSubroles: chrome))
        }
        let exposedContent: [[String?]?] = [nil, [nil], ["AXTextField"], ["AXCloseButton", nil]]
        for children in exposedContent {
            XCTAssertFalse(SelectionTarget.permitsWindowCapture(
                allowingCaret: true, role: kAXWindowRole, subrole: kAXStandardWindowSubrole,
                isFocusedWindow: true, childSubroles: children))
        }
    }

    func testFocusedPIDFallsBackToFrontmostOnlyWhenAccessibilityCannotAnswer() {
        // A nonactivating panel holds focus over the frontmost app: AX names it.
        XCTAssertEqual(SelectionTarget.focusedPID(accessibility: 41, frontmost: 52_802), 41)
        XCTAssertEqual(SelectionTarget.focusedPID(accessibility: nil, frontmost: 52_802), 52_802)
        XCTAssertNil(SelectionTarget.focusedPID(accessibility: nil, frontmost: nil))
    }

    func testEmptyRichEditorDropsPlaceholderNewlineAfterDictation() {
        let target = caretTarget()
        let text = "Привет, world!"
        XCTAssertTrue(target.replacementMatches(text, expected: text + "\n",
                                               currentRange: CFRange(location: text.utf16.count, length: 0)))
    }

    func testPlaceholderAcknowledgementRequiresExactCaretAndDictationOptIn() {
        let text = "Привет, world!"
        let target = caretTarget()
        for range in [nil, CFRange(location: 0, length: 0), CFRange(location: text.utf16.count, length: 1)] {
            XCTAssertFalse(target.replacementMatches(text, expected: text + "\n", currentRange: range))
        }
        let translation = caretTarget(allowingCaret: false)
        XCTAssertFalse(translation.replacementMatches(text, expected: text + "\n",
                                                     currentRange: CFRange(location: text.utf16.count, length: 0)))
        let selected = caretTarget(range: CFRange(location: 0, length: 1))
        XCTAssertFalse(selected.replacementMatches(text, expected: text + "\n",
                                                  currentRange: CFRange(location: text.utf16.count, length: 0)))
    }

    func testPlaceholderAcknowledgementDoesNotDiscardUserWhitespaceOrExistingText() {
        let target = caretTarget()
        let text = "Привет"
        let caret = CFRange(location: text.utf16.count, length: 0)
        for expected in [text + "\n\n", "\n" + text + "\n", " " + text + "\n", text + " \n"] {
            XCTAssertFalse(target.replacementMatches(text, expected: expected, currentRange: caret))
        }
        let nonempty = caretTarget(value: "Earlier\n")
        let combined = text + "Earlier"
        XCTAssertFalse(nonempty.replacementMatches(combined, expected: combined + "\n",
                                                  currentRange: CFRange(location: combined.utf16.count, length: 0)))
        let requestedNewline = text + "\n"
        let finalCaret = CFRange(location: requestedNewline.utf16.count, length: 0)
        XCTAssertTrue(target.replacementMatches(requestedNewline, expected: requestedNewline + "\n",
                                               currentRange: finalCaret))
    }

    func testPlaceholderCaretUsesUTF16AndExactValueStillMatches() {
        let target = caretTarget()
        let text = "Hi \u{10400}"
        XCTAssertFalse(target.replacementMatches(text, expected: text + "\n",
                                                currentRange: CFRange(location: text.count, length: 0)))
        XCTAssertTrue(target.replacementMatches(text, expected: text + "\n",
                                               currentRange: CFRange(location: text.utf16.count, length: 0)))
        XCTAssertTrue(target.replacementMatches(text + "\n", expected: text + "\n", currentRange: nil))
    }

    private func caretTarget(value: String = "\n", range: CFRange = CFRange(location: 0, length: 0),
                             allowingCaret: Bool = true) -> SelectionTarget {
        SelectionTarget(pid: ProcessInfo.processInfo.processIdentifier,
                        element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                        range: range, value: value, selectedText: "", allowsCaret: allowingCaret)
    }

    func testAXRangeDecoderRejectsMalformedRangesBeforeCaretOptIn() throws {
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

    func testCaretDeliveryDoesNotCopyASelectionAndRestoresClipboard() async throws {
        let access = DictationAccess()
        let delivery = DictationDelivery(access: access, pause: { _ in })
        let pasted = try await delivery.insert("Привет, world!", into: "caret")
        XCTAssertEqual(pasted, .confirmed)
        XCTAssertEqual(access.state.withLock { $0.pastes }, ["Привет, world!"])
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original rich clipboard")
    }

    func testWindowDeliveryDispatchesOnceWithoutClaimingTextConfirmation() async throws {
        let access = DictationAccess()
        let delivery = DictationDelivery(access: access, requiresTextConfirmation: false, pause: { _ in })
        let outcome = try await delivery.insert("text", into: "caret")
        XCTAssertEqual(outcome, .dispatched)
        XCTAssertEqual(access.state.withLock { $0.verificationCount }, 0)
        XCTAssertEqual(access.state.withLock { $0.pastes }, ["text"])
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original rich clipboard")
    }

    func testWindowDeliveryRejectsChangedTargetBeforeClipboardWrite() async throws {
        let access = DictationAccess()
        access.state.withLock { $0.target = "different window" }
        let delivery = DictationDelivery(access: access, requiresTextConfirmation: false, pause: { _ in })
        let outcome = try await delivery.insert("text", into: "caret")
        XCTAssertEqual(outcome, .retained)
        XCTAssertEqual(access.changeCount, 0)
        XCTAssertTrue(access.state.withLock { $0.pastes.isEmpty })
    }

    func testWindowChangeAfterDispatchRetainsResultWithoutRepeatingPaste() async throws {
        let access = DictationAccess()
        let delivery = DictationDelivery(access: access, requiresTextConfirmation: false, pause: { _ in
            access.state.withLock { $0.target = "different window" }
        })
        let outcome = try await delivery.insert("text", into: "caret")
        XCTAssertEqual(outcome, .retained)
        XCTAssertEqual(access.state.withLock { $0.pastes }, ["text"])
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original rich clipboard")
    }

    func testInputAfterWindowDispatchKeepsDelivery() async throws {
        let access = DictationAccess()
        let delivery = DictationDelivery(access: access, requiresTextConfirmation: false, pause: { _ in
            access.state.withLock { $0.userInput = true }
        })
        let outcome = try await delivery.insert("text", into: "caret")
        XCTAssertEqual(outcome, .dispatched)
        XCTAssertEqual(access.state.withLock { $0.pastes }, ["text"])
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original rich clipboard")
    }

    func testInputBeforeDispatchRetainsResult() async throws {
        let access = DictationAccess()
        access.state.withLock { $0.userInput = true }
        let delivery = DictationDelivery(access: access, requiresTextConfirmation: false, pause: { _ in })
        let outcome = try await delivery.insert("text", into: "caret")
        XCTAssertEqual(outcome, .retained)
        XCTAssertTrue(access.state.withLock { $0.pastes.isEmpty })
    }

    func testDeliveryWaitsForDelayedAccessibilityAcknowledgement() async throws {
        let access = DictationAccess()
        access.state.withLock { $0.acknowledgementDelay = .milliseconds(300) }
        let delivery = DictationDelivery(access: access, pause: { access.advance($0) })
        let pasted = try await delivery.insert("Привет, world!", into: "caret")
        XCTAssertEqual(pasted, .confirmed)
        XCTAssertEqual(access.state.withLock { $0.verificationCount }, 2)
        XCTAssertEqual(access.state.withLock { $0.pastes }, ["Привет, world!"])
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original rich clipboard")
    }

    func testUnacknowledgedPasteDoesNotRetryInsertion() async throws {
        let access = DictationAccess()
        access.state.withLock { $0.acknowledgementDelay = .seconds(2) }
        let delivery = DictationDelivery(access: access, pause: { access.advance($0) })
        let pasted = try await delivery.insert("text", into: "caret")
        XCTAssertEqual(pasted, .retained)
        XCTAssertEqual(access.state.withLock { $0.verificationCount }, 2)
        XCTAssertEqual(access.state.withLock { $0.elapsed }, .milliseconds(720))
        XCTAssertEqual(access.state.withLock { $0.pastes }, ["text"])
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original rich clipboard")
    }

    func testChangedTargetNeverReceivesDictation() async throws {
        let access = DictationAccess()
        access.state.withLock { $0.target = "different field" }
        let pasted = try await DictationDelivery(access: access, pause: { _ in }).insert("text", into: "caret")
        XCTAssertEqual(pasted, .retained)
        XCTAssertTrue(access.state.withLock { $0.pastes.isEmpty })
    }

    func testCopyDuringSnapshotPreventsPasteAndPreservesNewCopy() async throws {
        let access = DictationAccess()
        access.state.withLock { $0.copyDuringSnapshot = true }
        let pasted = try await DictationDelivery(access: access, pause: { _ in }).insert("text", into: "caret")
        XCTAssertEqual(pasted, .retained)
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "new copy")
        XCTAssertTrue(access.state.withLock { $0.pastes.isEmpty })
    }

    func testNewCopyAfterPasteSurvivesRestore() async throws {
        let access = DictationAccess()
        let run = DictationDelivery(access: access, pause: { _ in access.userCopy() })
        _ = try await run.insert("text", into: "caret")
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "new copy")
    }

    func testCancellationAfterDispatchStillRestoresOwnedClipboard() async throws {
        let access = DictationAccess()
        let run = DictationDelivery(access: access, pause: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let task = Task { try await run.insert("text", into: "caret") }
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertEqual(access.state.withLock { $0.pastes }, ["text"])
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original rich clipboard")
    }

    func testCancellationDuringFinalAcknowledgementWaitRestoresClipboard() async throws {
        let access = DictationAccess()
        access.state.withLock { $0.acknowledgementDelay = .milliseconds(300) }
        let run = DictationDelivery(access: access, pause: { duration in
            access.advance(duration)
            if access.state.withLock({ $0.elapsed }) >= .milliseconds(300) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        })
        let task = Task { try await run.insert("text", into: "caret") }
        do {
            _ = try await task.value
            XCTFail("Cancellation during the final wait must propagate")
        } catch is CancellationError {} catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertEqual(access.state.withLock { $0.verificationCount }, 1)
        XCTAssertEqual(access.state.withLock { $0.pastes }, ["text"])
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original rich clipboard")
    }

    func testMissingTargetDoesNotTouchClipboard() async throws {
        let access = DictationAccess()
        let pasted = try await DictationDelivery(access: access, pause: { _ in }).insert("text", into: nil)
        XCTAssertEqual(pasted, .retained)
        XCTAssertEqual(access.changeCount, 0)
    }
}

private struct DictationAccess: SelectionAccess {
    struct State {
        var target = "caret"
        var clipboard = "original rich clipboard"
        var count = 0
        var pastes: [String] = []
        var copyDuringSnapshot = false
        var elapsed: Duration = .zero
        var acknowledgementDelay: Duration = .zero
        var verificationCount = 0
        var userInput = false
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
    func advance(_ duration: Duration) { state.withLock { $0.elapsed += duration } }
    func captureTarget() -> String? { state.withLock { $0.target } }
    func copySelection() -> CopiedSelection {
        XCTFail("Dictation must not copy a selection")
        return .init(text: nil, changeCount: nil)
    }
    func isCurrent(_ target: String) -> Bool { !state.withLock { $0.userInput } && targetUnchanged(target) }
    func targetUnchanged(_ target: String) -> Bool { captureTarget() == target }
    func paste(_ text: String, into target: String, ifUnchangedSince mark: Int) -> PasteAttempt? {
        state.withLock {
            guard $0.target == target, $0.count == mark else { return nil }
            $0.clipboard = text
            $0.count += 1
            $0.pastes.append(text)
            return PasteAttempt(changeCount: $0.count, posted: true)
        }
    }
    func replacementLanded(_ text: String, in target: String) -> Bool {
        state.withLock {
            $0.verificationCount += 1
            return $0.pastes.last == text && $0.elapsed >= $0.acknowledgementDelay
        }
    }
    func copyResult(_ text: String, ifUnchangedSince mark: Int) -> Bool {
        XCTFail("No extra clipboard writes")
        return false
    }
}
