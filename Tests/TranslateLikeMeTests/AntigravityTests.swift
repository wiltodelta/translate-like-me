import XCTest
@testable import TranslateLikeMe

// Payloads captured from agy 1.4.2 on 2026-10-19.
final class AntigravityTests: XCTestCase {
    private let modelsOutput = """
        Fetching available models...
        gemini-4-argon-medium\tGemini 4 Argon (Medium)
        gemini-4-argon-high\tGemini 4 Argon (High)
        gemini-4-argon-low\tGemini 4 Argon (Low)
        gemini-3.8-flash-high\tGemini 3.8 Flash (High)
        gemini-3.8-flash-low\tGemini 3.8 Flash (Low)
        gpt-oss-120b-medium\tGPT-OSS 120B (Medium)
        custom-model\tCustom Model
        """

    private let success = """
        {"event":"init","conversation_id":"71008db9","init":{"agent":"translatelikeme","tools":["view_file"]}}
        {"event":"step_update","step_update":{"step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":"Не могли бы в"}}
        {"event":"result","result":{"conversation_id":"71008db9","status":"SUCCESS","response":"Не могли бы вы прислать мне этот файл к завтрашнему дню?\\n","num_turns":1}}
        """

    // agy takes the model and the effort apart (`--model gemini-3.8-flash
    // --effort low`), so each listed model-and-effort line becomes an effort.
    func testModelsAreGroupedWithTheirEfforts() {
        let catalog = HarnessModels.parseAntigravity(modelsOutput)
        XCTAssertEqual(catalog.models.map(\.id),
                       ["gemini-4-argon", "gemini-3.8-flash", "gpt-oss-120b", "custom-model"])
        XCTAssertEqual(catalog.models.map(\.name),
                       ["Gemini 4 Argon", "Gemini 3.8 Flash", "GPT-OSS 120B", "Custom Model"])
        XCTAssertEqual(catalog.efforts(for: "gemini-4-argon"),
                       [.init(id: "low", name: "Low"), .init(id: "medium", name: "Medium"),
                        .init(id: "high", name: "High")])
        XCTAssertEqual(catalog.efforts(for: "gemini-3.8-flash")?.map(\.id), ["low", "high"])
        XCTAssertEqual(catalog.efforts(for: "gpt-oss-120b")?.map(\.id), ["medium"])
        XCTAssertEqual(catalog.efforts(for: "custom-model"), [])
        XCTAssertNil(catalog.defaultModel)
        XCTAssertEqual(HarnessModels.parseAntigravity("Error: Please sign in to view available models."),
                       HarnessCatalog())
    }

    func testSignInProbeReadsTheModelsCommand() {
        let provider = Provider.antigravity
        XCTAssertEqual(provider.statusArguments, ["models"])
        XCTAssertTrue(provider.isSignedIn(statusOutput: modelsOutput.lowercased(), exitCode: 0))
        let signedOut = "Fetching available models...\nError: Please sign in to view available models. "
            + "Launch the CLI without arguments to sign in."
        XCTAssertFalse(provider.isSignedIn(statusOutput: signedOut.lowercased(), exitCode: 1))
        XCTAssertFalse(provider.isSignedIn(statusOutput: "", exitCode: 1))
    }

    func testTheResultEventCarriesTheAnswer() throws {
        XCTAssertEqual(try Antigravity.response(inStream: success),
                       "Не могли бы вы прислать мне этот файл к завтрашнему дню?\n")
    }

    func testAnErrorResultIsAFailure() {
        let stream = """
            {"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"authentication failed or timed out"}}
            """
        XCTAssertThrowsError(try Antigravity.response(inStream: stream)) { error in
            XCTAssertEqual(error.localizedDescription, "authentication failed or timed out")
        }
        XCTAssertThrowsError(try Antigravity.response(inStream: "")) { error in
            XCTAssertEqual(error.localizedDescription, "The Antigravity CLI returned no result.")
        }
    }

    func testALimitInTheResultEventIsALimit() {
        let stream = """
            {"event":"result","result":{"status":"ERROR","response":"","error":"Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 96h39m4s."}}
            """
        XCTAssertThrowsError(try Antigravity.response(inStream: stream)) { error in
            XCTAssertTrue(error is LimitReachedError, "\(error)")
        }
    }

    // The safety filter's notice arrives as a successful response.
    func testAFilteredResponseIsNotPastedAsATranslation() {
        let stream = """
            {"event":"result","result":{"status":"SUCCESS","response":"This request was blocked by Gemini's filters. They can occasionally trigger by mistake on safe coding, security, or biology-related queries. Please try rephrasing your prompt.\\n","num_turns":1}}
            """
        XCTAssertThrowsError(try Antigravity.response(inStream: stream)) { error in
            XCTAssertEqual(error.localizedDescription, "This request was blocked by Gemini's filters.")
        }
    }

    func testTheMessageIsOneStreamJSONLine() throws {
        let prompt = "Rules: \"quoted\"\nInput: Привет\nOutput:"
        let line = Antigravity.streamMessage(prompt)
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.dropLast().split(separator: "\n").count, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(json["event"] as? String, "user")
        let message = try XCTUnwrap(json["message"] as? [String: Any])
        XCTAssertEqual(message["role"] as? String, "user")
        XCTAssertEqual(message["content"] as? String, prompt)
    }

    // The fields that keep the user's configuration and every tool out of a run.
    func testTheWorkspaceHoldsTheIsolatedAgent() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("agy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(try Antigravity.workspace(in: base), base)
        let file = base.appendingPathComponent(".agents/agents/translatelikeme/agent.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\nname: translatelikeme\n"))
        for field in ["excludeDefaultComponents: true", "inheritCustomizations: false", "inheritMcp: false",
                      "tools: []", "mainAgent: true", "subagent: false"] {
            XCTAssertTrue(text.contains("\n\(field)\n"), field)
        }
        // An unchanged file is left alone.
        let marked = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: marked], ofItemAtPath: file.path)
        _ = try Antigravity.workspace(in: base)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, marked)
    }

    func testQuotaAndSignInFailuresAreRecognized() {
        let stderr = """
            error: Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 96h39m4s.
            AGY_ERROR: {"short_error":"RESOURCE_EXHAUSTED (code 429): Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 96h39m4s.","status":"RESOURCE_EXHAUSTED","error_code":429}
            """
        XCTAssertEqual(LimitDetector.message(in: stderr),
                       "Individual quota reached. Please upgrade your subscription to increase your limits. "
                        + "Resets in 96h39m4s.")
        XCTAssertTrue(SignInDetector.matches("Error: authentication required. Run 'agy' to log in, then retry."))
        XCTAssertEqual(Provider.antigravity.notSignedInHint, "Not signed in to Antigravity. Run agy in Terminal.")
    }
}
