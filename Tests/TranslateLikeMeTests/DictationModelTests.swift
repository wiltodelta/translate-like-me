import Foundation
import XCTest
@testable import TranslateLikeMe

@MainActor
final class DictationModelTests: XCTestCase {
    func testCatalogListsFluidSpeechProTurboAndQwenInCoverageOrder() {
        XCTAssertEqual(DictationModel.allCases, [.fluidSpeechPro, .turbo, .qwen3ASR])
        XCTAssertEqual(DictationModel.fluidSpeechPro.title, "Fluid Speech Pro (8-bit)")
        XCTAssertEqual(DictationModel.turbo.title, "Whisper large-v3-turbo")
        XCTAssertEqual(DictationModel.qwen3ASR.title, "Qwen3-ASR 1.7B (8-bit)")
        XCTAssertEqual(DictationModel.fluidSpeechCodes.count, 25)
    }

    func testRemovedModelPreferenceFallsBackToTurboWithoutChangingOtherChoices() {
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        for (stored, expected) in [("parakeetUltra", DictationModel.turbo), ("unknown", .turbo),
                                   ("small", .turbo), ("turbo", .turbo), ("largeV3", .turbo),
                                   ("fluid-speech-pro", .fluidSpeechPro), ("qwen3ASR", .qwen3ASR)] {
            var domain = saved
            domain["dictationModel"] = stored
            defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
            XCTAssertEqual(defaults.string(forKey: "dictationModel"), stored)
            XCTAssertEqual(Settings.dictationModel, expected, "Stored model: \(stored)")
        }
    }

    func testFluidSubsamplingStateComputesStridedValidFrameCounts() {
        let state = FluidSubsamplingState(hopLength: 160)
        state.setInputSamples(16_000) // 100 valid mel frames -> 50 -> 25 -> 13
        XCTAssertEqual(state.validFrames(stage: 1), 50)
        XCTAssertEqual(state.validFrames(stage: 2), 25)
        XCTAssertEqual(state.validFrames(stage: 3), 13)

        state.setInputSamples(24_000) // 150 valid mel frames -> 75 -> 38 -> 19
        XCTAssertEqual(state.validFrames(stage: 1), 75)
        XCTAssertEqual(state.validFrames(stage: 2), 38)
        XCTAssertEqual(state.validFrames(stage: 3), 19)
    }
}
