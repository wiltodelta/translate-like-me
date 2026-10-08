---
paths:
  - "Sources/**"
  - "Resources/**"
  - "Tests/**"
description: App architecture -- the status item and its standard NSMenu, settings panes, language pairs and Rewrite presets, the Carbon global hotkey path, paste-landed editability detection, Claude/Codex/Grok provider and model resolution, and update checking
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
  style (`SettingsTabViewController.makeWindow`, panes General, Translation
  and Rewrite, window title follows the pane, last pane restored unless a
  caller passes one in the `.openSettings` notification; a restored pane is
  not written back, a clicked or passed one is); `SettingsStore` applies every
  change immediately. No control is focused when a pane opens
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
  is typing in, the translation is already on the clipboard, and Settings opens
  from the status menu. Its one action keeps the active accent
  (`controlActiveState = .key`), and a capped body fades at the bottom when more
  text is below. macOS 27 hides `NSMenuItem.image` unless `preferredImageVisibility
  = .visible`; the status rows and the updates item set it (`StatusMenu.showsImage`).
  A scheduled Sparkle check shows its own window only while the app is active, so a
  launch-time find is announced in the menu, not over the user's app.
- `Languages.all` is every language with a macOS locale (307, from
  `Locale.availableIdentifiers`, English names), split by script where a
  language has several (not `Aran`, a Nastaliq style), Portuguese by region;
  stored codes are BCP 47. New pairs take languages from
  `Languages.suggestions`: system languages, then each enabled keyboard
  layout's primary language (TIS), then the region's language, then English.
  The first pair is the first two on ⌥⌘F; later pairs pair the first pair's
  first language with the next free suggestion. When suggestions run out the
  second language stays empty (`LanguagePair.isComplete` false): the picker
  shows "Choose a Language", onboarding's Continue waits, the menu item opens
  General, and a run shows a popup instead of translating. Each side's picker
  is an `Equatable` `LanguagePicker` keyed on its code, so typing a pair's
  style does not rebuild a 300-item menu per keystroke.
- Language pairs (`LanguagePair`, up to `Languages.maxPairs` = 3, stored as JSON
  in `Settings.languagePairs`, edited under General > Languages) each carry an
  optional shortcut and writing style (`style`, empty for a plain translation;
  pairs may share languages); `HotKeyManager` registers one Carbon `RegisterEventHotKey`
  per pair and the status menu lists one Translate Selection item per pair
  (pairs sharing languages get a subtitle saying which applies a style).
  The model detects the direction: text in `first` becomes `second`, anything
  else becomes `first` (`Translator.systemPrompt`). On-device detection
  (`NLLanguageRecognizer`) was measured and rejected: constrained to ru/en it
  called Spanish and "Скинь PR по TranslateLikeMe" English at 1.00.
  `Settings.persistLanguagePairs()` runs first at launch and writes the pairs
  once: the pre-pairs `languageA`/`languageB`/`replaceKeyCode` (or ru/en ⌥⌘F for
  an earlier run that kept the defaults) for an existing user, none for a new
  one (`Settings.initialPairs`), and every pair may be removed (the
  menu then shows "Add a Language Pair…"); `Settings.moveStyleIntoPairs()` then copies the
  earlier single global `style` into every pair when none has a style yet,
  and removes it.
  `TranslationController.run(pair:)` copies the
  selection, translates, and pastes back.
- Rewrite presets (`RewritePreset`, up to `Rewrite.maxPresets` = 3, stored as
  JSON in `Settings.rewritePresets`, edited in the Rewrite pane, none by
  default) each carry a name (the menu item's title; new ones are "Preset
  <n>"), an optional shortcut and a writing style. A preset never translates:
  the message stays in the notes' language and a pair's shortcut translates it
  afterwards. Presets are told apart by purpose, not language, as Apple's
  Writing Tools, Wispr Flow and DeepL Write tell theirs apart by tone, and
  because a language bound into each preset is what Superwhisper users ask to
  be rid of (an earlier draft here bound one, decided against 2026-10-08).
  `HotKeyManager.reload` registers pairs first, then presets, skipping a combo
  already taken, and `SettingsStore.owner(of:except:)` refuses a combo either
  list uses. A row holding a `TextField` binds its item by id
  (`RewriteSettingsView.binding(for:)`), never by index through
  `ForEach($array)`: the field re-reads its binding during the resize
  animation after a removal and crashed past the shortened array. The menu
  adds a Rewrite Selection section only while a preset exists. `TranslationController.rewrite(preset:)` shares the copy, engine and
  paste flow with `run(pair:)` (`perform`). `Rewrite.systemPrompt` keeps the
  notes' language even beside a received message in another (21 of 21 live
  runs, 2026-10-08), keeps questions for the recipient, drops filler and
  superseded self-corrections, treats the received message as context only,
  writes a name taken from it in the message's script ("Марк", 1 of 3 runs
  without that rule, 3 of 3 with it), and allows the recipient's name but no
  greeting word (10 of 21 runs opened "Hi Pete," without that rule, 0 of 12
  with it).
  Each run, translate or rewrite, logs its frontmost app, outcome, and
  failures through `os.Logger`: `/usr/bin/log stream --level info --predicate
  'subsystem == "com.wiltodelta.translatelikeme"'` (plain `log` is a zsh
  builtin).
