import XCTest
@testable import TranslateLikeMe

final class DictationCaptureRequestTests: XCTestCase {
    func testReleaseDuringStartupPreventsStartingTheHardware() throws {
        let request = DictationCaptureRequest()
        var starts = 0
        XCTAssertTrue(request.isActive)
        request.end()
        XCTAssertFalse(request.isActive)
        XCTAssertThrowsError(try request.startIfActive { starts += 1 }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(starts, 0)
    }

    func testReleaseCompletesWhileHardwareStartupIsStillInProgress() async {
        let request = DictationCaptureRequest()
        let started = expectation(description: "Hardware start entered")
        let released = expectation(description: "Release accepted before hardware start returns")
        let finished = expectation(description: "Hardware start finished")
        let finishStartup = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            try? request.startIfActive {
                started.fulfill()
                finishStartup.wait()
            }
        }
        await fulfillment(of: [started], timeout: 5)
        DispatchQueue.global().async {
            request.end()
            released.fulfill()
        }
        // This timeout guards a deadlock; startup is explicitly held until release completes.
        await fulfillment(of: [released], timeout: 5)
        finishStartup.signal()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertFalse(request.isActive)
    }

    func testHeldRequestCanStartButCannotRestartAfterRelease() throws {
        let request = DictationCaptureRequest()
        var starts = 0
        try request.startIfActive { starts += 1 }
        XCTAssertEqual(starts, 1)
        request.end()
        XCTAssertThrowsError(try request.startIfActive { starts += 1 })
        XCTAssertEqual(starts, 1)
    }
}
