import XCTest
@testable import TranslateLikeMe

final class DictationModelLanguageTests: XCTestCase {
    func testInventoriesNameWhatEachModelCannotRecognize() {
        XCTAssertEqual(DictationModel.qwen3ASR.unsupported(["am", "en", "am", "ru", "sw"]), ["am", "sw"])
        XCTAssertEqual(DictationModel.turbo.unsupported(["am", "en", "ru", "sw"]), [])
        XCTAssertEqual(DictationModel.qwen3ASR.unsupported(["fil", "zh-Hans", "pt-BR"]), [])
        XCTAssertEqual(DictationModel.turbo.unsupported(["chr"]), ["chr"])
    }

    func testCoveringKeepsThePreferredModelUnlessAnotherRecognizesMore() {
        XCTAssertEqual(DictationModel.covering(["ru", "en"], preferring: .qwen3ASR), .qwen3ASR)
        XCTAssertEqual(DictationModel.covering([], preferring: .qwen3ASR), .qwen3ASR)
        XCTAssertEqual(DictationModel.covering(["am", "en"], preferring: .qwen3ASR), .turbo)
        // Neither recognizes Cherokee; the preference stands.
        XCTAssertEqual(DictationModel.covering(["chr", "en"], preferring: .qwen3ASR), .qwen3ASR)
    }
}
