# Minimal dictation plan

> Current catalog: Whisper large-v3-turbo and Qwen3-ASR only. Fresh profiles select
> Turbo through 16 GiB of memory and Qwen above 16 GiB. Existing valid choices
> are preserved; saved Small and Large v3 values resolve to Turbo. Earlier
> four-model catalog and recommendation descriptions below are historical.


Scope decisions: October 18-19, 2026. Target: Translate Like Me, macOS 15+ on Apple
silicon, initially an M5 with 16 GB or more of unified memory.

The user requires a minimal implementation that works well with sensible defaults.
This document supersedes the broader feature priorities in the
[FluidVoice review](fluidvoice-source-review.md) and
[Handy review](handy-source-review.md). Those are research references, not a backlog.
The implementation uses WhisperKit for Turbo and MLX Audio Swift for Qwen.
The October 19 user request added a dedicated Dictation pane and model selection.
The later first-run policy retains Turbo and Qwen only, selected by memory for
new profiles. Implementation details and verification status are in
[dictation.md](dictation.md); this scope document is not a claim that release
acceptance or a comparative model quality benchmark is complete.

## Product contract

The only recording flow is hold-to-talk: hold right Option, speak, then release
to receive text at the cursor. Left Option can be assigned instead. Undo after insertion belongs to the
destination editor; dictation has no dedicated cancellation key.
The user explicitly confirmed that the microphone must be active only while
the key is held. Do not add continuous background capture or a pre-press audio
buffer. Reduce startup work within that constraint; the investigation and
acceptance matrix are in [startup latency](dictation-startup-latency.md).
Automatically detect and transcribe every language supported by the selected
multilingual model, without a Russian/English allowlist or a required language
picker. Russian, English, and mixed speech remain priority quality checks, not
the boundary of supported languages. Languages from complete translation pairs
receive a bounded preference during automatic detection across all offered
models, while other supported languages can still win. With no pairs, or when
any pair language is unsupported by the active model, keep unrestricted
detection. See [language detection](dictation-language-detection.md).
Ordinary dictation is local and does not invoke a text-processing LLM.

Provide one recommended default within the curated local model catalog. Choose
the default from measured speech quality, correction effort, latency, and memory
on the target Mac. The user must not choose a model or an inference configuration
to obtain usable results. The optional picker offers Whisper large-v3-turbo and Qwen3-ASR. It does not require users to tune inference settings or
choose a model during setup. Shared language behavior applies to both runtimes.

## First use and settings

- Use a dedicated Dictation pane in Settings, with an enable control, one editable
  Option hold key, model selection and preparation status when relevant.
- Enabling dictation requests microphone access and prepares the selected
  model, downloading it automatically with visible progress. Interrupted setup
  offers Retry. Do not request an account, API key, or model selection.
- Default to right Option, with left Option available in the same binding field.
  No tap-to-toggle mode, push-to-start menu command, or ordinary combination is
  part of dictation. Translation and Rewrite keep their existing shortcuts.
- Follow the system input microphone by default. Detect device changes and
  recover without requiring the user to manage an application-specific
  microphone preference. Settings (not first-run setup) offers an optional
  Microphone picker, user decision 2026-10-21: a chosen device keeps dictation
  off a Bluetooth headset that macOS makes the default input, without changing
  the input of other apps. A disconnected choice falls back to the system input.
- Once ready, normal use requires no Settings visit. Preparation is a one-time
  dependency on network access; recognition after installation works offline.

Right Option is the initial hold key. Model quality and native key behavior
remain subject to validation; do not present an untested configuration as proven.

## Visible behavior

- A compact nonactivating indicator shows preparation, listening with audio level,
  and recognition. It must preserve focus in the destination app.
- Insert the final transcript once. Support both an empty caret and a selection.
  Preserve names, English terms inside Russian speech, and the meaning of the
  dictation. Use the model's normal punctuation without a separate cleanup model.
- Insert wherever keyboard focus is when the text is ready, in any app (user
  decision, October 20, 2026, replacing validation of the original destination).
  The destination's read of the clipboard proves delivery; without it, or in a
  secure field, show the result in the existing popup pattern with Copy. Keep
  only the latest result in memory so it can be recovered; do not create a
  history screen.
- Internal cancellation invalidates pending output after input changes, disabling
  or sleep. Never start a delayed recording because a hold began while another
  operation was busy. Do not add a separate cancellation key or waiting period.

## Engineering needed for the basic flow

Keep these mechanisms internal, with automatic defaults rather than new controls:

- Explicit session identity and capture/recognition/delivery state. Ignore stale
  callbacks, prevent overlapping insertion, and handle stop during startup.
- Model installation with a pinned artifact, integrity verification, progress,
  resumable transfer where supported, and clear failure recovery.
- Microphone permission handling, actual-sample readiness, complete capture drain,
  sleep/wake and device-change recovery, and bounded recording memory.
- Measured model residency: keep the model ready and release it on memory pressure
  or when dictation is disabled, after capture/inference finishes. No policy picker.
- Reuse rich clipboard preservation. Deliver at the current focus with a clipboard
  read receipt, without weakening translation's selection requirements.

Start with batch recognition after stop. Add VAD filtering, chunking, a helper
process, or native streaming only if a measured quality, latency, or reliability
problem in the chosen backend requires that mechanism. Keep any required mechanism
behind the same simple flow. Do not build a provider framework for hypothetical
future engines.

## Outside this implementation

Standalone left/right Option was added at the user's request. Other modifier-only
keys remain outside the scope. No tap-to-toggle or combined tap/hold mode, live transcript preview,
model browser, custom dictionary, per-app profiles, voice commands, automatic
sending, meeting recording, audio archive, statistics, or separate local cleanup
LLM. Dictation-to-Rewrite and dictation-to-translation automation are also outside
this first release; the existing text actions remain available as they are.

These are scope exclusions, not a scheduled second phase. Additions require an
observed need and a separate product decision.

## Release evidence

Verify that automatic language detection is not constrained to Russian and
English, and exercise representative additional languages supported by the model.
Prioritize recognition quality on Russian, English, mixed technical terms,
quiet/short utterances, silence, and multi-minute dictation. Check cold
preparation, warm stop-to-text delay, memory after repeated sessions, and offline
recognition after installation. If a model fails the target use, improve or replace
the default rather than exposing tuning controls as the remedy.

Verify insertion in native text fields, browser editors, Electron editors, and
terminals with synthetic text. Exercise changed focus, newer clipboard content,
release during startup, cancellation on input changes, denied permissions, interrupted model
setup, microphone disconnect, sleep, and wake. Render the indicator and Settings
in both appearances and at minimum window size. These are required checks, not
completed test results.
