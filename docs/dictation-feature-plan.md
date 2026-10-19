# Minimal dictation plan

Scope decisions: October 18-19, 2026. Target: Translate Like Me, macOS 15+ on Apple
silicon, initially an M5 with 16 GB or more of unified memory.

The user requires a minimal implementation that works well with sensible defaults.
This document supersedes the broader feature priorities in the
[FluidVoice review](fluidvoice-source-review.md) and
[Handy review](handy-source-review.md). Those are research references, not a backlog.
The implementation uses WhisperKit with a small multilingual Whisper catalog.
The October 19 user request adds a dedicated Dictation pane and model selection;
Turbo remains the default, with Small and Large v3 as optional alternatives. Implementation details and verification status are in
[dictation.md](dictation.md); this scope document is not a claim that release
acceptance or a comparative model quality benchmark is complete.

## Product contract

The only recording flow is hold-to-talk: hold right Option, speak, then release
to receive text at the cursor. Left Option can be assigned instead. Undo after insertion belongs to the
destination editor; dictation has no dedicated cancellation key.
Automatically detect and transcribe every language supported by the selected
multilingual model, without a Russian/English allowlist or a required language
picker. Russian, English, and mixed speech remain priority quality checks, not
the boundary of supported languages. Ordinary dictation is local and does not
invoke a text-processing LLM.

Provide one default local model and one ASR integration. Choose the default from
measured speech quality, correction effort, latency, and memory on the target Mac.
The user must not choose a model or an inference configuration to obtain usable
results. The optional model picker offers three curated multilingual variants. It does
not require users to tune inference settings or choose a model during setup.

## First use and settings

- Use a dedicated Dictation pane in Settings, with an enable control, one editable
  Option hold key, model selection and preparation status when relevant.
- Enabling dictation requests microphone access and prepares the selected
  model, downloading it automatically with visible progress. Interrupted setup
  offers Retry. Do not request an account, API key, or model selection.
- Default to right Option, with left Option available in the same binding field.
  No tap-to-toggle mode, push-to-start menu command, or ordinary combination is
  part of dictation. Translation and Rewrite keep their existing shortcuts.
- Follow the system input microphone. Detect device changes and recover without
  requiring the user to manage an application-specific microphone preference.
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
- Validate the original destination before inserting. If it changed or delivery
  failed, show the result in the existing popup pattern with Copy. Keep only the
  latest result in memory so it can be recovered; do not create a history screen.
  Custom-rendered apps exposing only their standard window use process/window
  identity and uninterrupted input activity. That path dispatches Paste without
  claiming text confirmation; it does not apply to translation or Rewrite.
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
- Reuse rich clipboard preservation and destination validation. Add a caret-capable
  delivery target without weakening translation's selection requirements.

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
