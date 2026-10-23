---
paths:
  - "Sources/**"
  - "Resources/**"
  - "Tests/**"
description: App architecture -- the status item and its standard NSMenu, settings panes, language pairs and Rewrite presets, the Carbon global hotkey path, selection validation and clipboard ownership, Claude/Codex/Grok/Antigravity provider and model resolution, the on-device MLX engine, and update checking
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
  style (`SettingsTabViewController.makeWindow`, panes General, Dictation,
  Translation and Rewrite, window title follows the pane, last pane restored unless a
  caller passes one in the `.openSettings` notification; a restored pane is
  not written back, a clicked or passed one is); `SettingsStore` applies every
  change immediately. Persisted `SettingsPane` IDs stay stable; tab identifiers
  map them to their visual position so reordering preserves the saved pane.
  Native pane-identity tests inject synthetic General content: constructing
  `GeneralSettingsView` starts Sparkle, whose missing XCTest bundle configuration
  can show a modal alert during later async tests.
  Tab identifiers must be strings: toolbar mode sends `isEqualToString:` to
  this untyped property. Explicit pane selection persists even when already selected.
  The standard app-menu Settings command and ⌘, call
  `AppDelegate.showSettings`, replacing the dummy SwiftUI Settings command.
  Reopening brings Settings forward, or the visible onboarding window.
  No control is focused when a pane opens
  (`SettingsTabViewController.clearFocus`): AppKit focused the Rewrite pane's
  first preset name with its text selected, so the next key renamed it. The
  window is a `SettingsWindow` that keeps every frame, the pane-switch
  animation steps included, inside the screen's visible frame, and
  a pane taller than the screen scrolls (`SettingsLayout.maxPaneHeight`) instead
  of running under the Dock. At `Languages.maxPairs` the Add Pair button stays,
  disabled, beside "Up to 3 pairs". The popup (`PopupController`) stays a cursor-anchored
  panel: HIG Writing wants errors "as close to the problem as possible". It never
  becomes key, so its Copy / Open Settings buttons are not keyboard-reachable; that
  is deliberate (decided 2026-09-28): taking focus would steal the field the user
  is typing in. A skipped insertion leaves the result available through Copy,
  without overwriting a newer user copy. `LastResults` retains one nonempty
  completed result per `PopupController.ResultKind` in memory, before paste;
  failures and cancellations keep the earlier result. StatusMenu's Copy Last
  Result submenu always lists Translation, Rewrite and Dictation, dimming missing
  results; it copies explicitly without rerunning an engine. Settings opens
  from the status menu. Its one action keeps the active accent
  (`appearsActive = true`), and a capped body fades at the bottom when more
  text is below. Its opaque `windowBackgroundColor` backing keeps text readable
  over arbitrary desktop colors and Liquid Glass settings. macOS 27 hides `NSMenuItem.image` unless `preferredImageVisibility
  = .visible`; the status rows and the updates item set it (`StatusMenu.showsImage`).
  A scheduled Sparkle check shows its own window only while the app is active, so a
  launch-time find is announced in the menu, not over the user's app.
- `Languages.all` derives languages from `Locale.availableIdentifiers`,
  each with its English `name` for the
  engine's prompt and a `displayName` in the interface language
  (`Bundle.main.preferredLocalizations`, not `Locale.current`, capitalized as
  a menu item) that the pickers and pair titles show and sort by, split by script where a
  language has several (not `Aran`, a Nastaliq style), Portuguese by region;
  stored codes are BCP 47. New pairs take languages from
  `Languages.suggestions`: system languages, then each enabled keyboard
  layout's primary language (TIS), without region or assumed English fallbacks.
  The first pair is the first two on ⌥⌘F; later pairs pair the first pair's
  first language with the next free suggestion. When suggestions run out the
  second language stays empty (`LanguagePair.isComplete` false): the picker
  shows "Choose a Language", the summary shows the unchosen side, and the menu item opens
  General, and a run shows a popup instead of translating. Completion requires
  both languages to be nonempty and distinct; an unchosen side never swaps an
  empty value into the other side. Long names reflow onto two rows through
  `ViewThatFits`, in both General and onboarding. Each side's picker
  is an `Equatable` `LanguagePicker` keyed on its code, so typing a pair's
  style does not rebuild a 300-item menu per keystroke.
