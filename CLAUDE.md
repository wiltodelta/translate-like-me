# Translate Like Me

You are a **principal Swift/macOS engineer** maintaining a menu-bar app that
translates the current selection via global hotkeys, one per language pair (up
to three), auto-detecting the direction and applying the user's writing style,
and rewrites selected rough notes into a finished message in the same language
with named Rewrite presets (up to three), plus local multilingual dictation.
SwiftUI + AppKit, SwiftPM; Sparkle for updates, WhisperKit and MLX Audio Swift for local ASR, MLX for the
local translation model.

Shared rules for our macOS apps: `~/Documents/GitHub/claude-config/docs/macos-apps.md`; this file states only what differs.

## Build and release

Assemble the bundle with `./build.sh` (needs Xcode 26+: `actool` compiles the
Icon Composer icon); `swift build` alone leaves a stale binary inside
`Translate Like Me Dev.app`. The app has a cask, which release CI bumps in
`wiltodelta/homebrew-tap`. The
product page is on Victor's personal website; `translatelikeme.com` only
redirects there and forwards mail, both in Cloudflare. Full
detail, including the secrets and where the keys are kept (1Password):
`docs/build-and-release.md`.

## Personal website

Victor's personal website (`wiltodelta/wiltodelta-app`, page
`/projects/translate-like-me/`) imports `screenshots/general.png`,
`screenshots/general-dark.png`, `website-content.json` and the README section
"Features" or "Speak first, polish afterwards" from the stable release tag.
Keep those paths and section alternatives in step with `releaseSource` in the
site's `src/data/project-catalog.json`.

At every release, compare the candidate with the previous published release
for icon, screenshot and visitor-facing description changes. Prepare the
website changes that apply, then propose their live publication before closing
the release task; a local rebuild alone does not settle that decision. Reuse
existing deployment approval when it covers these changes; otherwise ask once
with the concrete icon, screenshot and copy changes. If none apply, no website
deployment proposal is needed. The icon has a separate retained source in the
website: `build:products` does not update it. Follow the site's
`docs/product-updates.md`, "What product repositories owe the site", for asset
preparation, preview, approval and live verification.

## Code quality

- The app manifest uses SwiftPM tools 6.2; MLX Swift requires Swift 6.3.
  CI's Swift 6.3.3 supports it. Keep swift-collections at 1.6.0, since 1.7
  requires Swift 6.4. Swift 6 language mode and macOS 15 remain unchanged.
- `build.sh` builds MLX's Metal kernels with CMake, embeds the current graph's
  materialized SDK resource bundles and packages upstream license notices.
  Do not glob old build bundles: stale FluidAudio output can remain after removal.
  MLX looks for `mlx.metallib` only beside the executable, not in
  `Contents/Resources`: call `MLXKernels.use()` before any MLX model loads.
- In subprocess tests, use explicit `@Sendable` task closures, a precomputed deadline and the concrete test type: the dynamic `Self`
  form failed Swift 6.3.3's region-based isolation checker.
- Give a closure property of a `@MainActor` type a `@MainActor` function type:
  a plain `async` function type runs off the main thread even in a `static let`.
- Hold an injected `sleep` with `TestGate`, and assert the pre-sleep state
  before awaiting it: a mutant that never sleeps otherwise hangs `swift test`
  until killed.
- UI, Accessibility, CGEvent and Sparkle require native verification. Render UI
  changes with `./capture-screenshots.sh`; it also regenerates `screenshots/`,
  light and dark, flipping the system to Dark Mode and back, and needs
  Accessibility and Screen Recording for the terminal and a Mac left alone.
- Check a change with the `CAPTURE_*_ONLY` mode it reaches (listed at the top
  of the script); the full run is only for a screen without a mode or the
  script's shared steps. A failed capture saves the screen, the app's
  windows and AX geometry under `$TMPDIR/translate-like-me-capture-failures/`:
  diagnose from that, not a rerun.
- The capture uses ScreenCaptureKit, which composites only the app and an
  opaque backdrop, excluding unrelated windows, alerts and the Dock. A closed
  or resized target fails the capture; Settings activation settles before the
  frame and backdrop are measured.
- `-AppleInterfaceStyle Dark` in the argument domain does not darken the app;
  render Dark Mode by flipping the system appearance, as
  `capture-screenshots.sh` does.
- System Events `entire contents` does not reach the SwiftUI controls in
  Settings: press them by walking `AXUIElement` children and matching the
  title or accessibility label.
