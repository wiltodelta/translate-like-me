---
paths:
  - "Sources/TranslateLikeMe/Dictation*.swift"
  - "Sources/TranslateLikeMe/ModelSnapshot.swift"
  - "Sources/TranslateLikeMe/HotKeyManager.swift"
  - "Sources/TranslateLikeMe/OptionKeyGesture.swift"
  - "Sources/TranslateLikeMe/Shortcut*.swift"
  - "Sources/TranslateLikeMe/SelectionTarget.swift"
  - "Sources/TranslateLikeMe/PasteDelivery.swift"
  - "Tests/TranslateLikeMeTests/Dictation*.swift"
  - "Tests/TranslateLikeMeTests/ModelSnapshotTests.swift"
  - "Tests/TranslateLikeMeTests/OptionKeyGestureTests.swift"
description: "Minimal local dictation: model, recording lifecycle, cancellation, and caret delivery"
---

# Local dictation

Product scope: `docs/dictation-feature-plan.md`. Implementation and verification:
`docs/dictation.md`. A small curated local ASR catalog, automatic detection within each model's languages,
one Option hold key, system microphone unless one is chosen in Settings, no cleanup LLM. Settings has a dedicated
Dictation pane. The user explicitly added model selection after the 3.5.0 release.
Compute-policy findings and the reproducible synthetic benchmark:
`docs/dictation-model-efficiency.md`.

- `DictationModel` lists Whisper large-v3-turbo (the upstream model name, including its version)
  and Qwen3-ASR 1.7B 8-bit (30 languages). Fresh profiles select Turbo through
  16 GiB and Qwen above 16 GiB; existing valid choices remain authoritative.
  `DictationLanguagePreference` snapshots languages from complete translation
  pairs on every transcription. Canonicalize configured and native language codes
  through Foundation before resolving the active model inventory; return its native
  spelling. Both runtimes apply the same finite logit
  preference during language selection only, never a language or script ban.
  No pairs or any unsupported candidate preserves unrestricted detection.
  WhisperKit's separate language pass needs its sampler adapter; text logits
  filters do not reach it. Qwen matches prefixes with its active tokenizer and
  stops applying the preference before text. Native MLX sampling tests need Metal
  kernels even in a CPU device scope. CI builds them before tests and supplies
  `TLM_QWEN_METALLIB`; a configured but missing library must fail. Details and evidence:
  `docs/dictation-language-detection.md`.
  Qwen uses native MLX on the GPU, with no Python requirement. Parakeet Ultra
  was removed; its saved raw value falls back to Turbo, as do removed Small and Large v3 choices.
  Preserve Turbo and its existing cache for absent or unknown preferences.
  Turbo uses CPU/Neural Engine for its encoder and decoder.
  Whisper mel stays CPU/GPU. Silero stays CPU-only. Measurements and
  first-specialization limits are in `docs/dictation-model-efficiency.md`.
  The selected model persists while disabled without preparing assets or requesting
  permissions. An enabled change prepares it automatically; a change during
  preparation cancels and unwinds before preparing the latest selection. Block
  changes during capture, recognition and cancellation. Keep old downloads, but
  unload the old runtime before loading another model.
- `DictationEngine` owns WhisperKit and delegates Qwen to its own actor. Qwen
  weights and tokenizer inputs share the pinned snapshot checks. The SDK's
  derived tokenizer.json stays in disposable staging outside that snapshot.
  Qwen's greedy loop runs in the calling task, checks cancellation per token,
  and synchronizes GPU work before returning. Past the language prefix
  (`DictationLanguagePrefix.reach`) it queues the next step before reading the
  current token; loading ends with a one-second silent warm-up. Use the SDK's low-energy 30-second
  chunks and fresh decoder caches; reaching the token/repetition backstop reports
  an error, never a partial transcript. Installation and offline checks:
  `docs/qwen-integration.md`.
  Model and tokenizer revisions
  are pinned. `ModelSnapshot` checks every required Core ML component and
  hashes existing files against the pinned revision's Hub metadata, using SHA-256
  for LFS and Git blob SHA-1 for ordinary files. Remove corrupt files before
  resuming a partial download, preserve good files, and validate the result again;
  a transient `URLError` refetches after the network returns, resuming the SDK's
  `.incomplete` files, until five attempts in a row add no bytes;
  the SDK admits partial caches and trusts matching metadata without rehashing.
  Load only verified local files and suppress SDK transcript logging.
  Validate Whisper tokenizer hashes explicitly; the SDK's literal
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
  before preparing the next session. Enqueue capture on press; the press reads
  no AX target;
  `DictationCaptureWorker` serializes all engine access and teardown off the UI.
  The request lock guards state only, never hardware startup. The worker checks
  activity before startup and stops the engine after startup if release arrived
  meanwhile, so release and cancellation never wait on the hardware-start lock.
  The stop task must finalize the WAV before model reload or recognition. Enqueue
  discard on the same queue before another start; never open an idle microphone.
  Flush capture cleanup synchronously at application termination, before exiting.
  Startup findings, the raw prepared input and the rejected idle-ducking cache:
  `docs/dictation-startup.md`.
  Reload the model only after release, while retaining the drained audio.
  Interrupted initial preparation retries after the old task unwinds, never
  reports ready with missing assets, and does not restart during termination.
  Do not reintroduce timed
  eviction without measuring reload latency.
