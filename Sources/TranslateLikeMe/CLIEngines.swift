import Foundation
import os

private let log = Logger.app("cli")

// Each adapter owns a CLI's flags and wire format. Process lifetime and error
// presentation are shared; an invocation is inspectable without launching a CLI.
protocol CLIAdapting {
    func invocation(system: String, text: String, choice: HarnessChoice) -> CLIInvocation
}

enum CLIEngines {
    static func adapter(for provider: Provider) -> any CLIAdapting {
        switch provider {
        case .anthropic: ClaudeAdapter()
        case .openai: CodexAdapter()
        case .grok: GrokAdapter()
        case .antigravity: AntigravityAdapter()
        case .local: preconditionFailure("The local engine has no CLI adapter")
        }
    }

    static func run(system: String, text: String, provider: Provider,
                    resolution: HarnessResolution? = nil) async throws -> String {
        guard let binary = await Translator.binaryPath(name: provider.cliBinaryName) else {
            throw TranslatorError.binaryNotFound(provider.cliBinaryName)
        }
        let resolution = resolution ?? HarnessResolution.current(for: provider)
        // Never log prompts, selected text, credentials or process arguments.
        log.info("""
            CLI \(provider.rawValue, privacy: .public), \
            model source \(resolution.modelSource.rawValue, privacy: .public), \
            effort source \(resolution.effortSource.rawValue, privacy: .public)
            """)
        let invocation = adapter(for: provider).invocation(system: system, text: text, choice: resolution.choice)
        return try await invocation.run(binary: binary)
    }
}

struct CLIInvocation {
    let arguments: [String]
    let input: String
    let format: Provider

    static func envelope(system: String, text: String) -> String {
        system + "\n\nInput: " + text + "\nOutput:"
    }

    var answerStream: (any CLIAnswerStream.Type)? {
        switch format {
        case .anthropic: ClaudeStream.self
        case .openai: CodexStream.self
        case .grok: GrokStream.self
        case .antigravity, .local: nil
        }
    }

    func run(binary: String, directory: URL? = nil) async throws -> String {
        let workingDirectory = try directory ?? (format == .antigravity ? Antigravity.workspace() : nil)
        let output = try await ProcessRunner.run(binary: binary, arguments: arguments, input: input,
            environment: Translator.toolEnvironment(adding: format.cliEnvironment), directory: workingDirectory,
            answered: answerStream?.isAnswered)
        guard output.status == 0, answerStream?.failed(in: output.stdout) != true else {
            throw FailureDetail.error(output: answerStream?.plain(output) ?? output, input: input)
        }
        let answer: String
        if format == .antigravity {
            answer = try Antigravity.response(inStream: output.stdout)
        } else {
            guard let text = answerStream?.answer(in: output.stdout) else {
                throw TranslatorError.failed(String(localized: """
                    The CLI response format was not recognized. Update the command-line tool and try again.
                    """))
            }
            answer = text
        }
        return try Translator.cleaned(answer)
    }
}

struct ClaudeAdapter: CLIAdapting {
    func invocation(system: String, text: String, choice: HarnessChoice) -> CLIInvocation {
        // `claude -p` is an agent harness, not a bare model endpoint: by default it
        // prepends ~20-30k tokens on every invocation - tool definitions, all of the
        // user's MCP server schemas, and their global/project CLAUDE.md - to what is
        // a tiny translation, adding several seconds of latency. Measured input drops
        // from ~10k+ tokens (~5-8s) to ~150 tokens (~2.4s, on Sonnet) with all three
        // stripped:
        //   --tools ""            no built-in tool schemas
        //   --strict-mcp-config   no MCP servers (none passed via --mcp-config)
        //   --setting-sources ""  no settings and, crucially, no CLAUDE.md
        // Dropping CLAUDE.md is also correct on its own: the user's working
        // instructions there should never leak into or steer the translation. This
        // is NOT extended thinking - the model does one short turn.
        // --no-session-persistence: claude would otherwise keep every selection
        // in ~/.claude/projects indefinitely.
        // The result event ends the run (ClaudeStream).
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--system-prompt", system,
                    "--tools", "", "--strict-mcp-config", "--setting-sources", "",
                    "--no-session-persistence"]
        // The model and effort picked in Settings, else the user's defaults from
        // their Claude Code settings, which --setting-sources "" would otherwise
        // drop (HarnessChoice, HarnessDefaults).
        if let model = choice.model { args += ["--model", model] }
        if let effort = choice.effort { args += ["--effort", effort] }
        return CLIInvocation(arguments: args, input: text, format: .anthropic)
    }
}

