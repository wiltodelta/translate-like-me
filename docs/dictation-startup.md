# Dictation startup investigation

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
