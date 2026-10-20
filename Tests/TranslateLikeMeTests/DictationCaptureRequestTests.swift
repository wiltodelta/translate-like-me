import XCTest
@testable import TranslateLikeMe

final class DictationCaptureRequestTests: XCTestCase {
    func testReleaseDuringStartupPreventsStartingTheHardware() throws {
        let request = DictationCaptureRequest()
        var starts = 0
        XCTAssertTrue(request.isActive)
        request.end()
        XCTAssertFalse(request.isActive)
        XCTAssertThrowsError(try request.startWhileHeld { starts += 1 }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(starts, 0)
    }

    func testHeldRequestCanStartButCannotRestartAfterRelease() throws {
        let request = DictationCaptureRequest()
        var starts = 0
        try request.startWhileHeld { starts += 1 }
        XCTAssertEqual(starts, 1)
        request.end()
        XCTAssertThrowsError(try request.startWhileHeld { starts += 1 })
        XCTAssertEqual(starts, 1)
    }
}
