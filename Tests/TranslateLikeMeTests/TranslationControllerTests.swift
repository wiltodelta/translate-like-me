import XCTest
@testable import TranslateLikeMe

@MainActor
final class TranslationControllerTests: XCTestCase {
    func testProgressCoversSelectionAndDeliveryForBothActionsAndEveryOutcome() async {
        for kind in [PopupController.ResultKind.translation, .message] {
            for outcome in [SelectionOutcome.pasted, .result("ready"), .noSelection] {
                let probe = TranslationProbe()
                let entered = expectation(description: "Workflow entered")
                let gate = TestGate()
                var interaction = probe.interaction
                interaction.run = { actualKind, _ in
                    XCTAssertEqual(actualKind, kind)
                    XCTAssertEqual(probe.shown, [kind])
                    XCTAssertEqual(probe.hidden, 0)
                    XCTAssertTrue(TranslationActivity.shared.isBusy)
                    entered.fulfill()
                    await gate.wait()
                    return outcome
                }
                let controller = TranslationController(interaction: interaction)
                start(controller, kind: kind)
                await fulfillment(of: [entered], timeout: 2)
                XCTAssertEqual(probe.hidden, 0, "Progress stays visible while the workflow is suspended")
                await gate.open()
                await controller.operation?.value
                XCTAssertEqual(probe.hidden, 1)
                XCTAssertFalse(TranslationActivity.shared.isBusy)
                XCTAssertNil(controller.operation)
                XCTAssertEqual(probe.results, outcome == .result("ready") ? ["ready"] : [])
                XCTAssertEqual(probe.errors.count, outcome == .noSelection ? 1 : 0)
            }
        }
    }

    func testFailureAndLimitBothDismissProgressAndKeepTheirPresentation() async {
        for error in [TestFailure() as any Error, LimitReachedError(message: "limit")] {
            let probe = TranslationProbe()
            var interaction = probe.interaction
            interaction.run = { _, _ in throw error }
            let controller = TranslationController(interaction: interaction)
            start(controller)
            await controller.operation?.value
            XCTAssertEqual(probe.shown, [.translation])
            XCTAssertEqual(probe.hidden, 1)
            XCTAssertFalse(TranslationActivity.shared.isBusy)
            XCTAssertEqual(probe.limits, error is LimitReachedError ? ["limit"] : [])
            XCTAssertEqual(probe.errors.count, error is TestFailure ? 1 : 0)
        }
    }

    func testCancelButtonCancelsTaskSuppressesLateResultAndKeepsBusyUntilUnwound() async {
        let probe = TranslationProbe()
        let entered = expectation(description: "Workflow entered")
        let gate = TestGate()
        var calls = 0
        var interaction = probe.interaction
        interaction.run = { _, _ in
            calls += 1
            guard calls == 1 else { return .pasted }
            entered.fulfill()
            await gate.wait()
            XCTAssertTrue(Task.isCancelled)
            return .result("late result")
        }
        let controller = TranslationController(interaction: interaction)
        start(controller)
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertNotNil(probe.cancel)
        probe.cancel?()
        XCTAssertTrue(controller.operation?.isCancelled == true)
        start(controller, kind: .message)
        XCTAssertEqual(probe.shown, [.translation], "Another shortcut must not replace the busy indicator")
        XCTAssertTrue(TranslationActivity.shared.isBusy)
        await gate.open()
        await controller.operation?.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(probe.hidden, 1)
        XCTAssertTrue(probe.results.isEmpty)
        XCTAssertTrue(probe.errors.isEmpty)
        XCTAssertFalse(TranslationActivity.shared.isBusy)
        start(controller, kind: .message)
        await controller.operation?.value
        XCTAssertEqual(probe.shown, [.translation, .message], "A completed cancellation permits another action")
    }

    private func start(_ controller: TranslationController, kind: PopupController.ResultKind = .translation) {
        if kind == .message {
            controller.rewrite(preset: RewritePreset(name: "Test", shortcut: nil))
        } else {
            controller.run(pair: LanguagePair(first: "en", second: "ru", shortcut: nil))
        }
    }
}

private struct TestFailure: Error {}

@MainActor
private final class TranslationProbe {
    var shown: [PopupController.ResultKind] = []
    var hidden = 0
    var cancel: (() -> Void)?
    var errors: [String] = []
    var limits: [String] = []
    var results: [String] = []

    var interaction: TranslationInteraction {
        TranslationInteraction(showProgress: { self.shown.append($0); self.cancel = $1 },
                               hideProgress: { self.hidden += 1 },
                               showError: { self.errors.append($0) },
                               showLimit: { self.limits.append($0) },
                               showResult: { text, _ in self.results.append(text) },
                               run: { _, _ in .pasted })
    }
}
