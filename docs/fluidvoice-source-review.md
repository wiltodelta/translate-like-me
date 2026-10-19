# FluidVoice source review and candidate features

> Historical research inventory. The user narrowed the product scope after this
> review. The [minimal dictation plan](dictation-feature-plan.md) is authoritative;
> the priorities below are retained as research, not approved implementation scope.

Review date: October 18, 2026. Target: Translate Like Me on Apple silicon,
macOS 15+, initially an M5 with 16 GB or more of unified memory.

This is a source review and a proposed product scope. No dictation feature has
been implemented or tested in Translate Like Me. Model selection and the proposed
Russian/English evaluation are covered in [the model research](dictation-research.md).
The subsequent [Handy source review](handy-source-review.md) adds implementation
findings on ASR memory, long-form chunking, native worker isolation, and recovery.

## Evidence and limits

The reviewed project is [altic-dev/FluidVoice][upstream], pinned to
[`ad1d1ff0ea0b6c2733bda72150625d3e8928f608`][snapshot]. Its README identifies
`altic.dev/fluid` as the official website and explicitly disclaims affiliation
with `fluidvoice.org`. The public app is GPLv3; Fluid Intelligence uses a separate
private runtime. This review covers the public integration, not that runtime's
internals. Product ideas below should be implemented independently, without
copying GPL source into this Apache-2.0 project.

The inspection followed hotkey dispatch, capture readiness, streaming preview,
finalization, optional processing, target selection, delivery, recovery, and model
management. It also sampled dictionary, voice editing, and history implementations.
It is not an exhaustive audit of meetings, command execution, or every provider.
The app was not launched, and upstream tests were not run. Code establishes the
implemented behavior, not measured latency, recognition accuracy, or reliability.

## First release

These are the recommended release requirements. Complexity describes integration
effort relative to this repository, not elapsed days: small, medium, or large.

| Feature | Evidence in FluidVoice | Proposed Translate Like Me behavior | Complexity |
| --- | --- | --- | --- |
| 1. Local dictation with selectable models | The [provider contract][provider] separates preparation, streaming, and final transcription. [Model actions][models] activate, download, cancel, and delete models. | Audio stays on the Mac for ordinary dictation. Offer a small evaluated catalog, with language support and download size. Evaluate English, Russian, and mixed speech separately before choosing the default. Keep existing CLI processing an explicit additional action. | Large |
| 2. Toggle or hold to record, plus cancellation | [Activation modes][activation] include toggle, hold, and automatic tap/hold. The [hotkey implementation][hotkeys] handles releases; [cancellation][cancel] invalidates pending output as well as active capture. | One configurable dictation shortcut, a choice of toggle or hold, and Escape to cancel. Cancellation during recognition or processing must suppress later insertion. Start with ordinary key combinations; modifier-only Fn, mouse shortcuts, and automatic tap/hold can follow. | Medium |
| 3. A compact recording indicator | The [overlay coordinator][overlay] routes audio levels to notch or bottom UI. The [bottom panel][panel] is nonactivating. [Streaming publication][preview] updates partial text. | A small panel that preserves the target app's focus: preparing, listening with a meter, recognizing, and optional processing. Optional start/stop sounds. A short preview can follow after the basic state display works. Avoid a notch framework and multiple overlay styles. | Medium |
| 4. Safe insertion at the cursor | [Stop snapshots][stop] preserve destination and processing decisions before awaiting final ASR. [Target policy][target] explicitly distinguishes the current cursor from the starting field. [Delivery][delivery] checks cancellation and preserves clipboard ownership. | Support an empty caret and replacing a selection. Capture the destination at start and validate the field and range again before inserting. If the target changed, retain the result and show Copy rather than restoring focus or inserting elsewhere automatically. Never dispatch Return as part of ordinary dictation. | Large |
| 5. Recover the result when insertion fails | The [delivery result][delivery] distinguishes recoverable failures. [Recovery actions][recovery] retry delivery or insert the latest transcription. | Keep the latest raw and final text in memory. A failed insertion offers Copy and an explicit retry; a menu action inserts the latest result at the current cursor. Preserve the user's newer clipboard. Full persistent history is not required for recovery. | Medium |
| 6. Microphone selection and a usable first-run check | [Microphone coordination][microphone] reconciles available inputs. The [capture startup path][readiness] waits for actual PCM and retries unstable routes. [Onboarding policy][onboarding] keeps an unknown destination in a sandbox. | Default microphone plus explicit device selection, a level meter and a short test in Settings, clear permission/device errors, and recovery after wake or reconnection. Show listening only after real samples arrive. Keep test output inside Settings. | Large |
| 7. Model installation that survives failures | [Preparation phases][provider] distinguish download, optimization, and loading. [Model actions][models] expose cancellation and deletion. The [Parakeet archive installer][installer] verifies manifests, file sizes, and hashes. | Show download and preparation progress; permit cancel, retry, and deletion when inactive. Stage incomplete downloads and verify the selected artifact before activating it. Never mark a partial download ready. Hide format and repository details from the normal flow. | Medium |
| 8. Preserve short utterances and the end of a phrase | [Finalization][finalize] marks a recording boundary, stops capture, drains audio, rejects empty buffers, conditionally skips short silence, and pads short input. | Releasing the shortcut must preserve the final captured phoneme. Silence must not create inserted text, and a short word must still work. Bound recording memory and reject stale results after cancellation or a new session. | Large |

