---
paths:
  - "Sources/**"
  - "Resources/**"
  - "Tests/**"
description: App architecture -- the status item and its standard NSMenu, settings panes, the Carbon global hotkey path, paste-landed editability detection, Claude/Codex/Grok provider and model resolution, and update checking
---

# Architecture

Read before editing this domain.

- `AppDelegate` owns an `NSStatusItem` whose `menu` is `StatusMenu`, a standard
  `NSMenu` for both clicks. HIG (The menu bar, menu bar extras): "display a menu,
  not a popover"; the system draws the menu's material, appearance and
  accessibility. It is rebuilt on every open
  (`menuNeedsUpdate`), keeps the same items in every state (status rows change
  text, never disappear), and uses the standard `terminate(_:)` selector so
  macOS 26 supplies Quit's icon. Settings is an `NSTabViewController` in toolbar
  style (`SettingsTabViewController.makeWindow`, panes General and Translation,
  window title follows the pane, last pane restored unless a caller passes one
  in the `.openSettings` notification); `SettingsStore` applies every change
  immediately. The popup (`PopupController`) stays a cursor-anchored
  panel: HIG Writing wants errors "as close to the problem as possible".
- Global hotkey via Carbon `RegisterEventHotKey` (`HotKeyManager`), default
  ⌥⌘F. `TranslationController` copies the selection, translates, and pastes back.
  Each run logs its frontmost app, outcome, and failures through `os.Logger`:
  `/usr/bin/log stream --level info --predicate 'subsystem ==
  "com.wiltodelta.translatelikeme"'` (plain `log` is a zsh builtin).
- `SelectionService.pasteLanded` decides editability *after* the paste (re-copy
  the selection; if it still holds the original text, the field is read-only).
  Read-only targets get the translation on the clipboard plus a `PopupController`
  popup instead of a silent lost paste.
- Providers: Claude (`claude` CLI or Anthropic API), ChatGPT (`codex` CLI or
  OpenAI API), and Grok (`grok` CLI only), selected in Settings. Per-provider
  facts live as `Provider` properties (`displayName`, `shortName`,
  `cliBinaryName`, `cliProductName`, `loginCommand`, `apiKeyCopy`, the model
  summaries, `cliEnvironment`, `statusArguments` with
  `isSignedIn(statusOutput:exitCode:)`, and the `supportsAPIKey` capability that
  views and checks gate on), not as `== .grok` special cases;
  `Provider.effectiveAuthMode(_:)` is the auth mode that applies (CLI-only
  engines ignore a stored API-key mode).
- Subscription mode never picks a model. claude and codex run isolated from
  their user config, so `HarnessDefaults` reads just the user's default model and
  effort (claude `settings.json` `model`/`effortLevel`, codex `config.toml`
  `model`/`model_reasoning_effort`) and passes them back as flags; grok reads
  its own config. `ModelResolver` picks only for API-key mode (newest Sonnet, or
  OpenAI's `luna` fast tier, formerly `mini`). Known gap: codex still loads the
  global `$CODEX_HOME/AGENTS.md` into every translation (measured ~9.3k tokens
  for a 37 KB file, 2026-09-23); codex 0.156 has no flag for it (see
  `Translator.runCodex`).
- Grok runs with the `GROK_CLAUDE_*`/`GROK_CURSOR_*` compat cells off
  (`cliEnvironment`) and an empty tool allowlist, because otherwise it imports
  `~/.claude` rules, skills and MCP servers and may act as an agent instead of
  translating (flag rationale in `Translator.runGrok`). Its sign-in check is
  `grok models` output.
- Exhausted-limit failures surface as `LimitReachedError`: `LimitDetector`
  (LimitReached.swift) matches real CLI/API payloads (claude prints its limit
  line on stdout, codex on stderr; grok's limit payload is not yet captured)
  and `PopupController.showLimitReached` shows the engine's reset time with an
  Open Settings action. `EngineStatus` stays
  sign-in-based: `claude usage` is too slow (~26s) for proactive checks.
- `UpdateChecker` checks GitHub Releases on launch and from Settings.