- Language pairs (`LanguagePair`, up to `Languages.maxPairs` = 3, stored as JSON
  in `Settings.languagePairs`, edited under General > Languages) each carry an
  optional shortcut and writing style (`style`, empty for a plain translation;
  pairs may share languages); `HotKeyManager` registers one Carbon `RegisterEventHotKey`
  per pair and the status menu lists one item per pair under Translate selection
  (pairs sharing languages get a subtitle saying which applies a style).
  The model detects the direction: text in `first` becomes `second`, anything
  else becomes `first` (`Translator.systemPrompt`). On-device detection
  (`NLLanguageRecognizer`) was measured and rejected: constrained to ru/en it
  called Spanish and "Скинь PR по TranslateLikeMe" English at 1.00.
  `Settings.persistLanguagePairs()` runs first at launch and writes the pairs
  once: the pre-pairs `languageA`/`languageB`/`replaceKeyCode` (or ru/en ⌥⌘F for
  an earlier run that kept the defaults) for an existing user, none for a new
  one (`Settings.initialPairs`), and every pair may be removed after confirmation (the
  menu then shows "Add a Language Pair…"); `Settings.moveStyleIntoPairs()` then copies the
  earlier single global `style` into every pair when none has a style yet,
  and removes it.
  `TranslationController.run(pair:)` copies the
  selection, translates, and pastes back. Translation and Rewrite show the shared
  nonactivating `ActivityIndicator` at the bottom of the pointer's screen, with
  Translating / Rewriting and a Cancel button. `TranslationInteraction` injects
  selection execution and presentation for controller tests. Progress spans the
  selection lookup, engine and paste receipt; every exit hides it. Cancellation
  keeps the busy guard until unwinding, suppresses late results and errors, and
  checks cancellation after the AX lookup before sending Copy. Dictation uses
  the same panel and content geometry through `DictationIndicator`.
- Rewrite presets (`RewritePreset`, up to `Rewrite.maxPresets` = 3, stored as
  JSON in `Settings.rewritePresets`, edited in the Rewrite pane) each carry a name (the menu item's title; new ones are "Preset
  <n>"), an optional shortcut and a writing style. The shared RemoveButton confirms
  removal in RemovalConfirmation before deleting a pair or preset and its saved
  shortcut/style. Deletion runs after the sheet dismisses to preserve row bindings. StyleEditor
  names its text area with the localized pair/preset title. A preset never translates:
  the message stays in the notes' language and a pair's shortcut translates it
  afterwards. Presets are told apart by purpose, not language, as Apple's
  Writing Tools, Wispr Flow and DeepL Write tell theirs apart by tone, and
  because a language bound into each preset is what Superwhisper users ask to
  be rid of (an earlier draft here bound one, decided against 2026-10-08).
  `HotKeyManager.reload` installs the enabled dictation hold monitor first, then
  registers pairs and presets, skipping a combo already taken, and `SettingsStore.owner(of:except:)` refuses a combo either
  list uses. A row holding a `TextField` binds its item by id
  (`RewriteSettingsView.binding(for:)`), never by index through
  `ForEach($array)`: the field re-reads its binding during the resize
  animation after a removal and crashed past the shortened array. The menu
  adds a Rewrite selection section only while a preset exists. `TranslationController.rewrite(preset:)` shares the copy, engine and
  paste flow with `run(pair:)` (`perform`). `Rewrite.systemPrompt` keeps the
  notes' language even beside a received message in another (21 of 21 live
  runs, 2026-10-08), keeps questions for the recipient, drops filler and
  superseded self-corrections, treats the received message as context only,
  writes a name taken from it in the message's script ("Марк", 1 of 3 runs
  without that rule, 3 of 3 with it), and allows the recipient's name but no
  greeting word (10 of 21 runs opened "Hi Pete," without that rule, 0 of 12
  with it).
  Each run, translate or rewrite, logs its focused app, outcome, and
  failures through `os.Logger`: `/usr/bin/log stream --level info --predicate
  'subsystem == "com.wiltodelta.translatelikeme"'` (plain `log` is a zsh
  builtin). `swift test` logs to the same subsystem from `xctest`; add
  `process == "TranslateLikeMe"` when tallying real runs.
