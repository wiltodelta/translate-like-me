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

Automated via GitHub Actions (`.github/workflows/build.yml`), same as the Watch
Me While I Fall Asleep app. The version comes from the git tag, not a manual
Info.plist bump:

1. `git tag -a vX.Y -m "Translate Like Me X.Y"` then `git push origin vX.Y`.
2. The workflow stamps `X.Y` into `Info.plist` (`CFBundleShortVersionString` and
   `CFBundleVersion`), runs SwiftLint and tests, builds via `build.sh`, zips as
   `TranslateLikeMe-vX.Y-macOS.zip`, and publishes a GitHub Release with it
   attached. `UpdateChecker` compares that tag to the installed version.

Local `./build.sh` bundles keep whatever version is committed in `Info.plist`;
they are for local use, not distribution. CI signs ad-hoc (the stable identity
is absent on the runner), which is expected.

## Code quality

- `bash maintain.sh` runs the full gate: `swiftlint lint --fix`, `swift test`,
  `swift build -c release` (same script and shared `.swiftlint.yml` rule set as
  the Watch Me While I Fall Asleep app).
- Lint: `swiftlint` (config in `.swiftlint.yml`, scans `Sources/`, 120-column
  lines). Build check: `swift build -c release`. Tests: `swift test`. All three
  must be clean before a commit.
- Tests cover the pure logic (`UpdateChecker.isNewer`, `Shortcut` formatting,
  `ModelResolver` model selection). UI, Accessibility, CGEvent, and CLI-subprocess
  code is not unit-tested.
- The build is self-signed for personal use, not notarized. Gatekeeper warns on
  other machines; fine for personal installs.