struct CodexAdapter: CLIAdapting {
    func invocation(system: String, text: String, choice: HarnessChoice) -> CLIInvocation {
        // Like `claude -p`, `codex exec` is an agent harness:
        //   --ignore-user-config   don't load ~/.codex/config.toml (disables all MCP
        //                          servers in one flag; auth still uses CODEX_HOME)
        //   --ignore-rules         don't load execpolicy `.rules` files
        // Global $CODEX_HOME/AGENTS.md still applies. A synthetic loopback
        // request on codex 0.164 confirmed that project_doc_max_bytes=0 does
        // not suppress it. Keep the original auth home; never copy its token.
        // Investigation and compatibility procedure: docs/provider-support.md.
        // The model and reasoning effort are the ones picked in Settings, else the
        // user's own defaults from that config, passed back explicitly
        // (HarnessChoice, HarnessDefaults).
        // --ephemeral keeps the selection out of ~/.codex/sessions. codex is an
        // agent with tools on by default, so text from a web page could talk it
        // into reading local files: the sandbox is read-only and every tool that
        // reads, runs or browses is off (feature names from `codex features list`,
        // codex-cli 0.156.1, checked 2026-09-24). `-c features.<name>=false`, not
        // `--disable`: codex rejects an unknown `--disable` name outright, so a
        // renamed feature would break every translation; an unknown `-c` key only
        // warns.
        // --json: events on stdout, the final message in the last agent item (CodexStream).
        var args = ["exec", "--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                    "--ephemeral", "-s", "read-only"]
        for feature in ["shell_tool", "unified_exec", "browser_use", "browser_use_external",
                        "computer_use", "image_generation", "apps", "view_image", "multi_agent",
                        "plugins", "in_app_browser"] {
            args += ["-c", "features.\(feature)=false"]
        }
        if let model = choice.model { args += ["-m", model] }
        if let effort = choice.effort { args += ["-c", "model_reasoning_effort=\(effort)"] }
        // "-": the prompt comes on stdin, so the selection is not in the process
        // list the way a command-line argument is.
        args += ["-"]
        return CLIInvocation(arguments: args, input: CLIInvocation.envelope(system: system, text: text),
                             format: .openai)
    }
}

struct GrokAdapter: CLIAdapting {
    func invocation(system: String, text: String, choice: HarnessChoice) -> CLIInvocation {
        // `grok -p` is an agent harness too. Measured 2026-09-22 (grok 1.0.41,
        // default model grok-4.7, a one-line ru<->en translation):
        //   defaults                                  ~28k input tokens, ~6-7s,
        //                                             and it may browse the cwd
        //                                             instead of translating
        //   Provider.grok.cliEnvironment              no imported rules, skills,
        //                                             MCP, memory or workflows
        //   --tools X --disallowed-tools X            an empty allowlist: `--tools ""`
        //                                             is ignored, and --disallowed-tools
        //                                             alone leaves always-on tools
        //   prompt envelope + --verbatim              the system prompt alone did not
        //                                             stop it answering the input
        // Together: ~5.7k tokens and correct output; 4-6s at the model's default
        // effort (2026-09-23; ~3.4s when it was forced to low). Errors go to
        // stderr, exit 1; streaming-json events carry the answer (GrokStream).
        // `--prompt-file /dev/stdin` is the single-turn mode of `-p` with the prompt
        // on stdin, so the selection stays out of the process list (as for codex);
        // same output and latency as `-p` (grok 1.0.50, 2026-10-11).
        var args = ["--prompt-file", "/dev/stdin", "--verbatim", "--output-format", "streaming-json",
                    "--system-prompt-override", system,
                    "--tools", "todo_write", "--disallowed-tools", "todo_write",
                    "--no-subagents", "--max-turns", "1"]
        // grok applies its own config defaults; only a pick made in Settings is passed.
        if let model = choice.model { args += ["-m", model] }
        if let effort = choice.effort { args += ["--reasoning-effort", effort] }
        return CLIInvocation(arguments: args, input: CLIInvocation.envelope(system: system, text: text), format: .grok)
    }
}

struct AntigravityAdapter: CLIAdapting {
    func invocation(system: String, text: String, choice: HarnessChoice) -> CLIInvocation {
        var args = ["--agent", Antigravity.agentName, "--disable-slash-commands",
                    "--input-format", "stream-json", "--output-format", "stream-json", "-p="]
        if let model = choice.model {
            args += ["--model", model]
            if let effort = choice.effort { args += ["--effort", effort] }
        }
        return CLIInvocation(arguments: args,
                             input: Antigravity.streamMessage(CLIInvocation.envelope(system: system, text: text)),
                             format: .antigravity)
    }
}
