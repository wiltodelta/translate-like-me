# Handy source review for dictation

Review date: October 18, 2026. Reviewed [cjpais/Handy][snapshot] at
`9e57a0d7929fcc6417ea0d6e54c1b57f62635edd`. This supplements the
[dictation feature plan](dictation-feature-plan.md) and
[local model research](dictation-research.md).

> Research findings, not implementation scope. The user subsequently requested a
> minimal product. The [minimal dictation plan](dictation-feature-plan.md) supersedes
> this review's feature priorities and implementation recommendations.

This is a static review of capture, VAD, decode policy, model lifecycle,
worker recovery, text correction, clipboard delivery, and relevant settings.
Handy was not launched or benchmarked, and its tests were not executed.
Code paths below establish implemented mechanisms, not their measured quality.

Handy uses a Rust/Tauri backend and React settings. Its current
[manifest][manifest] routes ASR through `transcribe-cpp` and enables Metal on
macOS. The [catalog][catalog] includes modern multilingual checkpoints such as
Qwen3-ASR, Nemotron 3.5, Voxtral Realtime, and Whisper. The README's short
Whisper/Parakeet description does not represent the entire current runtime.
Catalog presence and a capability flag do not prove recognition quality on an M5,
and catalog speed/accuracy scores are not a substitute for our own benchmark.

## Findings that change the implementation plan

### An explicit state machine for recording and cancellation

[TranscriptionCoordinator][coordinator] separates Idle, Recording, and Processing
and returns effects from its state transitions. Hold, toggle, and combined
hold-or-toggle share the same machine. It also handles deferred key releases and
presses received while processing; cancellation clears a remembered start.

Adopt the explicit lifecycle and session identity before adding ASR to our
controllers. A stop during startup, Escape during inference, and a late callback
must have defined outcomes. Start with hold and toggle, plus a visible busy state;
do not silently queue a future microphone start behind slow processing. Combined
tap/hold is a later convenience rather than a release prerequisite.

### ASR model unloading belongs in the first implementation

The [transcription manager][unload] actually watches ASR activity and unloads its
model after the configured timeout. Recording refreshes activity, and immediate
unloading is handled after transcription rather than by a zero-second idle timer.
[Unloading][unload-api] waits for the model worker to exit when completion is
required, for example before deleting the model file.

This adds ASR-specific evidence to the earlier FluidVoice finding, which concerned
its private AI processor. On a 16 GB Mac, define and measure our ASR residency
policy in the first release. Keep a recently used model warm, release it after
inactivity, and exclude active capture/inference from unloading. Pick the actual
timeout from warm memory and reload measurements. An automatic policy is enough;
Handy's long timeout picker is not necessary for our basic Settings pane.

### Choose decoding from the loaded model's capabilities

[Model capability reconciliation][capabilities] updates streaming, translation,
language detection, and language lists from runtime evidence. The
[settings card][model-ui] only exposes language/translation controls when the model
advertises them. [Decode policy][policy] chooses native streaming first, then
optional chunking for a model without native long-form support, otherwise batch.

Adopt this capability-driven behavior with a small curated model list. Unknown
capabilities must remain unknown until checked. Do not force a language hint on a
backend that cannot use it, or simulate a streaming promise from a model name.
Keep Russian, English, and mixed-speech evaluation independent of UI metadata.

### Long dictations can be decoded in chunks while recording

The [chunk planner][chunking] looks for pauses near a target chunk duration and
uses bounded fallback cuts. Its current policy leaves clips up to 40 seconds whole
and aims near 30 seconds for longer audio; those are this implementation's
constants, not universal model limits. [Chunked decoding][chunked] recognizes
completed chunks while recording, so only the remainder needs work at stop.
The [live path][live] also checks whether it saw the whole recording and can fall
back to batch. Explicit cancellation remains cancellation.

Promote long-dictation evaluation into first-release acceptance. If the selected
model degrades on multi-minute speech or has excessive stop latency, use chunking
for that backend. Test cuts, repetitions, punctuation, and Russian/English switches
across boundaries. Do not chunk a native streaming or long-form model merely to
copy Handy's defaults.

### VAD needs speech margins and a backend-specific policy

[Smoothed VAD][vad] buffers frames before detected speech and keeps a tail after
speech, rather than cutting strictly at every voice/noise decision. The
[capture sink][sink] supports disabled, offline, and streaming policies, resets
the detector per recording, and emits level updates separately from filtered PCM.
Readiness is signaled by delivered audio, including silence, rather than speech.

Adopt conservative speech margins and verify short/quiet words and final phonemes.
The pre-roll here preserves frames already captured before VAD recognition; it
does not record speech before the user starts the microphone. Treat aggressive
silence removal as a possible source of recognition errors. A detector failure
should preserve audio rather than erase it; Handy's sink forwards the frame on a
VAD error. Keep capture readiness separate from speech detection.

### Downloads should resume and detect a stalled transfer

The [HTTP transport][download] keeps partial downloads, requests the remaining
range, handles a server ignoring Range by restarting, validates resumed offsets,
and checks expected length and SHA-256 when available. It distinguishes a stalled
body from a slow transfer. Custom artifacts without an expected hash skip that
verification, so this does not establish identical integrity guarantees for every
model source.

Extend our planned model manager with resume, a bounded stall timeout, and a clear
retry state. Use pinned artifact identities and checksums for the curated catalog.
Keep model-file import and arbitrary repositories outside the initial UI.

