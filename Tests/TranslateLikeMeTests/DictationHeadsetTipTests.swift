import XCTest
@testable import TranslateLikeMe

final class DictationHeadsetTipTests: XCTestCase {
    func testTipIsDueAtMostOncePerHour() {
        var tip = DictationHeadsetTip()
        let start = ContinuousClock.now
        let at = { (minutes: Int64) in start.advanced(by: .seconds(minutes * 60)) }
        XCTAssertTrue(tip.due(at: at(0)))
        XCTAssertFalse(tip.due(at: at(59)), "Not again within the hour")
        XCTAssertTrue(tip.due(at: at(60)))
        XCTAssertFalse(tip.due(at: at(61)), "A shown tip restarts the hour")
    }
}
