import Foundation
import XCTest
@testable import TranslateLikeMe

final class SelectionWorkflowTests: XCTestCase {
    func testReadPasteReplacesSelectionAndRestoresOriginalClipboardAfterTheRead() async throws {
        let access = FakePasteAccess()
        access.state.withLock { $0.readDelay = .milliseconds(100) }
        let outcome = try await workflow(access).run { _ in "result" }
        XCTAssertEqual(outcome, .pasted)
        let state = access.state.withLock { $0 }
        XCTAssertEqual(state.pastes.map(\.text), ["result"])
        XCTAssertEqual(state.pastes.map(\.pid), [41])
        XCTAssertEqual(state.clipboardAtRead, "result")
        XCTAssertEqual(state.elapsed, .milliseconds(700))
        XCTAssertEqual(state.clipboard, "original clipboard")
    }

    func testChangedDestinationNeverReceivesPaste() async throws {
        // Another app focused, typing, a click, an app switch or a secure field.
        let access = FakePasteAccess()
        let outcome = try await workflow(access).run { _ in
            access.state.withLock { $0.destination = nil }
            return "result"
        }
        XCTAssertEqual(outcome, .result("result"))
        XCTAssertEqual(access.state.withLock { $0.pastes.count }, 0)
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original clipboard")
    }

    func testNewCopyDuringEngineIsPreservedAndSkipsPaste() async throws {
        let access = FakePasteAccess()
        let outcome = try await workflow(access).run { _ in
            access.userCopy()
            return "result"
        }
        XCTAssertEqual(outcome, .result("result"))
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "new copy")
        XCTAssertEqual(access.state.withLock { $0.pastes.count }, 0)
    }

    // A read-only field never reads the clipboard: the result is shown, the
    // user's clipboard comes back, and no second paste is posted.
    func testUnreadPasteShowsResultAndRestoresClipboardWithoutRetrying() async throws {
        let access = FakePasteAccess()
        let outcome = try await workflow(access).run { _ in "result" }
        XCTAssertEqual(outcome, .result("result"))
        let state = access.state.withLock { $0 }
        XCTAssertEqual(state.elapsed, .seconds(3))
        XCTAssertEqual(state.pastes.count, 1)
        XCTAssertEqual(state.copies, 1, "Only the initial Copy is allowed")
        XCTAssertEqual(state.clipboard, "original clipboard")
    }

    func testFailureRestoresOnlyClipboardContentsStillOwnedByRun() async {
        for newCopy in [false, true] {
            let access = FakePasteAccess()
            do {
                _ = try await workflow(access).run { _ in
                    if newCopy { access.userCopy() }
                    throw CancellationError()
                }
                XCTFail("Engine failure must propagate")
            } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(access.state.withLock { $0.clipboard }, newCopy ? "new copy" : "original clipboard")
            XCTAssertEqual(access.state.withLock { $0.pastes.count }, 0)
        }
    }

    func testEmptySelectionRestoresClipboardWithoutCallingEngine() async throws {
        let access = FakePasteAccess()
        access.state.withLock { $0.selection = " " }
        let outcome = try await workflow(access).run { _ in
            XCTFail("Empty selection must not reach the engine")
            return "result"
        }
        XCTAssertEqual(outcome, .noSelection)
        XCTAssertEqual(access.state.withLock { $0.clipboard }, "original clipboard")
    }

    private func workflow(_ access: FakePasteAccess) -> SelectionWorkflow<FakePasteAccess> {
        SelectionWorkflow(access: access, pause: { access.advance($0) })
    }
}