- Onboarding (`Onboarding`, a `SettingsWindow` hosting an `NSHostingView`: an
  `NSHostingController` sized by `preferredContentSize` aborted in a layout
  loop) opens at launch until `Settings.didCompleteFirstRun`, which closing it
  sets. Step one is `LanguagePairList`, shared with General > Languages; step
  two lists the providers with `EngineChecks`, started when the window opens:
  `EngineProbe` runs `EngineStatus.check` and then one real test translation
  (`Translator.translate(_:pair:provider:)`), mapped to `EngineHealth`.
  Not-installed and signed-out engines are rechecked when the app becomes
  active (back from a `login` in Terminal); a spent limit or failed run waits
  for Check Again, each recheck being a real translation. Until the user picks, a definitively failing
  stored engine yields to the first working one. Settings and onboarding share
  one `SettingsStore` owned by `AppDelegate`. Parallel checks made
  `Translator`'s binary cache a lock (`OSAllocatedUnfairLock`).
- `SelectionService.pasteLanded` decides editability *after* the paste (re-copy
  the selection; if it still holds the original text, the field is read-only).
  Read-only targets get the translation on the clipboard plus a `PopupController`
  popup instead of a silent lost paste.
- Providers: Claude (`claude` CLI), ChatGPT (`codex` CLI) and Grok (`grok`
  CLI), selected in Settings; each runs on the user's subscription through its
  signed-in CLI (the API-key mode was removed; `Settings.removeAPIKeys()`
  deletes what it stored at launch). Per-provider facts live as `Provider`
  properties (`shortName`, `cliBinaryName`, `cliProductName`,
  `loginCommand`, the model summary, `cliEnvironment`, `statusArguments` with
  `isSignedIn(statusOutput:exitCode:)`), not as `== .grok` special cases.
- Translations run the model and effort picked in Settings, else the CLI
  default (`HarnessChoice.current`). The pickers list `HarnessModels`, read from
  each CLI's own cache: claude `~/.claude/cache/model-catalog/<account>-cc.json`
  (per-model efforts; Haiku has none; `state.model` is its default), codex and
  grok `models_cache.json`. They are internal files parsed defensively: an
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
  probe, cached in `Settings.grokDefaultModel`. A default effort the picked model does not list is dropped.
  Known gap: codex still loads the
  global `$CODEX_HOME/AGENTS.md` into every translation (measured ~9.3k tokens
  for a 37 KB file, 2026-09-23); codex 0.156 has no flag for it (see
  `Translator.runCodex`).
- Grok runs with the `GROK_CLAUDE_*`/`GROK_CURSOR_*` compat cells off
  (`cliEnvironment`) and an empty tool allowlist, because otherwise it imports
  `~/.claude` rules, skills and MCP servers and may act as an agent instead of
  translating (flag rationale in `Translator.runGrok`). Its sign-in check is
  `grok models` output.
- Exhausted-limit failures surface as `LimitReachedError`: `LimitDetector`
  (LimitReached.swift) matches real CLI payloads, API quota bodies included (claude prints its limit
  line on stdout, codex on stderr; grok's limit payload is not yet captured)
  and `PopupController.showLimitReached` shows the engine's reset time with an
  Open Settings action. `EngineStatus` stays
  sign-in-based: `claude usage` is too slow (~26s) for proactive checks.
- Updates are Sparkle (`Updater`): a daily check against the appcast each
  release publishes, with gentle reminders so a scheduled find never takes
  focus (the menu item turns into "Install Update…"). Packaging and keys:
  `docs/build-and-release.md`.
- Logging goes through `Logger.app(category)`, one subsystem.