## Useful additions after the core works

- **Isolate native ASR failures.** The [engine supervisor][supervisor] launches the
  executable as a worker, uses request deadlines, kills an unresponsive worker,
  and bounds retries. Depending on the failure/device selection, it can retry in
  a fresh CPU-only worker. This is a strong option if our chosen integration uses
  C/C++ native inference; choose a helper/XPC design appropriate for a signed macOS
  app rather than transplanting Tauri's launcher. Do not assume every Swift/Core ML
  backend needs a subprocess. Retain audio until success or cancellation so a
  recoverable engine failure does not require repeating the dictation.
- **Retry recognition without speaking again.** Handy's [history retry][retry]
  reads retained WAV audio and calls the transcription manager again. Our smaller
  version can retain only the latest session's audio in bounded memory and offer
  a retry or another installed model. Define expiry and clear it on cancellation;
  a persistent searchable audio archive remains outside the initial scope.
- **Keep ordinary settings short.** The [General view][general] groups shortcuts,
  model-dependent controls, microphone, and feedback; [Advanced settings][advanced]
  holds many processing/output details. Adopt progressive disclosure and automatic
  defaults. Our native app can keep its Dictation pane smaller still, without
  exposing VAD engines, typing tools, accelerator selectors, or buffer timings.

## Ideas requiring care for this app

- **Fuzzy dictionaries are not a bilingual solution.** The [fallback matcher][text]
  creates keys only for ASCII alphanumeric terms and uses English Soundex where
  applicable. Cyrillic words are skipped by that path. The [run setup][vocabulary]
  passes vocabulary to models that support it, and final processing avoids fuzzy
  correction when the model already received custom words. Prefer explicit Unicode
  replacements and native vocabulary conditioning; evaluate fuzzy correction
  separately before allowing it to alter English names or code.
- **Text cleanup can delete legitimate content.** Handy [gates some filler
  tokens][fillers] on output-language evidence, which is better than using UI
  language as evidence. However, built-in universal tokens still apply when the
  language is unknown. Its normalization also collapses repeated whitespace and
  stutters separately from the filler-removal switch. Keep our literal mode
  conservative and preserve intentional repetition and paragraph breaks. Broader
  cleanup belongs in an explicit Rewrite operation.
- **A clipboard read is not confirmed insertion.** Handy's debug-gated
  [receipt-sequenced paste][paste] publishes promised data on macOS, waits for a
  post-keystroke read and a quiet period, then restores while it still owns the
  clipboard. The [macOS implementation][mac-paste] records any text consumer's
  read, not an authenticated receipt from the intended field, and saves text or an
  image rather than every original pasteboard representation. Evaluate delayed
  restoration as a separate experiment; retain our target checks, rich snapshot,
  newer-copy protection, and actual replacement verification. Do not infer a defect
  in our existing paste path from Handy's old fixed-delay implementation.
- **Retain Carbon for ordinary hotkeys.** Handy's [Secure Input handling][secure]
  detects affected event-tap shortcuts and shadow-registers suitable combinations
  through its Carbon-backed path. Our existing ordinary hotkeys already use Carbon.
  This is a reason to preserve that path and test release/cancel behavior, not to
  import an event-tap system and its fallback machinery for every shortcut.
- **Keep the product focused.** Auto-submit, external paste scripts, always-on
  microphone capture, a large community-model browser, and many advanced switches
  are not prerequisites for our dictation workflow. The runtime ideas are more
  valuable to this project than reproducing Handy's entire Settings surface.

## Revised priority

First-release engineering now includes an explicit session state machine,
capability-driven model behavior, conservative VAD boundaries, resumable verified
downloads, and measured ASR memory residency. Long-dictation quality must be tested
before deciding whether chunking is required for the first selected backend.

Next come native-runtime isolation where justified, retry from the last audio,
dictionary support, and optional processing through the existing presets. These
refinements preserve the original product flow: shortcut, speech, text at the
cursor, with a recoverable result when delivery fails.

[snapshot]: https://github.com/cjpais/Handy/tree/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd
[manifest]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/Cargo.toml
[catalog]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/catalog/catalog.json
[coordinator]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/transcription_coordinator.rs#L219
[unload]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/managers/transcription.rs#L287
[unload-api]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/managers/transcription.rs#L429
[capabilities]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/managers/model.rs#L970
[model-ui]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src/components/settings/general/ModelSettingsCard.tsx
[policy]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/managers/transcription/policy.rs
[chunking]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/audio_toolkit/chunking.rs
[chunked]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/managers/transcription/chunked.rs
[live]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/managers/transcription/live.rs
[vad]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/audio_toolkit/vad/smoothed.rs#L55
[sink]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/audio_toolkit/audio/sink.rs
[download]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/managers/model/download.rs#L186
[supervisor]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/engine_supervisor/supervisor.rs#L879
[retry]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/commands/history.rs#L63
[general]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src/components/settings/general/GeneralSettings.tsx
[advanced]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src/components/settings/advanced/AdvancedSettings.tsx
[text]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/audio_toolkit/text.rs#L30
[vocabulary]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/managers/transcription.rs#L1149
[fillers]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/audio_toolkit/text.rs#L305
[paste]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/paste_tx/mod.rs
[mac-paste]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/paste_tx/macos.rs
[secure]: https://github.com/cjpais/Handy/blob/9e57a0d7929fcc6417ea0d6e54c1b57f62635edd/src-tauri/src/secure_input.rs#L478
