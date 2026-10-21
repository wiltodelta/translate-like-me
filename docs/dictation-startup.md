# Dictation startup investigation

> The voice-processing recorder described through "Verification of the queued
> implementation" was replaced by raw prepared input; see the last section.

October 20, 2026. The user approved optimizing startup without background
microphone capture. The reported installed version was 3.7.4.

## Diagnosis and rejected cache

Six installed-app holds correlated with Core Audio processing-start events took
820-1,472 ms from press, median 1,030 ms. Target capture followed 2-16 ms later.
These events do not identify the first tap frame or visible indicator frame.
The recorder recreated VoiceProcessingIO synchronously on the main actor on
both every press and teardown, so the indicator could not render during startup.

A signed development probe compared the 3.7.4 recorder with a prepared, paused
graph in separate processes, reversing arm order. The cached prototype reduced
median first audio from 1,054 to 146 ms across twelve paired observations, all
in the same direction. The capture process's Core Audio input-running property
was zero before capture and after stopping, and one during capture. Temporary
WAVs were finalized and removed without transcription.

That cache was rejected. A separate continuously rendering digital-silence
process let the Core Audio logs expose its ducking coefficient without playing
sound. VoiceProcessingIO retained the attenuation request after pause, despite
not using the microphone. Advanced-ducking changes, bypass and explicit audio
unit uninitialization did not establish idle volume restoration; only full
voice-processing teardown requested a coefficient of one. The 146 ms result is
an abandoned prototype, not a claim about the shipped implementation.

## Implemented behavior

Capture initialization and teardown move to `DictationCaptureWorker`'s serial
queue. The main actor enqueues the request and shows the starting indicator
before reading the target. `Listening` still requires frames in the real sink.
The locked `DictationCaptureRequest` prevents a release or cancellation during
initialization from being followed by a late hardware start. Finishing returns
a task that closes the WAV before model preparation or inference. Discard and
subsequent starts use the same queue; observer callbacks check request identity.
Full voice-processing teardown remains, preserving idle audio behavior.

No microphone runs between holds. This change addresses delayed feedback and
UI blocking; it does not promise immediate capture of the first spoken word.
Physical VoiceProcessingIO initialization remains a limitation. There is no
silent fallback to raw input, persistent ducking, or continuously running input.

Unit checks cover feedback ordering, delayed drain, cancellation while draining,
and the release gate. Native timings, input activity, silence-reference volume
checks and recipes are retained under `.build/diagnostics/dictation-startup/`.
A native preview supports `-dictationPreview starting` without microphone access,
as well as the existing recording and recognizing previews.

## Verification of the queued implementation

The queued recorder's start call returned in 0.12-1.08 ms, median 0.155 ms,
across eleven completed captures in two fresh-process runs. First audio still
arrived after about a second; this is not a first-frame or speech-capture speed
claim. One further capture reported an engine/configuration interruption and
the native harness rejected it. The results are 11/12 completed captures, not
an unconditional pass. The production worker stores an interruption error on
the request before notifying the UI, so draining cannot admit partial audio
if a release races the notification. These metadata-only runs do not test
near-end speech quality or establish a cross-device failure rate.

Six additional 30 ms holds ended before hardware start. Each drain reported
cancellation, with the process input-running field read back as zero. A
mutation of a disposable request-source copy that removed its release guard
changed the standalone regression from exit zero to exit one. The production
source was not mutated. Unit checks also hold the drain with a continuation
and prove recognition waits, then prove cancellation suppresses recognition.

A separate final lifecycle probe read input activity as zero before capture,
one during capture, then zero after stop, discard and release. A separate
process continuously rendered digital silence with an advancing frame counter.
The voice-processing path requested ducking 0.056234 during initialization and
unity on full teardown. This validates the teardown request and input state;
it does not establish perceptual restoration or turn an API request log into
an acoustic gain measurement. The paused cache never made that unity request
until released and remains rejected. No real system volume preference changed.

The signed development bundle rendered the existing starting indicator in both
appearances through `-dictationPreview starting`, without opening the microphone.
Both captures were inspected. The fixed 280 by 80 pt surface is also its minimum
size; the title stays inside its bounds. Resolved sRGB contrast measured 14.94:1
in light and 12.27:1 in dark. These captures prove appearance, not hotkey-to-pixel
latency. AX target reads and compositor scheduling remain contributors to that
latency. Appearance and the complete development preference domain were restored.