- `FirstRunRecommendations.apply` runs before the launch migrations. Only a new
  profile gets a language suggestion and a neutral Improve Text preset on
  Option-Command-J; existing or deliberately empty settings are authoritative.
  `didApplyFirstRunRecommendations` prevents reseeding after removal. Language
  evidence, local-model eligibility and remaining work: `docs/first-run-recommendations.md`.
- Onboarding (`Onboarding`, a `SettingsWindow` hosting an `NSHostingView`) uses
  three shipping screens: preparation, permissions, usage. `OnboardingFlow`
  owns transitions with injected effects. Both models must be verified and
  prepared before permissions; speech preparation runs without microphone
  access, unloads, then the local translation download and `EngineProbe` run.
  Only the final usage action writes `didCompleteFirstRun`; closing or pausing
  never completes it. Failed preparation retries, changes in Settings invalidate
  readiness, and revoked permissions block completion. The local engine is
  seeded only for fresh profiles; explicit choices remain authoritative.
  Microphone consent follows Continue; Accessibility opens on its own action,
  never at fresh launch. Dictation activates only after both grants. No Rewrite
  controls appear. The final screen uses actual shortcuts or offers setup in the
  matching Settings pane when unassigned. Failed preparation marks the model and
  shows primary error text with a warning symbol. Prominent actions share
  primaryActionTint, the system selection backing, with PrimaryActionColors
  choosing black or white text for contrast on bright and dark accents.
  Dev-only `onboardingPreview` plus `onboardingStage` renders the same views in
  synthetic states, with no network, TCC, microphone or completion writes.
  `EngineChecks` remains available for injected provider checks; `EngineProbe`
  verifies readiness plus a real synthetic translation, never CLI installation alone.
- `SelectionWorkflow` owns the copy/await/validate/paste/restore flow, with
  `LiveSelectionAccess` as its native adapter and injected effects in tests.
  Text reaches a field one way in the whole app (user decision 2026-10-20):
  `PasteDelivery`, shared with dictation, promises the string through
  `PasteReceipt`, posts Paste, and takes the destination's read as the delivery
  proof; it restores the clipboard 300 ms after the read and never before
  700 ms, and an unread paste (a read-only field) is shown with Copy after 3 s,
  never retried. `PasteAccess.destination()`, asked just before writing, is
  `SelectionTarget.destination`, the focused process unless a secure field
  holds focus; translation also requires it to be the original process, with
  no intervening typing, click or app activation (`SelectionActivity`). The
  live adapters share the pasteboard through `LivePasteAccess`. No AX element,
  range or value is compared: those checks failed in Chrome, Claude and Slack.
  The focused process is AX's system-wide focused application, else the
  frontmost app (`SelectionTarget.focusedPID`): frontmost Slack once left the
  former unanswered, and the copy guard read every run as no selection. A
  failed AX answer logs its error code.
  Copy and Paste events go to the original pid and carry an app marker so the
  activity monitor ignores them. Their key codes come from the ASCII-capable
  layout (`KeyboardLayout`), read on the main thread before the workflow starts,
  so Dvorak sends Cmd+C and Cmd+V rather than the ANSI codes' Cmd+J and Cmd+K.
  A newer clipboard change during the engine skips insertion and remains
  untouched. Restores put back the original rich clipboard only while the run
  still owns it. Skipped insertion shows the result with Copy and never claims
  it was copied.
  Selection diagnostics use the `selection` log category at notice level: copy
  timeout, focus and clipboard guards, the first invalidating activity class,
  the paste destination, and whether and when it read the paste. They record
  metadata only, never text.
  Filter by process id when both installed and dev copies run.
