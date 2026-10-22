import XCTest
@testable import TranslateLikeMe

final class DictationMediaPlaybackTests: XCTestCase {
    func testReleaseDuringPauseWaitsForItsReceiptThenRestores() async {
        let entered = expectation(description: "Pause command entered")
        let resumed = expectation(description: "Confirmed pause restored")
        let probe = MediaCommandProbe(entered: entered, resumed: resumed)
        let playback = DictationMediaPlayback { action, receipt in await probe.run(action, receipt) }
        playback.begin()
        await fulfillment(of: [entered], timeout: 5)
        playback.end()
        await probe.completePause()
        await fulfillment(of: [resumed], timeout: 5)
        playback.finishPending()
        let calls = await probe.calls
        XCTAssertEqual(calls, ["pause", "resume"])
    }

    func testRepeatedBeginAndEndDoNotDuplicateCommands() async {
        let entered = expectation(description: "Pause command entered")
        let resumed = expectation(description: "Confirmed pause restored")
        let probe = MediaCommandProbe(entered: entered, resumed: resumed)
        let playback = DictationMediaPlayback { action, receipt in await probe.run(action, receipt) }
        playback.begin()
        playback.begin()
        await fulfillment(of: [entered], timeout: 5)
        await probe.completePause()
        playback.end()
        playback.end()
        await fulfillment(of: [resumed], timeout: 5)
        playback.finishPending()
        let calls = await probe.calls
        XCTAssertEqual(calls, ["pause", "resume"])
    }

    func testUnconfirmedPauseNeverSendsPlay() async {
        let entered = expectation(description: "Unconfirmed pause attempted")
        let probe = MediaCommandProbe(entered: entered, resumed: nil, result: #"{"status":"unconfirmed"}"#)
        let playback = DictationMediaPlayback { action, receipt in await probe.run(action, receipt) }
        playback.begin()
        await fulfillment(of: [entered], timeout: 5)
        playback.end()
        await probe.completePause()
        playback.finishPending()
        let calls = await probe.calls
        XCTAssertEqual(calls, ["pause"])
    }
}

private actor MediaCommandProbe {
    let entered: XCTestExpectation
    let resumed: XCTestExpectation?
    let result: String
    private(set) var calls: [String] = []
    private let pauseGate = TestGate()

    init(entered: XCTestExpectation, resumed: XCTestExpectation?,
         result: String = #"{"status":"paused","receipt":{"test":true}}"#) {
        self.entered = entered
        self.resumed = resumed
        self.result = result
    }

    func run(_ action: String, _ receipt: String?) async -> String {
        calls.append(action)
        if action == "pause" {
            entered.fulfill()
            await pauseGate.wait()
            return result
        }
        XCTAssertNotNil(receipt)
        resumed?.fulfill()
        return #"{"status":"resumed"}"#
    }

    func completePause() async {
        await pauseGate.open()
    }
}
