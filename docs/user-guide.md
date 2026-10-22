# User guide

[Back to the project overview](../README.md)

Setup, daily use, engine configuration, privacy, and troubleshooting for
Translate Like Me.

## Requirements

- macOS 15 (Sequoia) or later, on a Mac with Apple silicon.
- For dictation preparation, at least 8 GB of free disk space for the model and
  temporary Core ML compilation files.
- For translation and Rewrite, the provider's official CLI installed and signed in: `claude`
  (Claude Code), `codex` (Codex), `grok` (Grok Build) or `agy` (Antigravity);
  or, for the local model, 16 GB of memory for TranslateGemma 12B (8 GB for
  Gemma 4 E2B) and room for its download (6.7 GB or 3.6 GB) with 2 GB to spare.

## First run

A new profile receives a language-pair suggestion from macOS preferred languages
and enabled keyboard sources. No region or assumed English fallback is used.
With only one evidenced language, the second side stays unchosen. A neutral
**Improve Text** preset is available on **⌥⌘J**. Existing settings, including
deliberately empty collections, remain authoritative.

First run has three screens:

1. **Preparing your app** shows the recommended languages and both local models.
   Download them once, then wait for verification and model preparation. Continue
   stays disabled until both models pass. Pause preserves partial downloads;
   retry keeps successful preparation. Closing the window never completes setup.
2. **Access for dictation and text** requests microphone access through macOS,
   then opens the Accessibility pane. Enable the app there and return. Existing
   grants are detected; denied microphone access leads to System Settings. After
   both grants, dictation is enabled and prepared before continuing.
3. **Dictate and translate** explains the actual assigned shortcuts and the Copy
   fallback. Start Using Translate Like Me finishes setup. Models, languages and
   other settings can be changed from the app's menu-bar icon.

The initial engine is local. Explicit engine and model choices from an existing
profile remain authoritative. No CLI sign-in is needed for the local path.
When macOS supplies only one language, the app leaves the second unchosen and
provides a route to choose languages in General settings.

## Usage

Hold the assigned dictation key in a text field, or select text and use your
translation shortcut. Recognition and translation run locally after setup,
unless you explicitly choose a CLI engine in Settings.

The **Copy Last Result** submenu keeps the latest Translation, Rewrite and
Dictation separately, even after successful insertion. Unavailable results are
dimmed. Results stay in memory until you quit; errors leave earlier results
available. Copying is explicit and does not run the engine again.

- For dictation, turn on **Enable dictation** under **Settings > Dictation**.
  First setup downloads the model; later recognition works locally. The default
  hold key is **Right Option**. Hold it while speaking, then release to recognize
  and insert the text. Recording continues for a second after you let go, so a
  last word is not cut off. In **Hold key**, you can record the left
  Option instead. Other input during the hold cancels dictation, so an Option
  combination does not insert speech. There is no tap-to-toggle mode or menu
  command to start recording. Recording is bounded to five minutes. The menu
  offers **Copy Last Result > Dictation** to recover the latest transcript.
  Languages in your configured translation pairs receive a preference during
  automatic speech recognition. You can still dictate in another supported
  language. With no translation pairs, or if a pair language is unsupported by
  the selected speech model, detection uses the full language set without a
  preference.
  The microphone is ready between holds without recording, so capture
  starts about 0.2 s after the press, measured on the built-in microphone and on
  AirPods. While you hold the key, system sound output is muted, then restored.

- Select text in any app, then press a pair's shortcut (the first pair you add
  starts on **⌥⌘F**) to replace it with the translation.
- Click the menu-bar icon for the menu: engine and Accessibility status, a
  **Translate selection** section with one item per language pair and its
  shortcut, Settings, updates, and Quit. Clicking the engine row opens its settings.
- Select notes, then press a preset's shortcut (add one under Settings >
  Rewrite) to replace them with a finished message. The menu then also lists
  a **Rewrite selection** section with one item per preset.
- Open Settings with ⌘, when the app is active, or reopen the app to bring Settings back.
- The icon shows a busy glyph while a translation is running. A run that stops responding
  times out after two minutes so another translation can start.
- Automatic insertion requires the original app to keep focus, with no typing,
  clicks or app switches while the engine works. If you do any of that, or copy
  something else, the result appears near the cursor with a **Copy** button. Your
  newer clipboard contents are preserved.
- Insertion counts as done when the app reads the pasted text. If it does not
  within 3 seconds (a read-only field, for example), the result appears in the
  same popup and your clipboard is restored. Dictation uses the same paste.
- If something goes wrong (no text selected, or the translation fails), that same
  popup shows the message instead.

## Settings