- A picker is an `AXPopUpButton` (its value is the selection): press it, then
  press the `AXMenuItem` by title, and read the result back from the defaults
  (`plutil -extract languagePairs raw`, base64 JSON) rather than sending keys,
  which land in whatever app is in front.
- System Events `keystroke` maps characters through the active layout: send
  `key code` values, and never drive another person's conversation.
- Verify dictation delivery by the user's own dictation and the
  `Dictation destination` and `read ... after N ms` log lines.
- A standalone AX probe must touch `NSApplication.shared` first, or the
  system-wide element answers `kAXErrorCannotComplete`.
- The dev bundle id is `com.wiltodelta.translatelikeme.dev`, with its own
  Accessibility grant (granted once); if it and the installed app have the
  same shortcuts set, quit one before testing them.
- Override a setting for one launch with the argument domain
  (`open -n "Translate Like Me Dev.app" --args -provider grok`). Onboarding
  opens with `-didCompleteFirstRun NO -languagePairs '<5b5d>'` (no pairs).
- The bundle is hardened, so lldb cannot attach: read a crash's stack from
  `~/Library/Logs/DiagnosticReports/TranslateLikeMe-*.ips` (JSON after the
  first line).
- Probe engine CLIs with `env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN
  -u ANTHROPIC_BASE_URL`, or the harness's own variables redirect `claude`.
- Time a CLI by its answer event, not its exit: read its JSON stream in raw
  chunks (`docs/cli-translation-latency.md`). `claude --bare` refuses
  subscription auth, so it cannot replace the translation flags.
- Check a prompt change live with a temporary XCTest that calls
  `Translator.translate` or `Translator.rewrite` behind an env-var guard
  (`swift test --filter`, three runs per case, delete it after), rather than
  by pressing hotkeys: keystrokes land in whatever window is in front.
- Check the local engine live the same way: set `GPU.metallib` to the built
  app's `Contents/Resources/mlx.metallib` and pass `LocalModelFiles(base:)` the
  dev domain's `Application Support/.../Translation`; xctest's bundle has
  neither.
- Check paste delivery the same way: drive `SelectionWorkflow` with
  `LiveSelectionAccess` against a disposable AppKit window, snapshotting and
  restoring the user's clipboard around any marker it seeds. Post Copy only to
  that window, never to another app's pid, whose key window can be the user's
  own.
- Every `agy` probe or live test lands in Antigravity's history
  (`~/.gemini/antigravity-cli`); deleting its summary rows does not stick (agy
  restores them at startup), so keep live agy runs few.
- A standalone microphone probe gets the dev bundle's grant only as an `.app`
  with the dev bundle id, Developer ID signature, hardened runtime and the
  audio-input entitlement, launched with `open -W -n --stdout`; a bare binary
  reads not-determined.
- Make a Bluetooth probe refuse unless the default input is Bluetooth, and
  prove which input a probe recorded by its frames, not
  `kAudioDevicePropertyDeviceIsRunningSomewhere`.
- A microphone probe built from the worker's sources stays off the speakers
  when launched with `-dictationMutedOutputDevice probe-none` (argument
  domain): the mute sees a pending record and never engages.
- Measure latency in a release build: `swift test -c release --arch arm64
  --build-system native -Xswiftc -enable-testing --filter <probe>`; debug MLX
  hides CPU-side costs. Load probe models from an APFS clone (`cp -cR`) of the
  installed cache, never from the installed domain; a Python mlx-audio probe
  also needs the pinned revision's remaining small files in the clone
  (`snapshot_download(..., ignore_patterns=["*.safetensors"])`). Before timing,
  read GPU load (`ioreg -r -d 1 -c IOAccelerator`, `Device Utilization %`) and
  the load average (`sysctl -n vm.loadavg`).
- Candidate benchmarks and their method: `docs/local-model-candidates.md`;
  survey candidates by sweeping publishers' Hugging Face listings by date.
- A fresh worktree's first `swift build` or `./build.sh` compiles MLX past the
  10-minute tool timeout; run it detached (`nohup caffeinate -dimu ... > log &`).
- A `.build` cloned into another worktree fails release builds until
  `.build/arm64-apple-macosx/release/ModuleCache` is deleted, and `build.sh`
  until `.build/mlx-metal` is, because both embed the old path.

## Interface

Secondary text uses `Color.secondaryText`, and the result popup keeps an opaque
semantic backing instead of glass, both to hold 4.5:1 contrast.

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