Features 1, 6, 7, and 8 share the same ASR/capture work; their effort must not be
added as if they were independent projects. A first backend can prove the flow,
followed by a second evaluated model behind the same narrow interface.

## Refinements from Handy

The [Handy review](handy-source-review.md) adds these requirements to the core
implementation without expanding the basic Settings surface:

- Use an explicit recording/session state machine. Cancel must discard delayed
  output and any remembered start; avoid silently starting the microphone later.
- Define ASR idle unloading in the first release, with a timeout chosen from
  memory and reload measurements. Never unload during capture or inference.
- Derive language, vocabulary, and native-streaming behavior from the selected
  backend's actual capabilities. Keep unknown capabilities distinct from false.
- Resume interrupted model downloads, detect stalls, and verify catalog artifacts.
- Preserve speech margins around VAD decisions and keep capture readiness separate
  from speech detection. Test long dictations before deciding which backends need
  pause-based chunking or native streaming.

If the selected runtime uses native C/C++ inference, evaluate a worker/helper
process with bounded recovery. Retrying recognition from the last session's audio
is a useful later addition with bounded retention. Handy's experimental clipboard
read receipts warrant a separate experiment; preserve our existing destination
validation and rich clipboard snapshots.

## Next additions, in priority order

1. **Dictate into an existing Rewrite preset.** FluidVoice's [processing path][processing]
   keeps ASR and AI processing separate and falls back to the transcript if AI fails.
   Add an explicit choice to use an existing preset, retaining the original transcript
   on failure. Reuse the provider and preset system instead of creating another
   prompt editor. Ordinary dictation must preserve mixed Russian/English wording;
   Rewrite is an intentional transformation. Medium complexity.
2. **A manual dictionary for names and terms.** FluidVoice [applies cached dictionary
   replacements][dictionary] and [protects complete replacement output][protection]
   from some repeated expansions. Offer a small phrase-to-spelling list for names,
   products, acronyms, and technical vocabulary. Separate text correction from
   acoustic hotword support, which depends on the chosen model. Verify Unicode word
   boundaries and overlapping rules. Do not start with voice enrollment or automatic
   learning. Medium complexity.
3. **Live text preview.** FluidVoice's [scheduler][streaming] periodically recognizes
   accumulated audio, and its [publication path][preview] rejects stale operations.
   Display provisional text in the recording panel; insert the final result only
   once. This is valuable for checking the microphone and language, but periodic
   batch preview is not proof that a backend supports native streaming. Medium
   complexity, depending on the model.
4. **Dictate and translate.** Connect local ASR output to an existing language pair
   and its style, without selecting and recopying intermediate text. This is a
   Translate Like Me composition recommendation, not a claim that FluidVoice has
   our language-pair workflow. The translation still uses the configured remote
   CLI provider; the interface must make that boundary clear. Medium complexity.
