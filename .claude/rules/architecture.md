---
globs: Sources/**, Resources/**, Tests/**
description: App architecture -- custom NSStatusItem versus MenuBarExtra, the Carbon global hotkey path, paste-landed editability detection, provider and model resolution, and update checking
---

# Architecture

Relocated verbatim from the repo root `CLAUDE.md`. Read before editing this domain.

- `AppDelegate` owns a custom `NSStatusItem`. A custom status item is used
  instead of SwiftUI's `MenuBarExtra` because MenuBarExtra cannot show a separate
  right-click menu. Left click opens a borderless `NSPanel` (`MenuBarPanel`);
  right click pops up an `NSMenu`.
- Global hotkey via Carbon `RegisterEventHotKey` (`HotKeyManager`), default
  ⌥⌘F. `TranslationController` copies the selection, translates, and pastes back.
- `SelectionService.pasteLanded` decides editability *after* the paste (re-copy
  the selection; if it still holds the original text, the field is read-only).
  Read-only targets get the translation on the clipboard plus a `PopupController`
  popup instead of a silent lost paste.
- Providers: Claude (`claude` CLI or Anthropic API) and ChatGPT (`codex` CLI or
  OpenAI API), selected in Settings, plus OpenCode (`opencode run --pure`,
  account-free). Per-provider facts live as `Provider` properties
  (`displayName`, `shortName`, `cliBinaryName`, and the `supportsAPIKey` /
  `requiresSignIn` capabilities that views and checks gate on), not as
  `== .opencode` special cases. `ModelResolver` resolves the model live; it is
  never pinned in the app. OpenCode: `big-pickle` from opencode's models.dev
  cache, falling back to the newest `-free` zen model; auth mode is ignored for
  it (zen answers anonymously, verified 2026-08-17), and the child env is
  stripped of `OPENCODE_*`/`SUPERCONDUCTOR_*` so a harness wrapper cannot
  inject config. Expect 15-60s latency: the anonymous zen tier queues.
- Exhausted-limit failures surface as `LimitReachedError`: `LimitDetector`
  (LimitReached.swift) matches real CLI/API payloads (claude prints its limit
  line on stdout, codex on stderr) and `PopupController.showLimitReached` shows
  the engine's reset time with an Open Settings action. `EngineStatus` stays
  sign-in-based: `claude usage` is too slow (~26s) for proactive checks.
- `UpdateChecker` checks GitHub Releases on launch and from Settings.