`shutdown()` synchronously flushes capture cleanup during app termination so a
queued discard cannot leave a recording behind when the process exits. Normal
release and cancellation remain asynchronous. The local maintenance gate passed
189 tests with ten explicit opt-in checks skipped and no failures, followed by
the signed bundle build. Version 3.7.5 packages this feedback and capture-queue
change. A further hardware-latency improvement under the current no-background-
microphone and idle-volume constraints remains unproven.

## Raw prepared input, October 20, 2026

The user still reported that the starting state was long enough to confuse,
and that speech beginning with the press lost its first words. They chose raw
input prepared between holds, and muting media during the hold, over keeping
voice processing. Market review: VoiceInk (AUHAL, `AudioUnitInitialize` ahead,
only start on press), TypeWhisper and OpenSuperWhisper (`prepare()` without
start), Handy and OpenWhispr (raw input) do not use voice processing for
ducking; Superwhisper, Handy and TypeWhisper pause, mute or lower media
themselves. Wispr Flow and Aqua recommend a built-in microphone over Bluetooth,
whose HFP switch adds its own delay.

A signed development probe on the built-in MacBook Air microphone ran each
mode in its own process, eight holds per process, two processes per mode.
Press to first nonempty tap buffer:

| Mode | Median | Range |
|---|---|---|
| Voice processing, built per press (3.7.5 path) | 1,238 ms | to 2,151 ms; 1 of 16 delivered no audio within 3 s |
| Raw input, engine built per press | 391 ms | 251-675 ms |
| Raw input, engine prepared beforehand | 160 ms | 128-216 ms |

Mixing voice-processing and raw engines in one process raised
`format.sampleRate == inputHWFormat.sampleRate` at tap installation, so each
mode ran separately. The prepared idle state read process input-running zero.
That is the property the system microphone indicator follows; the indicator was
not inspected visually.

The first worker build measured 314-344 ms median: its stale-device check
compared the default input with `kAudioOutputUnitProperty_CurrentDevice`, which
returned the engine's aggregate device (115, against input 77 and output 70),
so every press rebuilt the engine. An instrumented copy then attributed the
start to about 1 ms of file creation, about 1 ms of muting and 58-105 ms of
`engine.start()`. With the check comparing the default input recorded at build,
the exact production sources (`DictationRecorder`, `DictationCaptureWorker`,
`DictationCaptureRequest`, `DictationAudioFile`, `DictationOutputMute`) in three
fresh processes gave 30 of 30 captures: median 179 ms, p95 231 ms, maximum
280 ms. Every hold read input-running zero while prepared, one during capture
and zero after its stop or discard, and zero after shutdown. The default output
read muted during each hold and unmuted afterwards, with no recovery record
left. Stops wrote the expected 14,400 frames (300 ms at 48 kHz).
After the worker stopped only a running engine, so a discard following a stop
keeps the re-prepared graph, two more processes gave 20 of 20 captures, median
175 ms, maximum 288 ms, with the same input and mute readbacks.
A process that exited during a hold left the speakers muted with the recovery
record set; the next launch unmuted them and removed the record. The complete
development preference domain matched its backup afterwards. These timings
measure first audio, not perceived speech capture. USB inputs were not measured.

### AirPods

With AirPods as default input and output, holds six seconds apart so the
headset could leave its call mode between them, each probe process refused to
run unless the default input was Bluetooth at launch. Every process of the
shipping path was bracketed by AirPods at its own launch and the next one's.

| Path | Holds | Failed | Median | Range |
|---|---|---|---|---|
| Raw prepared input (final worker) | 16 | 0 | 180 ms | 127-304 ms |
| Raw prepared input (before the tap fix below) | 16 | 0 | 142 ms | 122-447 ms |
| Voice processing, built per press (3.7.5 path) | 8 | 0 | 1,716 ms | 911-2,058 ms |

The AirPods output read muted during each hold and unmuted afterwards. Raw
input built per press was not measured on AirPods: its first attempt crashed,
and the AirPods then disconnected from the Mac twice during the session.

That crash was `Failed to create tap due to format mismatch` (2 ch, 44.1 kHz):
the AirPods input changed format (24 kHz at launch) between reading the input
format and installing a tap with it. AVFAudio raises an Objective-C exception
there, which terminates the process. The worker had the same read-then-tap
order, so it now installs the tap with a nil format and reads the format after
installation. A later change trips the stale check or the configuration
observer before a hold, or fails the sink's format check during one, rather
than crashing. The race was observed once and has not been reproduced on demand,
so the fix is not proven against a repeat.
Probe sources and metadata-only JSON results are in the gitignored
`.build/diagnostics/dictation-raw-input/` of the worktree that measured them;
the verdicts above are the record.