5. **Voice instructions for selected text.** FluidVoice's [Rewrite service][rewrite]
   captures selected context and processes spoken instructions; without selection,
   it enters a writing mode. An optional action such as "make this shorter" would
   fit our text-focused app. It requires a separate instruction contract and
   destination validation, not merely passing the instruction as rough notes to
   the current Rewrite preset. Large complexity.
6. **Spoken punctuation and formatting.** FluidVoice has a [dedicated formatter][punctuation]
   with configurable phrases, spacing, and application context. Start with opt-in
   Russian and English phrases for a new line or paragraph. Distinguish literal
   discussion of punctuation from a formatting instruction. Medium complexity.
7. **Joining successive dictations.** FluidVoice [uses text before the cursor][continuous]
   to decide spacing and initial capitalization. Add conservative spacing first;
   avoid automatically lowercasing product names, acronyms, or code. This requires
   context from the actual destination field. Medium complexity.
8. **Pause or mute while recording.** FluidVoice [handles held Space][mute] and
   excludes muted intervals from captured audio. Useful for long dictations, but
   intercepting Space also creates typing and lost-key-up edge cases. Add only
   after hold/toggle and cancellation are reliable. Medium complexity.
9. **Release inactive processing-model memory.** FluidVoice's [idle unloader][unloader] tracks
   activity and delays unloading while busy. That implementation concerns its
   private AI processing model; it does not establish an idle-unload policy for
   every ASR backend. ASR residency has been promoted to first-release engineering
   by the Handy review above; a separate local text-processing model should get
   the same measurement-based treatment if one is introduced. Medium complexity.
10. **Per-application processing choices.** FluidVoice's [route resolution][routes]
    supports app bindings and its [app session][session] tracks temporary choices.
    Consider a simple app-to-existing-preset mapping only after explicit preset
    selection has proved useful. Avoid a second collection of app-specific prompts.
    Medium complexity.

## Features to leave out of the initial scope

- Command Mode, terminal execution, agent conversations, and application search.
  The public [command service][commands] owns terminal tools and a multistep agent
  conversation. This would create a second product inside a text utility.
- Meeting capture, system audio, speaker identification, and meeting summaries.
  These need their own lifecycle and are outside short dictation into a field.
- A dashboard, usage statistics, text diff screens, and a full searchable audio
  archive. The [history model][history] holds raw/final text, app/window metadata,
  timing, processing failures, and optional audio. Last-result recovery provides
  the immediate benefit without this permanent data surface.
- Pronunciation enrollment and automatic dictionary training. The [pronunciation
  store][pronunciation] persists model-specific embeddings and audio evidence;
  this is substantially more than a personal spelling dictionary.
- Spoken Send. The [output pipeline][processing] parses and gates sending, but an
  automatic Return action is unnecessary for our first dictation release.
- A provider marketplace, local API server, many overlay variants, and Intel
  compatibility. Prefer the existing Apple silicon scope and a small tested model
  catalog. File transcription can be reconsidered as a separate request.

## Integration findings in Translate Like Me

- [HotKeyManager](../Sources/TranslateLikeMe/HotKeyManager.swift) currently registers
  only pressed events, with language-pair and Rewrite actions. Hold mode needs
  release handling and cancellation; shortcut collision checks must include
  dictation. Ordinary Carbon combinations do not require replacing all hotkeys
  with FluidVoice's broader event-tap machinery.
- [SelectionTarget](../Sources/TranslateLikeMe/SelectionTarget.swift) requires
  `range.length > 0`. A new caret-capable delivery target is needed; weakening
  selection requirements globally would change translation and Rewrite behavior.
- The same file's `SelectionActivity` invalidates on keyboard, mouse, and app
  changes. Its current lifetime is for a selection transformation. Dictation must
  distinguish its own start/stop keys from real destination changes and reject
  stale asynchronous output deliberately.
- [SelectionService](../Sources/TranslateLikeMe/SelectionService.swift) already
  preserves rich clipboard data, uses change counts, and posts paste to the original
  PID. Reuse these safeguards. Snapshot the clipboard near delivery rather than
  overwriting clipboard activity that happened during a long recording.
