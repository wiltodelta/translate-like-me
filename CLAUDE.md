# Translate Like Me

You are a **principal Swift/macOS engineer** maintaining a menu-bar app that
translates the current selection via global hotkeys, one per language pair (up
to three), auto-detecting the direction and applying the user's writing style,
and rewrites selected rough notes into a finished message in the same language
with named Rewrite presets (up to three), plus local multilingual dictation.
SwiftUI + AppKit, SwiftPM; Sparkle for updates, WhisperKit and MLX Audio Swift for local ASR, MLX for the
local translation model. Supports the
three latest macOS releases (15+) on Apple silicon only.

Shared rules for our macOS apps: `~/Documents/GitHub/claude-config/docs/macos-apps.md`; this file states only what differs.

## Build and release

Assemble the bundle with `./build.sh` (needs Xcode 26+: `actool` compiles the
Icon Composer icon); `swift build` alone leaves a stale binary inside
`Translate Like Me Dev.app`. Releases are driven by `vX.Y.Z` git tags through GitHub
Actions, which signs with the Developer ID from repository secrets and
notarizes (`notarize.sh`), then bumps the cask in `wiltodelta/homebrew-tap`;
locally `build.sh` signs with the same identity from the keychain. The
website `translatelikeme.com` is `site/index.html` on GitHub Pages, its DNS
and mail forwarding in Cloudflare. Full
detail, including the secrets and where the keys are kept (1Password):
`docs/build-and-release.md`.

## Code quality

- `bash maintain.sh` runs the canonical Swift gate.
- The app manifest uses SwiftPM tools 6.2; MLX Swift requires Swift 6.3.
  CI's Swift 6.3.3 supports it. Keep swift-collections at 1.6.0, since 1.7
  requires Swift 6.4. Swift 6 language mode and macOS 15 remain unchanged.
- `build.sh` builds MLX's Metal kernels with CMake, embeds the current graph's
  materialized SDK resource bundles and packages upstream license notices.
  Do not glob old build bundles: stale FluidAudio output can remain after removal.
  MLX looks for `mlx.metallib` only beside the executable, not in
  `Contents/Resources`: call `MLXKernels.use()` before any MLX model loads.
- CI can lag local Swift. In subprocess tests, use explicit `@Sendable` task
  closures, a precomputed deadline and the concrete test type: the dynamic `Self`
  form failed Swift 6.3.3's region-based isolation checker.
- A closure stored as a plain `async` function type runs off the main thread even
  when written in a `@MainActor` type's `static let`; the compiler accepted a
  main-only Text Input Sources call there and the app trapped (2026-10-20). Give
  such properties a `@MainActor` function type.
- Lint config in `.swiftlint.yml` scans `Sources/` and `Tests/` at 120-column lines (fixtures inside multiline strings exempt, `Tests/.swiftlint.yml`).
- `Tests/TranslateLikeMeTests/` covers pure logic, selection orchestration with
  injected effects, and `ProcessRunner` with synthetic subprocesses. Hold an
  injected `sleep` with `TestGate`, and assert the pre-sleep state before awaiting
  it: a mutant that never sleeps otherwise hangs `swift test` until killed. UI,
  Accessibility, CGEvent and Sparkle require native verification; render UI changes with
  `./capture-screenshots.sh` (it also regenerates `screenshots/`, light and
  dark, flipping the system to Dark Mode and back; needs
  Accessibility and Screen Recording for the terminal and a Mac left alone).
  ScreenCaptureKit composites only the app and an opaque backdrop, excluding
  unrelated windows, alerts and the Dock. A closed or resized target fails the
  capture; Settings activation settles before the frame and backdrop are measured.
  Inspect every generated image. System Events `entire contents`
  does not reach the SwiftUI controls in Settings: press them by walking
  `AXUIElement` children and matching the title or accessibility label. A
  picker is an `AXPopUpButton` (its value is the selection): press it, then
  press the `AXMenuItem` by title, and read the result back from the
  defaults (`plutil -extract languagePairs raw`, base64 JSON) rather than
  sending keys, which land in whatever app is in front. System Events
  `keystroke` maps characters through the active layout: under Russian a
  `keystroke "k" using command down` and a typed name went into a Slack draft
  instead (2026-10-20). Send `key code` values, and never drive another
  person's conversation; verify dictation delivery by the user's own dictation
  and the `Dictation destination` and `read ... after N ms` log lines.
