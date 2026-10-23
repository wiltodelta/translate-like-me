# Model management

Translation and Dictation keep their working-model pickers in Settings. Both
use **Manage Models…** to open `ModelManagementView`: all available models,
their descriptions, the selected model, download state and
Download / Cancel / Remove Download actions. A download continues after Done;
removal requires confirmation. Closing the sheet does not change the selection.

Every download resumes. Cancel, quit or a failure keeps finished files and the
partial one, and the next Download continues from there; a dropped connection or
sleep is retried in place until the network returns (`ModelSnapshot`, verified
live against Hugging Face on 2026-10-23: a cancelled run restarted at the
partial file's fraction).

`LocalModelDownloads` owns translation downloads, cancellation and removal state.
Removal runs through `LocalEngine`'s existing exclusive operation queue. It has
an observable state, and a failed removal remains visible instead of being
logged alone.

Both managers protect the selected model while its feature is enabled. For
Translation, choose another local model before removing its download. For
Dictation, choose another speech model or disable dictation first. Translation
checks the current selection again when removal is confirmed, so a model
selected while the confirmation was open stays protected.

`DictationModelDownloads` owns speech file operations separately from microphone
permission and runtime preparation. `DictationModelFiles` reuses the engine's
pinned model, tokenizer and VAD download paths and integrity checks. Its list
status checks file presence only; engine preparation still verifies hashes.
The required model components come from `DictationEngine.requiredFiles(for:)`.

An already loaded speech model remains usable while another model downloads.
The app injects a file-operation wait into its speech engine before a new runtime
load; isolated engines keep a no-op default. Management cannot start
during preparation, recording, recognition or cancellation. The selected speech
model cannot be removed while dictation is enabled; disabling drains its runtime
release before removing files. Whisper variants share a Hub repository, so
removal targets only the chosen variant and its tokenizer, preserving every
neighbor and shared VAD assets.

`DictationModelFilesTests` uses temporary synthetic files and the SDK's actual
cache paths to check each model's removal against every neighbor, tokenizer and
shared VAD, and checks incomplete or empty model components. It never touches
the app's downloads or microphone.

## Native verification

Select verification scope and reuse completed evidence through the shared
UI verification rule in `~/Documents/GitHub/claude-config/docs/ui-verification.md`.
The capture options below narrow this app's recipe to the selected checks.

For a focused render, combine `CAPTURE_MODELS_ONLY=1`,
`CAPTURE_MODEL_KIND=translation` (or `speech`), `CAPTURE_MODEL_INTERACTIONS=0`
and `CAPTURE_APPEARANCE=current`. This skips unchanged dismissal and confirmation
routes and leaves the system appearance alone.

Run the existing capture recipe with the Mac unlocked:

```bash
CAPTURE_MODELS_ONLY=1 CAPTURE_OUT=/tmp/tlm-models-captures ./capture-screenshots.sh
```

Wrap desktop driving with the shared capture notice as described in
`~/Documents/GitHub/claude-config/docs/macos-capture.md`. The recipe opens both
real entry points, captures both themes at the fixed window widths, then
closes and reopens each sheet through Accessibility. It verifies Done, Escape,
Return and cancellation of removal when a downloaded model is present. Pass
`CAPTURE_GEOMETRY_TOOL` the shared `macaudit.py` path to retain geometry dumps
beside the captures. With both selected models already downloaded,
`CAPTURE_VERIFY_PROTECTION=1` also asserts that selected-model removal is disabled
in both managers. The recipe preserves dev settings and appearance and never
presses Download or confirms removal.

Use `CAPTURE_LANGUAGE=de` with the same output override for long translations.

Verified on October 22, 2026, after integration onto the published version:
English and German, light and dark, both real Settings entry points and both
removal confirmations. The current speech-model choices and microphone picker
are preserved.
The model picker contains the original model names without recommendation tags.
Confirmation reuses `RemovalConfirmation`, the app's ordinary sheet with
readable buttons across system accents, instead of an alert. Row actions use
ordinary bordered controls; the selected-content tint is scoped to Done so it
cannot become a low-contrast label on another action in Dark Mode.

At the fixed minimum sizes, all model descriptions and actions fit without
clipping. Both managers measure 520 × 440 pt; confirmations are 360 pt wide and
fit their localized message. Every action has a 24 pt hit height. Calibrated
2× sRGB captures measured enabled text at least 4.95:1 in light and 5.85:1 in
dark; the disabled native removal control is excluded. The geometry analyzer
found no alignment, spacing or control-size discrepancies in the 16 manager
and confirmation frames. AX verified selected-model protection, cancellation,
Done, Escape and Return. No download or confirmed deletion was performed.
Development preferences and system appearance matched their pre-run snapshots.

Saved views: [translation, light](../screenshots/models-translation.png),
[translation, dark](../screenshots/models-translation-dark.png),
[speech, light](../screenshots/models-speech.png),
[speech, dark](../screenshots/models-speech-dark.png).

Selected-model protection was checked in both English appearances for both
managers. The revised explanatory text was also rendered in German. The wider
German capture stopped on its unchanged Return-dismissal check; that run does
not establish keyboard completion. It restored preferences and appearance.

After restoring the upstream `Whisper large-v3-turbo` name, a focused native
check switched each picker in both directions and read each saved choice back
from the development preferences. Translation switched between the downloaded
Gemma 4 E2B and the absent TranslateGemma 12B; selection and removal protection
followed the choice. Speech switching ran with dictation disabled, without
runtime loading or microphone access. The enabled preparation/cancellation and
active-recording restrictions were covered by controller tests instead.
All four manager states remained 520 × 440 pt with 24 pt actions; the complete
Whisper name fit. The geometry analyzer found no discrepancies within those
sheets. Development preferences were restored and compared with the snapshot.