- [SelectionWorkflow](../Sources/TranslateLikeMe/SelectionWorkflow.swift) expects
  selected text and a copied-selection marker. Dictation needs a different input
  path sharing delivery primitives, not a fake selection passed into that workflow.
- [Translator](../Sources/TranslateLikeMe/Translator.swift) accepts text directly
  for translation and Rewrite, which makes explicit processing composition feasible.
  [Rewrite](../Sources/TranslateLikeMe/Rewrite.swift) intentionally selects the
  dominant language of mixed notes and restructures a message. It must not become
  an invisible cleanup step for literal multilingual dictation.
- [TranslationController](../Sources/TranslateLikeMe/TranslationController.swift)
  has an activity guard for current transformations. Dictation needs an explicit
  ownership decision so simultaneous capture, processing, and paste cannot race.
  Keep capture, recognition, transformation, and delivery separate instead of
  growing one controller with every mode.

## Suggested product surface and validation

Add one Dictation settings pane with a shortcut, toggle/hold choice, microphone,
and model selection with installation status. Keep the normal path to one shortcut,
speaking, and insertion. Use the existing result popup pattern for recovery and a
small nonactivating recording panel for progress. These are design proposals,
not rendered or validated UI.

Before release, exercise Russian, English, mixed terms, short words, silence,
long recordings, punctuation, and repeated sessions. Verify empty fields and
selections, focus changes during recognition, newer clipboard writes, cancellation
during startup/ASR/processing/delivery, and hotkey release while startup is pending.
Test microphone permission denial, unavailable devices, Bluetooth reconnect, sleep
and wake, and an interrupted model installation. Verify actual insertion in native
fields, browsers, Electron editors, and terminals using synthetic text. Compare
models on the same recordings and build; measure warm/cold latency and memory
separately. These are acceptance requirements, not completed checks.

[upstream]: https://github.com/altic-dev/FluidVoice
[snapshot]: https://github.com/altic-dev/FluidVoice/tree/ad1d1ff0ea0b6c2733bda72150625d3e8928f608
[provider]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/TranscriptionProvider.swift#L156
[activation]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Persistence/HotkeyActivationMode.swift
[hotkeys]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/GlobalHotkeyManager.swift#L1717
[cancel]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/ContentView.swift#L5105
[overlay]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/NotchOverlayManager.swift#L176
[panel]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Views/BottomOverlayView.swift#L653
[stop]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/DictationStopSnapshot.swift
[target]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/DictationTargetPolicy.swift
[delivery]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/PasteDeliveryCoordinator.swift
[recovery]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/ContentView.swift#L4086
[microphone]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/MicrophonePreferenceCoordinator.swift#L200
[readiness]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/ASRService.swift#L2909
[onboarding]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/OnboardingDictationOutputPolicy.swift
[models]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/UI/AISettings/VoiceEngineSettingsViewModel.swift#L126
[installer]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Networking/ParakeetArchiveInstaller.swift#L64
[finalize]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/ASRService.swift#L3549
[processing]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/ContentView.swift#L3144
[dictionary]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/ASRService.swift#L7461
[protection]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/DictionaryReplacementProtection.swift
[streaming]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/ASRService.swift#L6976
[preview]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/ASRService.swift#L7209
[rewrite]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/RewriteModeService.swift#L51
[punctuation]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/ASRService+SpokenPunctuationFormatting.swift
[continuous]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/ASRService.swift#L7633
[mute]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/GlobalHotkeyManager.swift#L2794
[unloader]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/PrivateAIIdleUnloader.swift
[routes]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/DictationPostProcessingService.swift#L16
[session]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/DictationAppSession.swift
[commands]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/CommandModeService.swift
[history]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Persistence/TranscriptionHistoryStore.swift#L25
[pronunciation]: https://github.com/altic-dev/FluidVoice/blob/ad1d1ff0ea0b6c2733bda72150625d3e8928f608/Sources/Fluid/Services/PronunciationDictionaryStore.swift
