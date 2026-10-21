# First-run recommendations

## Status and product decisions

This increment adds one-time recommendations, a configuration summary and
standalone onboarding design previews. It does **not** yet provide the complete
installed-and-working experience: the approved three-screen flow is not wired
into the app, and completion still follows engine checks rather than mandatory
preparation of both local models.

The product requirement is useful dictation, text improvement and translation
without extensive configuration. Local models should be the initial engine;
CLI services should remain alternatives. Personalization comes later.

| Mac memory | Translation recommendation | Dictation recommendation |
|---|---|---|
| 8-16 GiB | Gemma 4 E2B | Whisper Turbo |
| Above 16 GiB | TranslateGemma 12B | Qwen3-ASR |

These are the user's explicit product choices, accepting E2B's documented quality
limitations. Hardware does not establish transcription quality or language
coverage. Existing valid choices remain authoritative. Storage and preparation
checks remain necessary before the models can be used.

## Implemented behavior

- `FirstRunRecommendations.apply` runs before legacy migrations. A fresh profile
  gets language suggestions, the memory-based model picks and a neutral Improve
  Text preset on Option-Command-J. It does not enable dictation or download models.
- Languages come from macOS preferred languages and enabled keyboard sources,
  normalized and deduplicated. Region and assumed English are not evidence.
  One evidenced language leaves the second side unchosen; none creates no pair.
- Existing settings, including empty collections and false first-run flags,
  prevent seeding. A one-time marker prevents reapplying recommendations after
  edits or removals. Argument-domain fixtures are excluded. Input sources are
  read only when seeding actually needs suggestions.
- Engine checks reuse `EngineChecks` and `EngineProbe`: readiness followed by a
  real synthetic translation. Installation or sign-in alone never means working.
  Selection waits for all checks, keeps a working current engine, otherwise uses
  stable provider order. Manual choices are preserved; automatic choices can
  change during unfinished onboarding.
- The current welcome window is a grouped configuration summary. Rewrite is
  excluded from it. Settings opens the shared Settings window. Closing after
  completed checks marks first run complete; interrupted checks retry next time.
- When no engine works, a local-model download can be offered for the en/ru/de
  evidence covered by the existing evaluation. Eligibility checks the selected
  model's memory minimum and download size plus the existing storage reserve.
  Unknown storage does not qualify. File checks run outside SwiftUI body evaluation.
  An offer is not a claim that the model already works.
- Dictation offers Whisper Turbo and Qwen only. Saved Small, Large v3 and unknown
  preferences resolve to Turbo without deleting cached downloads. The visible
  Turbo title omits the version and retains its original name in every language,
  as do the other model names. Descriptive strings have all nine translations. The recommendation badge follows memory.
- Settings order is General, Dictation, Translation, Rewrite. Persisted pane IDs
  remain 0, 3, 1, 2. String tab identifiers map stable IDs to positions; numeric
  identifiers caused a native `isEqualToString:` exception. Explicit same-pane
  selection persists; restoring a saved pane does not write it back.

## Approved onboarding design

The final order is preparation, permissions, then usage instructions.
Completion must eventually require both selected models to be downloaded,
verified and prepared. Closing early must preserve unfinished setup.

The preparation screen shows selected languages/models, download sizes and
progress. The permission screen guides microphone consent and Accessibility
sequentially with one action per stage. Consent remains with macOS. The final
screen explains dictation and translation with actual assigned shortcuts, then
says how to reach Settings through the app's menu-bar icon. Rewrite and model
pickers do not belong in this flow.

Standalone Russian previews are `docs/prototypes/preparation-preview.swift`,
`permissions-preview.swift` and `welcome-preview.swift`. Run each with
`swift <script> <output-directory>`. They use synthetic progress and permission
states, not real downloads, preferences, prompts or button handlers.

The user approved design findings UX-01 through UX-05: consistent geometry,
neutral sequential permission requests, Right Option, accurate insertion/Copy
wording and a concrete Settings route. Ten final frames cover the three screens
and three permission substates in both appearances at 560 by 650 points.
Header positions match; ungrouped row text starts at x84 points. The preparation
frame stayed pixel-identical. Sampled secondary text contrast was 4.83:1 light
and 5.85:1 dark. These are static design results, not native interaction proof.
Audit artifacts, including immutable baselines, before/after images and PDFs,
remain in the session's Downloads audit folder for continued review.

## Evidence and verification

[Local translation evaluation](local-translation.md) covers 15 synthetic cases,
three runs per case and en/ru/de. TranslateGemma preserved a spoken correction;
E2B repeatedly reversed it and also mishandled translation direction. Its use
on smaller Macs is an accepted tradeoff, not a quality-parity claim.
[Speech compute measurements](dictation-model-efficiency.md) and
[Qwen integration](qwen-integration.md) do not establish a comparative
per-language recognition-quality ranking.

Recommendation tests cover fresh profiles, model memory boundaries, storage,
existing-user preservation, edits/removals and explicit engine choices.
The isolated fresh-install harness exercises the real seed/migration/store seam
without accounts, network access, microphone or personal preferences.
Settings pane tests create the actual AppKit controller with synthetic General
content, avoiding Sparkle's startup from GeneralSettingsView under XCTest. An
unisolated full run opened a Sparkle modal during later async tests; a process
sample established the cause and that run was stopped. Tests verify saved IDs
and direct routes. Reverting to visual indices caused six assertion failures.
Earlier mutations of preservation and storage guards were also rejected.

The isolated fresh-install harness passed all seven scenarios on the final
development build. The latest focused recommendation, language, model, pane
and store run passed 59 tests without skips. Strict lint
and localization synchronization passed. Full pre-push verification is recorded
in the commit preparation logs and final session report, including skipped
opt-in tests rather than treating them as exercised.

## Remaining work

- Connect the approved screens to real recommendation, download, preparation
  and permission state, including mandatory model-ready completion.
- Make local the fresh-install engine default; current engine selection still
  retains a working current provider or uses stable provider order.
- Handle unsupported/no language evidence, insufficient memory/storage,
  interrupted/resumed downloads, verification failures and denied permissions.
- Verify native keyboard/focus and assistive-technology behavior for the new flow,
  all shipping localizations and actual assigned shortcuts. Previews do not prove them.
- Native summary and Dictation Settings were verified in Russian in both themes
  on the current signed development build, at widths 520 and 500 points.
  Sampled secondary text measured 4.95:1 light and at least 5.64:1 dark through
  the calibrated sRGB capture pipeline. The original failed transition was not
  counted; the separate dark run passed. Two German runs lost focus before
  capture, so German rendering remains unverified. The capture harness now
  waits for a previous development PID to exit before launching the next one.
  Preferences and system appearance were restored by the harness.

## Isolation

Work stays in branch `feat/first-run-recommendations`, in the originally created
`sc-trapped-boson-99dd` worktree. The source checkout was read-only. Its ongoing
probes and uncommitted files were never copied. Integration uses the committed
remote main, preserving its README/user guide and dictation-language changes.
The worktree is retained for continuation; no installed app or personal settings
are modified by the implementation or the standalone previews.
