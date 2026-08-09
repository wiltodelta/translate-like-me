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
  OpenAI API), selected in Settings. `ModelResolver` resolves the model live; it
  is never pinned in the app.
- `UpdateChecker` checks GitHub Releases on launch and from Settings.
