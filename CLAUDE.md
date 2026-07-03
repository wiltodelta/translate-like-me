# Translate Like Me

macOS menu-bar app that translates the current selection via a global hotkey,
auto-detecting the direction between two configured languages and applying the
user's writing style. Swift, SwiftUI + AppKit, SwiftPM, macOS 14+, no external
dependencies.

## How to run / build

- **Build and assemble the app bundle:** `./build.sh`. It runs `swift build -c
  release`, copies the binary and `Resources/` into `Translate Like Me.app`, and
  code-signs it.
- **CRITICAL:** `swift build` alone updates only `.build/release/`; it does NOT
  refresh the binary inside `Translate Like Me.app`. Always run `./build.sh`
  before installing or testing the bundle, otherwise you run a stale binary.
- **Install for local use:** quit the running app, replace
  `/Applications/Translate Like Me.app`, relaunch. It is a menu-bar accessory
  (no Dock icon).
- Code signing uses a stable self-signed identity ("Translate Like Me Dev", see
  the comment in `build.sh`) so the Accessibility (TCC) grant survives rebuilds.
  If the identity is missing, it falls back to ad-hoc and macOS re-prompts.

## Architecture

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

## Release process

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist` (the single source
   of the app version) and `CFBundleVersion`.
2. `./build.sh`, then
   `ditto -c -k --sequesterRsrc --keepParent "Translate Like Me.app" "Translate Like Me.zip"`.
3. `gh release create vX.Y "Translate Like Me.zip" --title "Translate Like Me X.Y" --target main --notes "..."`.
4. The tag must match the version (`v1.2` <-> `1.2`) and the `.zip` must be
   attached, or the in-app updater has nothing to offer.

## Code quality

- Lint: `swiftlint` (config in `.swiftlint.yml`, scans `Sources/`, 120-column
  lines). Build check: `swift build -c release`. Tests: `swift test`. All three
  must be clean before a commit.
- Tests cover the pure logic (`UpdateChecker.isNewer`, `Shortcut` formatting,
  `ModelResolver` model selection). UI, Accessibility, CGEvent, and CLI-subprocess
  code is not unit-tested.
- The build is self-signed for personal use, not notarized. Gatekeeper warns on
  other machines; fine for personal installs.
