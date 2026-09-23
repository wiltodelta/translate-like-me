import Foundation
import XCTest
@testable import TranslateLikeMe

final class ModelResolverTests: XCTestCase {
    func testPickAnthropicPrefersSonnet() {
        let ids = ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5"]
        XCTAssertEqual(ModelResolver.pick(provider: .anthropic, from: ids), "claude-sonnet-4-6")
    }

    func testPickOpenAIExcludesSpecialisedMinis() {
        // audio / realtime variants contain "mini" but must be skipped.
        let ids = ["gpt-5.4-audio-mini", "gpt-5.4-realtime-mini", "gpt-5.4-mini", "gpt-5.4"]
        XCTAssertEqual(ModelResolver.pick(provider: .openai, from: ids), "gpt-5.4-mini")
    }

    func testPickOpenAIPrefersLuna() {
        let ids = ["gpt-6-astra", "gpt-6-luna", "gpt-5.4-mini", "gpt-5.6-luna"]
        XCTAssertEqual(ModelResolver.pick(provider: .openai, from: ids), "gpt-6-luna")
    }

    func testPickGrokHasNoAPIModel() {
        XCTAssertNil(ModelResolver.pick(provider: .grok, from: ["grok-4.7"]))
    }
}