- A build without `RELEASE=1` is `com.wiltodelta.translatelikeme.dev`: its own
  settings domain, login item and Accessibility grant (granted once), so it
  runs beside the installed app; if both have the same shortcuts set, quit one
  before testing them. Override a setting for one launch with the argument
  domain (`open -n "Translate Like Me Dev.app" --args -provider grok`). Onboarding
  opens with `-didCompleteFirstRun NO -languagePairs '<5b5d>'` (no pairs). The
  bundle is hardened, so lldb cannot attach: read a crash's stack from
  `~/Library/Logs/DiagnosticReports/TranslateLikeMe-*.ips` (JSON after the
  first line).
  A standalone AX probe must touch `NSApplication.shared` first: without a
  window server connection the system-wide element answered
  `kAXErrorCannotComplete` for every frontmost app (2026-10-20).
  Probe engine CLIs with `env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN
  -u ANTHROPIC_BASE_URL`, or the harness's own variables redirect `claude`.
  Check a prompt change live with a temporary XCTest that calls
  `Translator.translate` or `Translator.rewrite` behind an env-var guard
  (`swift test --filter`, three runs per case, delete it after), rather than
  by pressing hotkeys: keystrokes land in whatever window is in front.
  Check the local engine live the same way: set `GPU.metallib` to the built
  app's `Contents/Resources/mlx.metallib` and pass `LocalModelFiles(base:)` the
  dev domain's `Application Support/.../Translation`; xctest's bundle has neither.
  Check paste delivery the same way: drive `SelectionWorkflow` with
  `LiveSelectionAccess` against a disposable AppKit window, snapshotting and
  restoring the user's clipboard around any marker it seeds. Chrome's key
  window can be the user's own window rather than a tab opened for the check,
  so Copy posted to Chrome's pid lands there (2026-10-20).
  Every `agy` probe or live test lands in Antigravity's history
  (`~/.gemini/antigravity-cli`); deleting its summary rows does not stick (agy
  restores them at startup), so keep live agy runs few.
  `-AppleInterfaceStyle Dark` in the argument domain does not darken the app;
  render Dark Mode by flipping the system appearance, as `capture-screenshots.sh` does.
  A standalone microphone probe gets the dev bundle's grant only as an `.app`
  with the dev bundle id, Developer ID signature, hardened runtime and the
  audio-input entitlement, launched with `open -W -n --stdout`; a bare binary
  reads not-determined. Make a Bluetooth probe refuse unless the default input
  is Bluetooth: AirPods dropped off the Mac mid-session and a run silently
  measured the built-in microphone. Prove which input a probe recorded by its
  frames, not `kAudioDevicePropertyDeviceIsRunningSomewhere`: another process
  held the built-in microphone running before a probe started (2026-10-21).
  Measure latency in a release build: `swift test -c release --arch arm64
  --build-system native -Xswiftc -enable-testing --filter <probe>` (debug MLX
  hides CPU-side costs; this rebuilds the release tree, about 6 minutes). Load
  models for such probes from an APFS clone (`cp -cR`) of the installed cache,
  never from the installed domain itself. A microphone probe built from the
  worker's sources stays off the speakers when launched with
  `-dictationMutedOutputDevice probe-none` (argument domain): the mute sees a
  pending record and never engages.
  A fresh worktree's first `swift build` or `./build.sh` compiles MLX past the
  10-minute tool timeout; run it detached (`nohup caffeinate -dimu ... > log &`).
  A `.build` cloned into another worktree
  fails release builds until `.build/arm64-apple-macosx/release/ModuleCache` is
  deleted, because its modules embed the old path.

## Interface

The UI follows Apple's Human Interface Guidelines; read the relevant HIG page
before changing a surface. Secondary text the app draws uses
`Color.secondaryText` (primary at 0.66 opacity), never `.secondary`, which the
SwiftLint rule `no_system_secondary_text` refuses: the system style measured
3.88-3.93:1 on the settings forms (2026-10-11), under 4.5:1.
The result popup uses an opaque semantic backing because glass could not keep
text above 4.5:1 across desktop colors and tint settings (2026-10-17). watch-me-sleep and rota use the same token.
Deviation from the global rules: the status menu's section headers and disabled
rows stay as NSMenu draws them (about 1.9:1 in light), since the app does not
draw them.

## Localization

The interface ships in English (the development language), ru, de, fr, es,
ja, zh-Hans, pt-BR, it and ko. Strings live in `Resources/Localizable.xcstrings`
(`InfoPlist.xcstrings` for the microphone prompt); the app target compiles
with `-emit-localized-strings` (`Package.swift`, so dependencies write none),
and `build.sh` runs `scripts/sync-strings.py`, which syncs the catalog in
place and fails on a stale string, a missing or unreviewed translation, a
format specifier that differs from the English, or InfoPlist English that
differs from `Info.plist`. A new string therefore needs all nine translations
before the bundle builds (`--prune-stale` removes strings the code dropped).
Write AppKit text as `String(localized:)` and pass SwiftUI literals straight
to `Text`/`Button`: `+` between literals, or a ternary mixing a literal with a
`String`, yields a plain `String` that is never localized. Compose no
sentence from fragments whose grammar depends on each other (gender, case);
give each variant its own string (`PopupController.ResultKind`, `ShortcutOwner`). Prompts sent
to the engines, log lines, product names and CLI commands stay English.
System Settings paths use Apple's own name per language: the `.loctable`
files of the matching pane in `/System/Library/ExtensionKit/Extensions/` and
AppKit's `MenuCommands.loctable` give them (`plutil -convert json`).
Render a localization with `CAPTURE_LANGUAGE=de CAPTURE_OUT=<dir>
./capture-screenshots.sh`; German runs longest. Add translations by script
with `json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True,
separators=(",", " : "))` and no trailing newline, byte-identical to what
`xcstringstool sync` writes.

## Rules and conventions

Topic-specific rules live in `.claude/rules/*.md` and are auto-loaded when
matching files are touched.

| File | Covers |
|------|--------|
| `dictation.md` | Minimal local dictation, model installation, recording, cancellation, and delivery at the current focus |
| `architecture.md` | Status item and its menu, settings panes, onboarding and its engine checks, global hotkey, language pairs and Rewrite presets, selection validation, the paste shared with dictation and clipboard ownership, CLI providers and the local MLX engine, and update checking |
