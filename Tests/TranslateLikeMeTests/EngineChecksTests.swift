import XCTest
@testable import TranslateLikeMe

@MainActor
final class EngineChecksTests: XCTestCase {
    func testLeavingSetupCancelsProbesAndMakesUnfinishedChecksRestartable() async {
        let cancelled = expectation(description: "The in-flight probe received cancellation")
        let gate = TestGate()
        let checks = EngineChecks(probe: { _ in
            await withTaskCancellationHandler {
                await gate.wait()
                return .working
            } onCancel: {
                cancelled.fulfill()
            }
        })
        checks.check(.anthropic)
        XCTAssertEqual(checks.health[.anthropic], .checking)
        checks.cancelAll()
        XCTAssertNil(checks.health[.anthropic], "An unfinished check must be eligible for a new visit")
        await fulfillment(of: [cancelled], timeout: 5)
        await gate.open()
    }
}
