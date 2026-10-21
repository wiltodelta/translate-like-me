import Foundation
import XCTest
@testable import TranslateLikeMe

@MainActor
final class DictationModelTests: XCTestCase {
    func testCatalogContainsOnlyTurboAndQwen() {
        XCTAssertEqual(Set(DictationModel.allCases), [.turbo, .qwen3ASR])
        XCTAssertFalse(DictationModel.turbo.title.contains("v3"))
    }

    func testRemovedModelPreferenceFallsBackToTurboWithoutChangingOtherChoices() {
        let defaults = UserDefaults.standard
        let saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        for (stored, expected) in [("parakeetUltra", DictationModel.turbo), ("unknown", .turbo),
                                   ("small", .turbo), ("turbo", .turbo), ("largeV3", .turbo),
                                   ("qwen3ASR", .qwen3ASR)] {
            var domain = saved
            domain["dictationModel"] = stored
            defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
            XCTAssertEqual(defaults.string(forKey: "dictationModel"), stored)
            XCTAssertEqual(Settings.dictationModel, expected, "Stored model: \(stored)")
        }
    }
}