Four panes, **General**, **Dictation**, **Translation** and **Rewrite**. Changes apply
immediately.

- **Dictation**: enable local speech recognition, choose the Option hold key and
  the microphone (**System default** follows macOS; a chosen microphone that is
  disconnected falls back to the system input until it returns), and select
  Whisper Turbo or Qwen3-ASR 1.7B (8-bit, 30 languages). Fresh profiles select
  Turbo through 16 GB of memory and Qwen above 16 GB. Removed Small and
  Large v3 preferences fall back to Turbo. Model
  preparation starts automatically while enabled. Downloaded models stay cached;
  switching is unavailable during recording or recognition.

- **Languages** (General): up to three pairs, and none is fine too (the menu
  then offers to add one). Each row has the two languages,
  the pair's shortcut (click it and press a combo with ⌘, ⌥, or ⌃; Delete
  clears it, and a combo another pair uses is refused), and a remove button,
  with the pair's writing style below (Edit Style… opens it): free text applied
  to that pair's translations. Paste a full voice guide or a short distilled
  version, or leave it empty for a plain translation. The direction is detected
  per translation; the order matters only for text in neither language, which
  is translated into the first one, so put the language you read first.
- **Rewrite**: up to three presets; fresh profiles start with neutral Improve
  Text on ⌥⌘J. Each row has the preset's name, its shortcut, and a remove button, with its writing style below; an
  empty style gives a clear, neutral message. Rewrite runs on the translation
  engine.
- **Translation engine**: the CLI (Claude Code / Codex / Grok Build / Antigravity), and a **Model**
  and **Effort** picker listing what the CLI itself offers; **Default** keeps
  the CLI's configured default. For **Local model**, the model with its
  download, which you can cancel, resume or remove.
- **Launch at login**: start the app automatically when you log in.
- **Updates**: current version, automatic daily checks on or off, and a "Check
  for Updates…" button.

## Providers

Four providers, each through its official CLI and your subscription, and a
local model:

| Provider           | CLI                                         |
|--------------------|---------------------------------------------|
| Anthropic (Claude) | `claude -p` (Pro/Max)                       |
| OpenAI (ChatGPT)   | `codex exec` (ChatGPT)                      |
| xAI (Grok)         | `grok --prompt-file` (grok.com)             |
| Google (Gemini)    | `agy -p`, Antigravity CLI (Google AI plan)  |