- Capture uses raw `AVAudioEngine` input, without voice processing: its per-press
  initialization cost about 1.2 s and lost first words, and a prepared
  voice-processing unit kept media ducked while idle (user decision 2026-10-20,
  `docs/dictation-startup.md`). Between holds the worker keeps the engine
  prepared but stopped, with the relay tap and a first-audio sink node
  installed; it opens no microphone
  (process input-running reads zero). Warm up only with an existing grant, after
  preparation's permission check; rebuild after wake, on an idle configuration
  change, on a microphone choice, or when the resolved input or its format
  differs from the one the engine was built on. `DictationInputRoute.resolve`
  validates the chosen UID, liveness and input channels, else uses a usable
  default without overwriting the preference. Explicit choices are bound even
  when they equal the current default; only the system/fallback path is unbound.
  Compare UID and native rate/channels/data source as well as numeric ID.
  Snapshot the route after building the graph: building an AirPods graph moved
  their nominal rate between 24 and 48 kHz, and a pre-build snapshot rebuilt the
  idle graph about four times a second.
  `DictationInputObserver` forwards topology and selected-device property events
  to the capture queue, unregisters on shutdown and ignores unchanged snapshots.
  Re-prepare an absent idle input when hardware returns. Drain rechecks the route
  and running state rather than trusting notification delivery. Details and
  hardware coverage: `docs/dictation-device-compatibility.md`.
  The I/O unit's current device is the engine's aggregate, not the input;
  compare the input resolved at build. Re-prepare after
  every stop or discard and drop a graph that failed to start; disabling
  dictation releases the engine, after a hold in progress ends.
  The press mutes the default output (`DictationOutputMute`) only if it was
  unmuted, persisting the device UID until release; release unmutes only if it is
  still muted, resolving its stable UID rather than a potentially reused device id.
  Keep the recovery record if the device is disconnected or unmuting fails;
  retry on launch, idle preparation and before another hold. Never lower volume or
  change it otherwise. Install the tap with a nil format and read the format
  after it: AirPods changed format between a read and the tap, and a stale tap
  format raises an uncatchable Objective-C exception. Write native PCM.
  `DictationAudioLoader` selects one stable channel by non-DC energy and drains finite AVAudioConverter input fully to 16 kHz mono; never
  sum arbitrary input channels or relabel their rate. Tap
  callbacks are explicitly `@Sendable` and never enter the main actor for audio
  writes; the relay forwards only while a hold's sink is attached. The locked sink
  closes before recognition and rejects late writes. Bound capture by frame
  count. While the hold has delivered only digital silence, it may rebuild the graph and
  WAV at most twice after a configuration interruption (Bluetooth switches to
  HFP at startup) or a failed `start()` (AirPods returned -10868 on a graph
  prepared for their previous format). A running graph that delivers no buffer
  within 1 s is rebuilt from the same budget: an AirPods graph built during their
  mode switch started without error and stayed silent. An exhausted budget fails
  the hold through one shared path. The controller only caps the whole startup
  at 10 s from the press, since an AirPods rebuild took 2.5 s. Keep output mute ownership through this recovery;
  release/cancel forbids another start. After any nonzero audio, an interruption fails
  instead of recognizing partial audio. Tear down a failed graph, and ignore
  notifications from older graph generations. Buffer arrival and nonzero signal
  are distinct: a zero PCM buffer proves capture activity but must not close
  the recovery window. Do not infer a broken route from silence alone, since a
  hardware-muted headset can deliver a stable zero stream.
- In configuration callbacks, read the current engine from worker state
  inside the capture queue, guarded by the engine generation. Do not capture
  `AVAudioEngine` across a Sendable closure: the CI SDK does not mark it
  Sendable, even when the newer local SDK accepts that capture. Offline tests
  create and use their engine inside one task, returning only sample values.
