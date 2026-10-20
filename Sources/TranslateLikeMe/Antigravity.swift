import Foundation

// How a translation runs on Antigravity CLI (agy). agy has no flag for a system
// prompt, for switching tools off or for ignoring the user's configuration, so
// it runs as a custom agent the app defines in a workspace of its own. Measured
// 2026-10-19 (agy 1.4.2, a one-line ru<->en translation):
//   defaults in an empty directory    ~20.9k input tokens: the user's global
//                                     rules, skills and MCP servers, every tool,
//                                     under the user's own tool permission
//   this agent                        ~1k input tokens; asked to read a file it
//                                     reported only manage_task, list_resources
//                                     and read_resource, where the same agent
//                                     without excludeDefaultComponents and
//                                     `tools: []` read the file
// agy has no ephemeral mode: every run is kept in its own history
// (~/.gemini/antigravity-cli), left there by decision (2026-10-19).
enum Antigravity {
    static let agentName = "translatelikeme"

    // inheritCustomizations: false keeps the user's rules, skills, plugins,
    // subagents and MCP servers out; excludeDefaultComponents and `tools: []`
    // drop the default prompt sections and tools. The instructions travel in the
    // message (Translator.promptEnvelope), so this file never changes.
    static let agentDefinition = """
        ---
        name: \(agentName)
        description: Transforms the text in each message as the message's instructions say.
        mainAgent: true
        subagent: false
        excludeDefaultComponents: true
        inheritCustomizations: false
        inheritMcp: false
        tools: []
        ---
        # \(agentName)

        You are a text transformation engine, not an assistant. Each message holds \
        instructions followed by the input text. Follow those instructions and output only the result.

        """

    // The directory agy runs in, holding the agent at
    // `.agents/agents/<name>/agent.md`, where agy finds a project's agents.
    // Written only when missing or different, so parallel runs (onboarding
    // checks) find the same file.
    static func workspace(in base: URL = defaultBase) throws -> URL {
        let directory = base.appendingPathComponent(".agents/agents/\(agentName)", isDirectory: true)
        let file = directory.appendingPathComponent("agent.md")
        let contents = Data(agentDefinition.utf8)
        if (try? Data(contentsOf: file)) != contents {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try contents.write(to: file, options: .atomic)
        }
        return base
    }

    static var defaultBase: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.wiltodelta.translatelikeme")
            .appendingPathComponent("Antigravity", isDirectory: true)
    }

    // One `--input-format stream-json` line: the prompt arrives on stdin, so the
    // selection stays out of the process list.
    static func streamMessage(_ prompt: String) -> String {
        let message: [String: Any] = ["event": "user", "message": ["role": "user", "content": prompt]]
        let data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        return (String(bytes: data, encoding: .utf8) ?? "") + "\n"
    }

    // The answer in agy's `--output-format stream-json` output: the `result`
    // event's `response` when its status is SUCCESS, else its `error`. A
    // response Gemini's safety filter replaced still reports SUCCESS ("This
    // request was blocked by Gemini's filters. They can occasionally trigger by
    // mistake ...", agy 1.4.2), so it is a failure here rather than a translation.
    static func response(inStream output: String) throws -> String {
        let result = output.split(separator: "\n").reversed().lazy.compactMap { line -> [String: Any]? in
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["event"] as? String == "result" else { return nil }
            return json["result"] as? [String: Any]
        }.first
        guard let result else {
            throw TranslatorError.failed(String(localized: "The Antigravity CLI returned no result."))
        }
        guard result["status"] as? String == "SUCCESS" else {
            let error = result["error"] as? String ?? ""
            // A limit agy reports here rather than by its exit status still
            // gets the limit popup.
            if let limit = LimitDetector.message(in: error) { throw LimitReachedError(message: limit) }
            throw TranslatorError.failed(
                error.isEmpty ? String(localized: "The Antigravity CLI reported an error.") : error)
        }
        let response = result["response"] as? String ?? ""
        if response.hasPrefix("This request was blocked by") {
            // Its first sentence; the rest links to feedback and policy pages.
            throw TranslatorError.failed(response.firstIndex(of: ".").map { String(response[...$0]) } ?? response)
        }
        return response
    }
}