- `ProcessRunner` concurrently drains stdout/stderr and writes stdin through
  DispatchIO. A run is cancellable, with a 120-second translation deadline,
  10-second status/lookup deadlines and an 8 MiB combined-output cap. Cancellation
  and timeout kill the owned process group when isolated, otherwise the child,
  close its streams and await termination. Status transport failures remain
  failures rather than being reported as a signed-out account. claude, codex
  and grok answer 0.5-1.1 s before they exit, so translations read their JSON
  event streams (`CLIStreams.swift`) and `run(answered:)` returns at the
  answer, leaving the child to exit or be killed at the deadline. A failure
  still waits for the exit status and reaches `FailureDetail` in the shape of
  the CLI's plain output (claude's result text, codex's `ERROR:` lines).
- Providers: Claude (`claude` CLI), ChatGPT (`codex` CLI), Grok (`grok`
  CLI) and Antigravity (`agy` CLI), selected in Settings and named everywhere by
  their CLI (`Provider.name`: Claude Code, Codex, Grok Build, Antigravity), since
  the user picks and signs in to a CLI and agy serves more than Gemini; each runs on the user's subscription through its
  signed-in CLI (the API-key mode was removed; `Settings.removeAPIKeys()`
  deletes what it stored at launch). Per-provider facts live as `Provider`
  properties (`name`, `cliBinaryName`,
  `loginCommand`, the model summary, `cliEnvironment`, `statusArguments` with
  `isSignedIn(statusOutput:exitCode:)`, `probeReportsModels`), not as `== .grok`
  special cases.