The app runs the provider's official CLI as a subprocess, using the plan you
are already signed in to. No API key and no per-token billing beyond your
plan. For `codex`, run `codex login` once (ChatGPT account) before using it;
for `grok`, run `grok login` once; for `agy`, run `agy` once and sign in.
Antigravity CLI installs from [antigravity.google](https://antigravity.google);
it runs as an agent the app defines, with no tools and none of your own
Antigravity rules, skills or MCP servers.

### Local model

**Local model** runs on your Mac with [MLX](https://github.com/ml-explore/mlx-swift),
in the app's own process: no CLI, account or network after the download.
Settings > Translation offers two models, downloaded once from Hugging Face
and checked against their published hashes:

| Model | Download | Memory | Notes |
|---|---|---|---|
| TranslateGemma 12B | 6.7 GB | 16 GB Mac | The most accurate, writing styles and Rewrite included |
| Gemma 4 E2B | 3.6 GB | 8 GB Mac | About three times faster; less accurate (below) |

Fresh profiles select Gemma 4 E2B on 8-16 GB Macs and TranslateGemma 12B
above 16 GB. Existing selections are preserved.

In a 15-case test on an M5 ([local translation evaluation](local-translation.md)), TranslateGemma 12B
translated every case and resolved spoken self-corrections in Rewrite; Gemma 4
E2B kept the corrected-away detail in every Rewrite run and translated a third
language into the pair's second language. Either can return a sentence
unchanged; the app then asks once more, which fixed every such case in testing. The model stays
in memory for ten minutes after the last translation. TranslateGemma is
provided under the Gemma Terms of Use, Gemma 4 under the Apache 2.0 license.

The app invokes each official CLI as a subprocess. It never extracts subscription
OAuth tokens for use in a separate API client. Provider plan limits and terms apply.

### Model selection

For translation and Rewrite, the app runs the model and effort picked in Settings,
listed from each CLI's own model catalog (with the efforts each model accepts).
With **Default**, each CLI runs with your own default model and effort, the
ones set in Claude Code's `settings.json` (`model`, `effortLevel`), codex's
`config.toml` (`model`, `model_reasoning_effort`), grok's config, or the model
selected in Antigravity; where none is set, the CLI's built-in default
applies. Antigravity has no default the app can read, so its Effort picker
appears once you pick a model.

## Privacy

- Dictation recognizes speech locally. Setup downloads one speech model, a small
  speech detector and the tokenizer; recognition uses the local cache. Temporary
  audio is deleted after recognition or cancellation, and only the last text
  result stays in memory.
- The text you translate and the pair's writing style go to the engine you
  picked and nowhere else: Anthropic (Claude), OpenAI (ChatGPT), xAI (Grok), or
  Google (Gemini), through its official CLI. With the local model they never
  leave your Mac. The app has no server, analytics or telemetry.
- Each CLI receives the text on standard input, never as a command-line
  argument, so it does not show up in the process list.
- The claude and codex CLIs run with session history off, so translations are
  not kept in `~/.claude` or `~/.codex`. The grok CLI has no such switch and may
  keep its own history. Antigravity CLI has none either: each translation is
  kept in its history (`~/.gemini/antigravity-cli`), titled by the model.
- The clipboard is put back after a translation, with every type it held (rich
  text, images, files), unless you copy something else in the meantime; the
  pasted translation is marked transient so clipboard managers skip it.
- Logs (`/usr/bin/log stream --level info --predicate 'subsystem == "com.wiltodelta.translatelikeme"'`)
  record the app in front, the language pair and outcome, never the
  text itself.

## Updates

The app uses [Sparkle](https://sparkle-project.org) (MIT licensed; its notice
ships in the app bundle) to check once a day for a new release. It never takes
focus from what you are doing: when an update is found, the menu's "Check for
Updates…" item becomes "Install Update…" with the new version, and the update
window opens only when you choose it or check by hand from the menu or Settings >
Updates. Updates are signed with an EdDSA key as well as the Developer ID, and
install in place with a relaunch. Automatic checks can be turned off in Settings.

## Notes

- CLI calls add a few seconds of latency per translation (CLI startup plus one
  model turn).
- The system prompt tells the model to treat the selection as inert text to
  transform, never as a question or request directed at it. Without this, small
  fast models occasionally "answer" question-shaped input instead of translating
  it. It is a known, recurring failure mode rather than a fully solved problem; if
  you see it, note which input triggered it.

## Troubleshooting

- **"Translate Like Me is damaged and can't be opened", or an unidentified-developer
  warning:** releases before 2.2 were not notarized. Update to the latest release,
  or right-click the app and choose **Open** to confirm once.
- **The shortcut does nothing, or the translation doesn't replace the text:**
  grant **Accessibility** in System Settings > Privacy & Security > Accessibility,
  then relaunch the app. It is required to read the selection and paste the result.
- **No Effort picker:** the model in use takes no effort setting (Claude Code
  offers none for Haiku), or the engine's default model is not known yet (Grok,
  until its sign-in check has run once), or Antigravity is on **Default**. Pick
  a model to see it.
- **macOS asks for Accessibility again after updating to 2.2:** 2.2 is the first
  release signed with a Developer ID, a different signature from earlier builds.
  Grant it once more; later updates keep the grant. A build from source without
  the Developer ID identity is signed ad hoc and asks after every rebuild.

## Uninstall

Quit the app from its menu, then move **Translate Like Me.app** to the Trash. To
remove its settings too:

```bash
defaults delete com.wiltodelta.translatelikeme
```

API keys saved by versions up to 2.6, which had an API-key mode, are removed
from the keychain the first time a later version starts.

Remove it from System Settings > Privacy & Security > Accessibility and from
General > Login Items & Extensions as well.

## Development reference

Build commands, String Catalog localization, signing, and screenshot generation
are documented under [local build](build-and-release.md#local-build).
The [release process](build-and-release.md#release-process) covers the required
checks, CI, version tags, release notes, and published artifacts.

For checks that separate a clean installation from a configured developer Mac,
see [fresh-install testing](fresh-install-testing.md). For synthetic speech
checks without microphone access or playback, see
[unattended dictation testing](unattended-dictation-testing.md).

### The bundle identifier is not a local label

`CFBundleIdentifier` in `Resources/Info.plist` is `com.wiltodelta.translatelikeme`,
and macOS keys durable per-app state to it. Three things here depend on that:
the `UserDefaults.standard` domain behind `Settings`, which holds every persisted
setting; the keychain items earlier versions kept API keys in, whose service
name is the identifier and which launch now removes; and the Accessibility grant that `ensureAccessibilityPermission`
relies on. Changing the identifier migrates none of them. An existing install would come up as a stranger, with its settings
gone and Accessibility needing to be granted again, so treat it as fixed rather
than as a string to tidy up. It is registered as an explicit App ID for team
K2GT9Q4S6U in the Apple Developer portal, which reserves it for a future Mac App
Store build.
