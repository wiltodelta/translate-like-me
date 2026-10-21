import Foundation
import os
import XCTest
@testable import TranslateLikeMe

final class SelectionWorkflowTests: XCTestCase {
    func testUnchangedTargetIsReplacedAndOriginalClipboardRestored() async throws {
        let access = FakeSelectionAccess()
        let outcome = try await workflow(access).run { _ in "result" }
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(access.state.withLock { $0.pastes }, ["result"])
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original clipboard")
    }

    func testChangedAppFieldSelectionOrTextNeverReceivesPaste() async throws {
        // Each AX context change is represented by a different target identity.
        for changed in ["other app", "other field", "moved range", "edited text"] {
            let access = FakeSelectionAccess()
            let outcome = try await workflow(access).run { _ in
                access.state.withLock { $0.target = changed }
                return "result"
            }
            XCTAssertEqual(outcome, .result("result", copied: false), changed)
            XCTAssertEqual(access.state.withLock { $0.pastes }, [], changed)
            XCTAssertEqual(access.state.withLock { $0.clipboard }, "original clipboard", changed)
        }
    }

    func testMissingAXContextStillTranslatesWithoutAutomaticPaste() async throws {
        let access = FakeSelectionAccess()
        access.state.withLock { $0.target = nil }
        let outcome = try await workflow(access).run { text in
            XCTAssertEqual(text, "selection")
            return "result"
        }
        XCTAssertEqual(outcome, .result("result", copied: false))
        XCTAssertEqual(access.state.withLock { $0.pastes }, [])
    }

    func testNewCopyDuringEngineIsPreservedAndSkipsPaste() async throws {
        let access = FakeSelectionAccess()
        let outcome = try await workflow(access).run { _ in
            access.userCopy("new user copy")
            return "result"
        }
        XCTAssertEqual(outcome, .result("result", copied: false))
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "new user copy")
        XCTAssertEqual(access.state.withLock { $0.pastes }, [])
    }

    func testNewCopyAfterPasteSurvivesDelayedRestore() async throws {
        let access = FakeSelectionAccess()
        var run = workflow(access)
        run.pause = { duration in
            if duration == .milliseconds(600) { access.userCopy("new user copy") }
        }
        let outcome = try await run.run { _ in "result" }
        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "new user copy")
    }

    func testReadOnlySelectionKeepsResultButDoesNotOverwriteANewerCopy() async throws {
        for newCopy in [false, true] {
            let access = FakeSelectionAccess()
            access.state.withLock { $0.editable = false }
            var run = workflow(access)
            run.pause = { _ in if newCopy { access.userCopy("new user copy") } }
            let outcome = try await run.run { _ in "result" }
            XCTAssertEqual(outcome, .result("result", copied: !newCopy))
            XCTAssertEqual(access.state.withLock { $0.clipboard }, newCopy ? "new user copy" : "result")
            XCTAssertEqual(access.state.withLock { $0.copies }, 1, "Only the initial Copy is allowed")
        }
    }

    func testFailureRestoresOnlyClipboardContentsStillOwnedByRun() async {
        for newCopy in [false, true] {
            let access = FakeSelectionAccess()
            do {
                _ = try await workflow(access).run { _ in
                    if newCopy { access.userCopy("new user copy") }
                    throw CancellationError()
                }
                XCTFail("Engine failure must propagate")
            } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(access.state.withLock { $0.clipboard }, newCopy ? "new user copy" : "original clipboard")
            XCTAssertEqual(access.state.withLock { $0.pastes }, [])
        }
    }

    func testEmptySelectionRestoresClipboardWithoutCallingEngine() async throws {
        let access = FakeSelectionAccess()
        access.state.withLock { $0.selection = " " }
        let outcome = try await workflow(access).run { _ in
            XCTFail("Empty selection must not reach the engine")
            return "result"
        }
        XCTAssertEqual(outcome, .noSelection)
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original clipboard")
    }

    private func workflow(_ access: FakeSelectionAccess) -> SelectionWorkflow<FakeSelectionAccess> {
        SelectionWorkflow(access: access, pause: { _ in })
    }
}

private struct FakeSelectionAccess: SelectionAccess {
    struct State {
        var target: String? = "original field and range"
        var clipboard = "original clipboard"
        var count = 0
        var selection = "selection"
        var editable = true
        var pastes: [String] = []
        var copies = 0
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    var changeCount: Int { state.withLock { $0.count } }
    func snapshot() -> String { state.withLock { $0.clipboard } }
    func captureTarget() -> String? { state.withLock { $0.target } }
    func isCurrent(_ target: String) -> Bool { state.withLock { $0.target == target } }
    func userCopy(_ text: String) { state.withLock { $0.clipboard = text; $0.count += 1 } }
    func copySelection() -> CopiedSelection {
        state.withLock {
            $0.copies += 1
            $0.clipboard = $0.selection
            $0.count += 1
            return CopiedSelection(text: $0.selection, changeCount: $0.count)
        }
    }
    func restore(_ snapshot: String, ifUnchangedSince mark: Int) {
        state.withLock {
            if $0.count == mark { $0.clipboard = snapshot; $0.count += 1 }
        }
    }
    func paste(_ text: String, into target: String, ifUnchangedSince mark: Int) -> PasteAttempt? {
        // Workflow, rather than this fixture, must enforce its preflight guards.
        state.withLock {
            $0.pastes.append(text)
            $0.clipboard = text
            $0.count += 1
            return PasteAttempt(changeCount: $0.count, posted: true)
        }
    }
    func replacementLanded(_ text: String, in target: String) -> Bool { state.withLock { $0.editable } }
    func copyResult(_ text: String, ifUnchangedSince mark: Int) -> Bool {
        state.withLock {
            guard $0.count == mark else { return false }
            $0.clipboard = text
            $0.count += 1
            return true
        }
    }
}