- Delivery goes wherever keyboard focus is when recognition finishes, in any
  app (user decision 2026-10-20): typing, clicks and app switches during
  recognition no longer retain the result. Field-level AX targets and the
  custom-renderer window target were removed after a day of logs showed them
  failing in Chrome, Claude, Slack and on any click; translation and Rewrite
  now deliver the same way (`architecture.md`). `SelectionTarget.destination`
  is AX's focused process, else the frontmost app; only a secure text field or
  no process at all retains the result.
- `PasteDelivery.insert` snapshots the clipboard just before writing; the
  shared `PasteDelivery` resolves the destination, guards the change count and
  restores only its own write. It promises the string through `PasteReceipt`
  and posts Paste to the destination pid: a read of the promised string is the
  delivery proof, because a paste must read the clipboard and AX cannot see
  into custom renderers. Restore only after that read (300 ms later, never
  before 700 ms), so a busy app never pastes the older clipboard; the previous
  fixed 720 ms wait raced slow apps. No read within 3 s retains the result
  without a second paste. TransientType keeps clipboard managers from reading
  it. Cancellation still restores. Diagnostics log the destination bundle id,
  pid and read latency, never text. The Paste key code comes from
  the ASCII-capable layout (`KeyboardLayout`, main thread only), so Dvorak sends
  Cmd+V rather than the fixed ANSI code's Cmd+K; Russian and other non-Latin
  layouts use their ASCII-capable layout. Keep the last transcript in `LastResults` for
  explicit Copy Last Result > Dictation, shared with Translation and Rewrite.
- Hold-to-talk is the only recording mode. Default to right Option; the binding
  field accepts left or right Option only. Press begins capture, release finishes
  after a tail of up to one second that catches a last word spoken while letting go
  (`DictationController.liveReleaseTail`; the output stays muted through it); it
  ends early after 300 ms of quiet, never before 200 ms, and runs in full when the
  hold has no quiet buffer 15 dB under its loudest (`docs/dictation-latency.md`),
  other input during the hold cancels. No toggle, menu-start path or dedicated cancellation key.
  Escape is not registered for dictation. Keep the hold monitor alive on press
  or its release will be lost. `OptionKeyGesture` observes local/global NSEvent events.
  Keys, other modifiers, clicks and direct scrolling cancel. Momentum scroll
  events from a previous flick do not cancel the hold. Carbon actions cancel too.
  Repeated flags for the same held Option are ignored, not treated as new input;
  they never rearm a hold already blocked by cancellation.
  Release during microphone startup drains active capture or cancels its pending start;
  asynchronous model preparation never precedes capture.
  The shortcut binding recorder and runtime share the state machine. Shortcut recording pauses all registrations
  and monitors, including reloads triggered by completion; generations discard
  callbacks from removed monitors.
- `DictationModelDownloads` manages speech files without microphone permission or runtime loading.
  It shares the model-management sheet with Translation; file ownership and
  removal protection are documented in `docs/model-management.md`.
- During onboarding, `OnboardingFlow` prepares speech assets without permission
  or capture and unloads the runtime before the translation check. Microphone
  consent comes on the second screen; enabling dictation follows both grants.
  Outside onboarding, permission prompts belong to enabling dictation. A release build needs both
  the audio-input entitlement and microphone purpose string.
- The indicator appears only when the microphone delivers its first nonzero
  sample, or once a second of zero frames is recorded (a hardware-muted input;
  `DictationAudioFile.isListening`):
  a cold AirPods microphone sent about 0.5 s of exact zeros first, and speech then
  was lost. Normally this is `.starting` to `.recording` about 60 ms after the press: an
  `AVAudioSinkNode` sees 512-frame I/O cycles while the tap delivers 100 ms
  buffers, and the meter polls every 10 ms until then, every 50 ms after), already reading
  Listening: a Preparing state was taken for "wait before speaking", and
  Listening before audio invites words the recording misses. Keep a shared 20-point icon slot in the listening and recognizing indicator
  states so the text does not shift when the symbol changes. Native previews
  render those states without opening the microphone; they do not verify recording.
- Bluetooth headsets dictate less accurately than the built-in microphone
  (vendors and the 2026-10-25 recordings agree, `docs/dictation-device-compatibility.md`),
  but the input stays the user's choice (decision 2026-10-25). The Dictation pane
  notes it under the microphone picker while the input a hold would use is
  Bluetooth, and the indicator adds "The built-in microphone is more accurate"
  for a whole hold at most once an hour (`DictationHeadsetTip`, in memory).
  Preview it with `-dictationPreview headset`.

Native capture restores the complete backed-up development preference domain
with `setPersistentDomain`, after stopping its owned app. `defaults import`
merges and leaves newly added keys behind; the regression and verified cleanup
are recorded in `docs/parakeet-ultra-integration.md`.
