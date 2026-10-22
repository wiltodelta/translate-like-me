import XCTest
@testable import TranslateLikeMe

@MainActor
final class OnboardingFlowTests: XCTestCase {
    func testBothModelsAndSequentialPermissionConsentAreRequiredBeforeCompletion() async {
        let fixture = Fixture()
        let flow = OnboardingFlow(effects: fixture.effects)
        flow.continueFromPreparation()
        XCTAssertEqual(flow.step, .preparation)
        XCTAssertFalse(flow.finish())
        XCTAssertEqual(fixture.calls, [])
        flow.prepare()
        await flow.operation?.value
        XCTAssertEqual(fixture.calls, ["speech", "translation"])
        XCTAssertTrue(flow.modelsReady)
        XCTAssertEqual(fixture.completed, 0)
        flow.continueFromPreparation()
        XCTAssertEqual(flow.step, .permissions)
        XCTAssertFalse(flow.finish())
        flow.permissionAction()
        await flow.operation?.value
        XCTAssertEqual(fixture.calls.last, "microphone")
        XCTAssertEqual(fixture.openedAccessibility, 0)
        XCTAssertEqual(flow.step, .permissions)
        flow.permissionAction()
        XCTAssertEqual(fixture.openedAccessibility, 1)
        XCTAssertEqual(fixture.completed, 0)
        fixture.trusted = true
        flow.refreshPermissions()
        flow.permissionAction()
        await flow.operation?.value
        XCTAssertEqual(fixture.calls.last, "activate")
        XCTAssertEqual(flow.step, .usage)
        XCTAssertEqual(fixture.completed, 0)
        XCTAssertTrue(flow.finish())
        XCTAssertEqual(fixture.completed, 1)
    }

    func testFailedTranslationCannotAdvanceAndRetryKeepsPreparedSpeech() async {
        let fixture = Fixture()
        fixture.failTranslation = true
        let flow = OnboardingFlow(effects: fixture.effects)
        flow.prepare()
        await flow.operation?.value
        XCTAssertEqual(flow.speech, .ready)
        XCTAssertNotEqual(flow.translation, .ready)
        XCTAssertNotNil(flow.error)
        flow.continueFromPreparation()
        XCTAssertEqual(flow.step, .preparation)
        XCTAssertFalse(flow.finish())
        fixture.failTranslation = false
        flow.prepare()
        await flow.operation?.value
        XCTAssertEqual(fixture.calls, ["speech", "translation", "translation"])
        XCTAssertTrue(flow.modelsReady)
        XCTAssertNil(flow.error)
    }

    func testPauseDrainsPreparationAndDoesNotCompleteOrTreatLateProgressAsReady() async {
        let fixture = Fixture()
        let gate = TestGate()
        let started = expectation(description: "Speech preparation entered")
        fixture.speechGate = gate
        fixture.speechStarted = { started.fulfill() }
        let flow = OnboardingFlow(effects: fixture.effects)
        flow.prepare()
        await fulfillment(of: [started], timeout: 2)
        flow.pause()
        XCTAssertTrue(flow.running)
        flow.prepare()
        await gate.open()
        await flow.operation?.value
        XCTAssertFalse(flow.running)
        XCTAssertFalse(flow.modelsReady)
        XCTAssertEqual(flow.step, .preparation)
        XCTAssertEqual(fixture.completed, 0)
        XCTAssertEqual(fixture.calls, ["speech"])
        XCTAssertEqual(fixture.cancelledDownloads, 0, "Speech preparation must not cancel a Settings download")
    }

    func testPausingTranslationCancelsThatDownloadAndKeepsSpeechReady() async {
        let fixture = Fixture()
        let gate = TestGate()
        let started = expectation(description: "Translation preparation entered")
        fixture.translationGate = gate
        fixture.translationStarted = { started.fulfill() }
        let flow = OnboardingFlow(effects: fixture.effects)
        flow.prepare()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(flow.speech, .ready)
        flow.pause()
        XCTAssertEqual(fixture.cancelledDownloads, 1)
        await gate.open()
        await flow.operation?.value
        XCTAssertEqual(flow.speech, .ready)
        XCTAssertEqual(flow.translation, .waiting)
        XCTAssertFalse(flow.modelsReady)
    }

    func testDeniedMicrophoneGoesToSystemSettingsAndRevocationBlocksFinish() async {
        let fixture = Fixture()
        fixture.allowMicrophone = false
        let flow = OnboardingFlow(effects: fixture.effects)
        flow.prepare()
        await flow.operation?.value
        flow.continueFromPreparation()
        flow.permissionAction()
        await flow.operation?.value
        XCTAssertTrue(flow.microphoneDenied)
        flow.permissionAction()
        XCTAssertEqual(fixture.openedMicrophone, 1)
        XCTAssertEqual(fixture.calls.filter { $0 == "microphone" }.count, 1)
        fixture.mic = true
        fixture.trusted = true
        flow.permissionAction()
        await flow.operation?.value
        XCTAssertEqual(flow.step, .usage)
        fixture.trusted = false
        XCTAssertFalse(flow.finish())
        XCTAssertEqual(flow.step, .permissions)
        XCTAssertEqual(fixture.completed, 0)
    }

    func testChangedModelInvalidatesBothReadinessAndFinalInstruction() async {
        let fixture = Fixture()
        fixture.mic = true
        fixture.trusted = true
        let flow = OnboardingFlow(effects: fixture.effects)
        flow.prepare()
        await flow.operation?.value
        flow.continueFromPreparation()
        flow.permissionAction()
        await flow.operation?.value
        XCTAssertEqual(flow.step, .usage)
        flow.configurationChanged()
        XCTAssertEqual(flow.step, .preparation)
        XCTAssertFalse(flow.modelsReady)
        XCTAssertFalse(flow.finish())
        XCTAssertEqual(fixture.completed, 0)
    }
}

@MainActor
private final class Fixture {
    var calls: [String] = []
    var completed = 0
    var cancelledDownloads = 0
    var openedMicrophone = 0
    var openedAccessibility = 0
    var mic = false
    var trusted = false
    var allowMicrophone = true
    var failTranslation = false
    var speechGate: TestGate?
    var speechStarted: () -> Void = {}
    var translationGate: TestGate?
    var translationStarted: () -> Void = {}

    var effects: OnboardingFlow.Effects {
        .init(speech: { progress in
            self.calls.append("speech")
            self.speechStarted()
            if let gate = self.speechGate { await gate.wait() }
            progress(1)
        }, translation: {
            self.calls.append("translation")
            self.translationStarted()
            if let gate = self.translationGate { await gate.wait() }
            if self.failTranslation { throw OnboardingFailure(message: "Synthetic failure") }
        }, translationState: { .notDownloaded }, cancelDownload: { self.cancelledDownloads += 1 },
              microphoneGranted: { self.mic }, accessibilityGranted: { self.trusted },
              requestMicrophone: {
                  self.calls.append("microphone")
                  self.mic = self.allowMicrophone
                  return self.mic
              }, openMicrophoneSettings: { self.openedMicrophone += 1 },
              openAccessibilitySettings: { self.openedAccessibility += 1 },
              activateDictation: { self.calls.append("activate") }, complete: { self.completed += 1 })
    }
}