- The fifth engine, `Provider.local` ("Local model"), runs a model on this Mac
  with MLX in process (`LocalEngine`); `usesCLI` is false and the CLI facts are
  never read for it. `LocalModel` pins TranslateGemma 12B (16 GB minimum)
  and Gemma 4 E2B with their turn formats. Fresh profiles recommend E2B through
  16 GiB and TranslateGemma above 16 GiB; `Settings.localModel` holds the pick,
  `LocalModelControls` shows it in the Translation pane, and
  `LocalModelDownloads` owns download, cancel and removal through the shared
  `ModelManagementView`. File ownership and both model managers: `docs/model-management.md`.
  `EngineStatus` checks the model's memory minimum before calling a verified download ready
  (`LocalModelFiles`: a marker
  and exact sizes; hashes are checked once, after downloading). The engine
  keeps one model resident and frees it after 10 idle minutes, on memory
  pressure, or when the model is switched. Each run reuses a copy of the KV cache
  of the instructions before the selection (`LocalModel.promptHead`,
  `MLXLoader.PromptHeads`, latest three), only when the prompt's tokens begin
  with the head's. Loading, generation and removal share
  an exclusive operation queue across awaits. Await the SDK producer before releasing
  model access; pressure during generation is remembered and applied after drain.
  A length-limited answer never replaces the selection. A translation that comes back
  unchanged is asked once more with the pair reversed
  (`Translator.translateLocally`; both models echoed English when it was the
  pair's second language). It shares Qwen dictation's `mlx.metallib`, which
  `MLXKernels.use()` points MLX at before either loads a model. Benchmark, prompt format, tokenizer
  check and build detail: `docs/local-translation.md`.
- Translations run the model and effort picked in Settings, else the CLI
  default (`HarnessChoice.current`). The pickers list `HarnessModels`, read from
  each CLI's own cache: claude `~/.claude/cache/model-catalog/<account>-cc.json`
  (per-model efforts; Haiku has none; `state.model` is its default), codex and
  grok `models_cache.json`; agy keeps no cache, so its list is the last `agy
  models` output (the sign-in probe), stored in `Settings.antigravityModels`,
  with `EngineStatus` publishing `.harnessModelsChanged` on the main actor
  after recording a probe's catalog. `SettingsStore` subscribes for its lifetime
  and reloads only the currently selected provider, including probes started
  by the status menu or onboarding; a late answer cannot replace another
  provider's catalog. The settings probe is injectable in unit tests.
  Antigravity's catalog has
  one line per model and effort (`gemini-3.8-flash-low`) grouped into a model
  and its efforts, since agy takes `--model gemini-3.8-flash --effort low` and
  refuses an effort a model is not listed with; an effort without `--model` is
  ignored, so none is passed alone. They are internal files parsed defensively: an
  unreadable one gives an empty list and "Default" only (claude falls back to
  its documented aliases). `HarnessCatalog.model(_:)` finds a model by id, else
  a claude alias ("opus" in the user's settings) as the first catalog model
  whose `short_name` it is, which is what claude runs (checked live for all
  four aliases, 2026-10-08), so "Default (Opus 5.5)" names a version.
  `HarnessCatalog.efforts(for:)` is the one effort
  rule, nil for an unknown model so nothing is guessed; the cache is read at
  translation time only when a pick exists. Picks are stored per provider
  (`Settings.harnessPick`). claude and codex run isolated from their user
  config, so `HarnessDefaults` reads just the user's default model and effort
  (claude `settings.json` `model`/`effortLevel`, codex `config.toml`
  `model`/`model_reasoning_effort`) and passes them back as flags; grok reads
  its own config, and its default model (for the "Default (…)" label and the
  Effort picker) is the "Default model:" line of `grok models`, the sign-in
  probe, cached in `Settings.grokDefaultModel`; agy runs the model selected in
  it, which it does not print. A default effort the picked model does not list is dropped.
  Known gap: codex still loads the
  global `$CODEX_HOME/AGENTS.md` into every translation (measured ~9.3k tokens
  for a 37 KB file, 2026-09-23); codex 0.156 has no flag for it (see
  `Translator.runCodex`).
- Grok runs with the `GROK_CLAUDE_*`/`GROK_CURSOR_*` compat cells off
  (`cliEnvironment`) and an empty tool allowlist, because otherwise it imports
  `~/.claude` rules, skills and MCP servers and may act as an agent instead of
  translating (flag rationale in `Translator.runGrok`). Its sign-in check is
  `grok models` output.
- agy has no system-prompt, tools-off or ignore-config flag, so it runs as the
  app's own custom agent (`Antigravity.agentDefinition`, written to
  `.agents/agents/translatelikeme/agent.md` under Application Support, which is
  its working directory): `inheritCustomizations: false`,
  `excludeDefaultComponents: true`, `tools: []`, the prompt in the message
  through `--input-format stream-json`. Measured 2026-10-19 (agy 1.4.2): ~1k
  input tokens instead of ~20.9k, no file, command or network tool, 5-9 s per
  translation. A Gemini safety-filter notice arrives as a SUCCESS result and is
  turned into a failure (`Antigravity.response`). agy has no ephemeral mode;
  every run stays in its history (`~/.gemini/antigravity-cli`), kept by
  decision (2026-10-19).
- Exhausted-limit failures surface as `LimitReachedError`: `LimitDetector`
  (LimitReached.swift) matches real CLI payloads, API quota bodies included (claude prints its limit
  line on stdout, codex on stderr, agy "Individual quota reached" on stderr;
  grok's limit payload is not yet captured)
  and `PopupController.showLimitReached` shows the engine's reset time with an
  Open Settings action. `EngineStatus` stays
  sign-in-based: `claude usage` is too slow (~26s) for proactive checks.
- Updates are Sparkle (`Updater`): a daily check against the appcast each
  release publishes, with gentle reminders so a scheduled find never takes
  focus (the menu item turns into "Install Update…"). Packaging and keys:
  `docs/build-and-release.md`.
- Logging goes through `Logger.app(category)`, one subsystem.
- Isolated first-run checks and native permission verification:
  `docs/fresh-install-testing.md`. `scripts/check-fresh-install.py` gives each
  `FreshInstallTests` method a new process, home and preferences domain, with
  host CLI access and network denied; ordinary `swift test` skips these checks.
