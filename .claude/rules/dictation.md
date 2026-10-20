---
paths:
  - "Sources/TranslateLikeMe/Dictation*.swift"
  - "Sources/TranslateLikeMe/HotKeyManager.swift"
  - "Sources/TranslateLikeMe/OptionKeyGesture.swift"
  - "Sources/TranslateLikeMe/Shortcut*.swift"
  - "Sources/TranslateLikeMe/SelectionTarget.swift"
  - "Tests/TranslateLikeMeTests/Dictation*.swift"
  - "Tests/TranslateLikeMeTests/OptionKeyGestureTests.swift"
description: "Minimal local dictation: model, recording lifecycle, cancellation, and caret delivery"
---

# Local dictation

Product scope: `docs/dictation-feature-plan.md`. Implementation and verification:
`docs/dictation.md`. A small curated Whisper catalog, automatic detection of all model languages,
one Option hold key, system microphone, no cleanup LLM. Settings has a dedicated
Dictation pane. The user explicitly added model selection after the 3.5.0 release.

- `DictationModel` lists multilingual Small, Turbo (the existing default) and
  Large v3 variants, with matching pinned tokenizer repositories and hashes.
  Preserve Turbo and its existing cache for absent or unknown preferences. The
  selected model persists while disabled without preparing assets or requesting
  permissions. An enabled change prepares it automatically; a change during
  preparation cancels and unwinds before preparing the latest selection. Block
  changes during capture, recognition and cancellation. Keep old downloads, but
  unload the old runtime before loading another model.
- `DictationEngine` owns WhisperKit in an actor. Model and tokenizer revisions
  are pinned. `DictationSnapshot` checks every required Core ML component and
  hashes existing files against the pinned revision's Hub metadata, using SHA-256
  for LFS and Git blob SHA-1 for ordinary files. Remove corrupt files before
  resuming a partial download, preserve good files, and validate the result again;
  the SDK admits partial caches and trusts matching metadata without rehashing.
  Validate tokenizer hashes explicitly; the SDK's literal
  file-pattern cache check only understands directories. Ordinary reload disables
  downloading. Silero checks speech presence without cutting the original clip;
  its recurrent state resets per recording. SDK 1.1.1 hardcodes `noSpeechProb`
  to zero, so it cannot substitute for this gate. Keep the quiet tail for short
  words and timestamp decoding for complete long-clip boundaries. Check free
  storage before preparation, since Core ML ENOSPC can terminate outside Swift.
- `DictationSession` checks identity and phase. A queued meter callback must not
  return recognition to recording. Cancellation suppresses late completions;
  another recording must wait for the previous operation to finish unwinding.
- Capture holds `TranslationActivity` through delivery. The recorder owns only
  its current temporary WAV and deletes it on completion/cancel. Never log audio
  or transcripts. Keep the model resident until memory pressure or disabling;
  release after active work. Clear the actor's model reference before an await so
  a new request cannot take a model being unloaded. Await any queued release
  before preparing the next session. Start the recorder synchronously on press;
  reload the model only after release, while retaining the drained audio.
  Interrupted initial preparation retries after the old task unwinds, never
  reports ready with missing assets, and does not restart during termination.
  Do not reintroduce timed
  eviction without measuring reload latency.
- Capture uses `AVAudioEngine` voice processing on both I/O nodes, with maximum
  fixed other-audio ducking, automatic gain disabled and no microphone-to-speaker
  connection. Render a separate zero-filled output for the downlink clock in the
  processed input's client format; the default mixer format failed
  VoiceProcessingIO initialization in the native check. Explicitly disable
  processing after stopping the engine and removing its tap, releasing ducking
  on release, cancellation or failure before recognition. Do not silently
  fall back to raw input. Read the input format after enabling processing; write
  native PCM and let WhisperKit resample on read. Tap callbacks are explicitly
  `@Sendable` and never enter the main actor for audio writes. The locked sink
  closes before recognition and rejects late writes. Bound capture by frame
  count; a route/format interruption fails instead of recognizing partial audio.
- In configuration callbacks, read the current engine from recorder state
  inside the main actor, guarded by capture identity. Do not capture
  `AVAudioEngine` across a Sendable closure: the CI SDK does not mark it
  Sendable, even when the newer local SDK accepts that capture.
- `SelectionTarget.capture(allowingCaret: true)` is explicit to dictation; the
  default still requires a selection for translation/Rewrite. Validate the
  original element, range, text and activity. Decode AX ranges with nonnegative
  location and length before the caret opt-in can admit a zero length. Option produces modifier events,
  not text edits; keep ordinary keys, clicks and switches invalidating targets.
  If no range exists and the focused element is the exact focused standard
  window, dictation alone may capture a window target for custom renderers.
  Require its exposed children to be standard window controls only; unknown
  children or normal accessible content keep the result rather than guessing.
  Keep process/window identity and activity guards. Do not extend that path to
  secure fields, sheets, dialogs, unknown roles or translation. It cannot detect
  programmatic field changes inside an inaccessible custom window.
- `DictationDelivery` captures a stable clipboard snapshot near delivery, guards
  its change count, and restores only its own write. No selection-copy probe.
  Recheck unconfirmed AX evidence at the end of the clipboard retention wait;
  a delayed acknowledgement must not cause another paste. Observe cancellation
  after that wait. Verification diagnostics record metadata only.
  An empty rich editor may drop its single LF placeholder after paste. Accept
  that only for dictation at offset zero with exact inserted text and a collapsed
  caret at its UTF-16 end. Do not trim arbitrary user whitespace.
  Missing target evidence yields the result popup, not a global paste elsewhere.
  Delivery distinguishes confirmed text, window dispatch without AX text proof,
  and a retained result. Keep the last transcript available for explicit Copy.
- Hold-to-talk is the only recording mode. Default to right Option; the binding
  field accepts left or right Option only. Press begins capture, release finishes,
  other input cancels. No toggle, menu-start path or dedicated cancellation key.
  Escape is not registered for dictation. Keep the hold monitor alive on press
  or its release will be lost. `OptionKeyGesture` observes local/global NSEvent events.
  Keys, other modifiers, clicks and scroll cancel. Carbon actions cancel too.
  Repeated flags for the same held Option are ignored, not treated as new input;
  they never rearm a hold already blocked by cancellation.
  Release during microphone startup drains the already-started recording;
  asynchronous model preparation never precedes capture.
  The shortcut binding recorder and runtime share the state machine. Shortcut recording pauses all registrations
  and monitors, including reloads triggered by completion; generations discard
  callbacks from removed monitors.
- Permission prompts belong to enabling dictation. A release build needs both
  the audio-input entitlement and microphone purpose string. Test with the signed
  dev bundle, never the installed app's settings or privacy state.
- Keep a shared 20-point icon slot in the listening and recognizing indicator
  states so the text does not shift when the symbol changes. Native previews
  render those states without opening the microphone; they do not verify recording.
