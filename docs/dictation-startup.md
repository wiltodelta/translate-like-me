# Dictation startup investigation

> The voice-processing recorder described through "Verification of the queued
> implementation" was replaced by [raw prepared input](#raw-prepared-input-october-20-2026).
> Listening now follows a first-audio sink node, about 60 ms after the press:
> [dictation latency](dictation-latency.md). The October 23 research records the
> first-buffer recovery limitation before the correction described in
> [the follow-up](#follow-up-implementation-and-headset-check).

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
latency. Compositor scheduling remains a contributor to that latency; AX target
reads left the press on October 20, 2026. Appearance and the complete development
preference domain were restored.

`shutdown()` synchronously flushes capture cleanup during app termination so a
queued discard cannot leave a recording behind when the process exits. Normal
release and cancellation remain asynchronous. The local maintenance gate passed
189 tests with ten explicit opt-in checks skipped and no failures, followed by
the signed bundle build. Version 3.7.5 packages this feedback and capture-queue
change. A further hardware-latency improvement under the current no-background-
microphone and idle-volume constraints remains unproven.

## Post-release ducking verification

A read-only check on October 20 at 13:52 PDT verified that the installed 3.7.5
process started after the update. Its two completed holds each requested maximum
attenuation (0.056234), then unity (1.0), with no voice-processing teardown error.
The unity request specifies a two-second transition; it is not an instantaneous
volume reset. A preceding 30-minute window contained 24 matched maximum-duck and
unity requests from the previous 3.7.4 process, with no unmatched maximum request.
These observations are process-specific and do not measure cancellation or
hardware-error outcomes on 3.7.5.

Re-reading the earlier native probe's complete combined-volume log also found
an independent Core Audio readback: another present audio client moved from
0.056234 to 1.0 after teardown. The silent reference itself was marked not
present in these gain lines, despite its advancing render counter. This is
system gain evidence for that client, not an acoustic or perceptual playback
measurement. The fresh 3.7.5 window had no other present playback client, so
its two unity requests alone cannot prove the resulting music amplitude.

Code inspection confirms stop, cancellation, startup failure and termination
reach full engine teardown; a drain failure reaches it through controller
completion and discard. The application does not write the user's system or
player volume setting. Read-only logs are retained in
`.build/diagnostics/dictation-startup/recent-volume-check.log` and
`current-version-volume.log`. No microphone was opened or volume changed by
this verification, and no additional release was made.

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


## Bluetooth readiness research, October 23, 2026

The Yealink BH74 failure has two independent contributors: Bluetooth route
renegotiation stopped the engine, and the controller then rejected every hold
in its failed phase. System logs showed the prepared 44.1 kHz tap against
16 kHz hardware. Removing microphone mute did not prevent that engine stop.

Apple's [configuration-change contract](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification)
says the engine stops and retains its old node connection formats when hardware
rate or channels change. Connections must be reestablished. Teardown must not
run synchronously inside the notification callback's internal queue. The app's
own capture queue and graph-generation checks preserve that separation.
Apple's [Bluetooth explanation](https://support.apple.com/en-us/102217) confirms
that opening the headset microphone changes its audio mode; preparing a stopped
engine is not evidence that this later transition has completed.

Source inspection, not execution of these applications:

- [TypeWhisper AudioRecordingService](https://github.com/TypeWhisper/typewhisper-mac/blob/cda5bf73b074287e6a4c4c11ed4eb49a74fb4a75/TypeWhisper/Services/AudioRecordingService.swift#L3822)
  stages startup samples by capture generation. Its readiness checker distinguishes
  steady signal, a steady all-zero stream and absent/stalled buffers. An all-zero
  stream can be headset mute or a dead route; its recording path rebuilds once,
  then can accept persistent silence rather than repeatedly restarting a muted
  microphone. Its [recovery coordinator](https://github.com/TypeWhisper/typewhisper-mac/blob/cda5bf73b074287e6a4c4c11ed4eb49a74fb4a75/TypeWhisper/Services/AudioEngineRecoverySupport.swift#L397)
  coalesces configuration events and bounds recovery. Its timing constants are
  that project's policy, not measurements on this Mac.
- [VoiceInk CoreAudioRecorder](https://github.com/Beingpax/VoiceInk/blob/22e5ec5479b712797c3b338fcb875961e58800b6/VoiceInk/Infrastructure/Audio/CoreAudioRecorder.swift#L368)
  uses an input-only AUHAL, explicitly disables output, binds the selected input,
  initializes before a hold and starts on demand. It checks the physical nominal
  rate and unit input format before reusing a prepared unit. Apple's
  [TN2091](https://developer.apple.com/library/archive/technotes/tn2091/_index.html)
  documents this input-only path and native-rate requirement. This architecture
  reduces dependence on an output graph; avoiding Bluetooth renegotiation or
  improving latency on BH74 remains an unmeasured hypothesis.
- [Yealink's BH74 mute instructions](https://support.yealink.com/docs/bh74/mute-headset/97e6cbf3c5f349048f2bb42efe3777f1)
  specify boom-up/button mute and boom-down unmute. Synchronization of that
  physical state with Core Audio's mute property has not been established here.

A synthetic executable compiled with the real `DictationAudioFile.swift`
confirmed that appending a nonempty buffer of exact zeros sets
`isDeliveringAudio` even though its level remains zero. The prepared worker
fix uses that property to forbid startup recovery after first audio. Therefore
an initial silent buffer can close the recovery window before the Bluetooth
route settles. The existing worker tests cover no-buffer startup changes and
changes after nonzero audio, but do not establish correct recovery through an
initial silent stream. Do not treat that fix as complete hardware validation.

Next implementation target: distinguish arrival of PCM buffers, stable input
readiness and signal presence. Preserve startup samples from the accepted
capture generation, coalesce route changes within a bounded startup deadline,
and avoid mistaking hardware mute for an endless restart request. Add a
synthetic zero-buffer-then-format-change regression before changing that policy.
Keep the stopped microphone between holds; a continuously running stream would
change the user-selected capture/privacy behavior and hold Bluetooth in its
microphone mode. Evaluate input-only AUHAL only if live BH74 checks show the
engine path remains unreliable, rather than assuming the lower-level API fixes
Bluetooth. Required hardware checks remain direct Bluetooth cold starts,
repeated holds after idle, physical mute/unmute, release during startup and
reconnection. No new live headset measurements were made for this research.


### Follow-up implementation and headset check

`DictationAudioFile` now exposes buffer arrival separately from nonzero signal.
Its PCM energy calculation detects even signal below the visible meter floor.
The real-time sink can also mark signal before the tap writes. Startup recovery
uses the signal flag, so exact-zero startup buffers do not forbid rebuilding a
changed graph. Nonzero audio still forbids silently discarding a partial phrase.
An uninterrupted silent stream neither triggers a rebuild nor fails capture.
The zero-buffer/format-change regression failed before this change and passes
after it; separate cases cover a steady muted stream and very quiet signal.

After Yealink was reconnected, signed probes of the baseline source and the
candidate worker each captured three of three holds with nonzero PCM at 16 kHz.
Each hold began with the headset output at 44.1 kHz, and the default input UID
still matched at completion. Playback consisted only of digital silence; media
commands and output-mute writes were disabled. Temporary recordings were
removed after reading aggregate counts. These are capture checks, not speech
recognition or paste-delivery checks, and the baseline also passed: the original
intermittent engine-stop failure was not reproduced in this series. The synthetic
regression establishes the corrected silence boundary; these headset checks do
not establish a measured reliability improvement or exercise physical mute and
reconnection during a hold. The installed application was not replaced by them.


### Installed-app verification remains incomplete

After the approved local replacement, the installed process prepared its model
and registered the hold shortcut. The user's own holds then reproduced a
configuration interruption after signal had arrived and a first-audio timeout
following a slow startup rebuild. Other holds completed Qwen recognition and
clipboard delivery. Thus the source-level probe's successful captures did not
establish reliable installed-app behavior; the probe excluded output mute and
media commands. Output mute remains a contributor to isolate before attributing
the remaining route failures; the media commands have since been removed.

The user also reports that recognized words are consistently close to, but
different from, what was spoken. Logs contain neither the original speech nor
the recognized text. A spoken-versus-recognized example is required to separate
missing startup speech, input quality/format problems, language selection and
ASR model errors. Do not attribute that report solely to the known startup
latency or treat successful paste delivery as recognition accuracy. No personal
audio or transcript has been added to the repository for this investigation.


### Synthetic accuracy check after the installed-app report

The user supplied a spoken-versus-recognized example with phonetic substitutions
across the phrase. A temporary, environment-guarded XCTest synthesized that
supplied phrase with macOS Milena, converted it to mono Float32 WAV at 16 and
48 kHz, wrote it through the production `DictationAudioFile`, and called
`DictationEngine.transcribe` with Qwen and downloading disabled. It used an APFS
clone of the installed model cache and the installed bundle's Metal library.
No microphone, speakers or personal recording was used. Each rate was tested
three times with no language preference and three times with ru/en preference.
All twelve outputs had the supplied word sequence after case, punctuation and
е/ё normalization. This was a debug-host accuracy check, not a release-build
latency measurement or proof of the installed microphone path.

The temporary XCTest verdict itself was red: its initial term checker removed
Russian diacritics from output but not terms, and its uncalibrated 10 ms duration
tolerance also rejected a 17.6 ms shortening on the 48 kHz conversion. Independent
Unicode word-sequence comparison of all saved synthetic outputs matched twelve
of twelve. The 16 kHz native-rate case also recognized correctly; the small
48 kHz duration difference does not establish the cause of the headset report.
The probe and all synthetic audio/model clones were removed after inspection.

Remaining evidence needed: one consented real capture from the application
path, a local listening check for pitch/speed/distortion, and comparison of
Qwen and Whisper on that identical clip. Do not declare the headset or the
model faulty from the synthetic result alone, and do not add personal voice
samples or full transcripts to this repository.


### Consented headset speech comparison

The user approved one eight-second local voice capture, local playback and
comparison, followed by removal. A signed, nonactivating development helper
used the production capture worker, WAV writer, output mute and media path.
It recorded 128,000 mono frames at the native 16 kHz rate with no interruption;
the default input UID matched before and after capture. Aggregate peak was
0.138, RMS 0.0159, exact-zero samples 5.42%, and clipped samples zero. These
figures establish sample shape and amplitude, not intelligibility or freedom
from acoustic/Bluetooth distortion. This successful warm capture does not
resolve the intermittent installed-app startup failures above.

The same WAV went through the production loader and transcription engine with
the configured language preferences, using an APFS clone of the model cache.
Qwen and Whisper Turbo each ran three times. Each model produced one identical
output across its three runs. Against the supplied twelve-word reference,
case/punctuation and е/ё normalized, Qwen had three word edits in every run;
Turbo had six. No run preserved the complete supplied word sequence. These
repetitions establish within-clip consistency, not an accuracy rate across
speakers or recordings. Unlike the synthetic check, both models made phonetic
substitutions on real headset speech. Changing to Turbo alone is not supported
as a remedy. The evidence still cannot distinguish the acoustic input from
recognizer sensitivity to this voice or separate missing initial speech.

The clip was played once locally through an explicitly selected Yealink output.
Perceptual feedback on pitch, speed, muffling and distortion remains necessary;
the agent did not listen to it. The temporary voice sample, full reference and
recognized transcripts, model clone, helper and opt-in test were removed after
comparison. No personal audio or full transcript is retained in the repository.


### Manual playback failure

A second consented Yealink recording produced 129,600 mono frames at 16 kHz.
The user reported that manual playback did not start. The helper had accepted
`AVAudioPlayer.play()` returning true, while its Core Audio log repeatedly
reported `HALC_ProxyIOContext::_StartIO`, `StartAndWaitForState` error 35 on the
Yealink output. Output-mute restoration had completed before playback. The
playback request was therefore not proof that the user could hear the sample.
When inspected, the helper was no longer running and its termination cleanup
had removed the voice file; no crash report for the helper was found.

A fresh standalone process advanced playback on six of six one-second digital-
silence checks, three with the explicit Yealink UID and three on the default
Yealink route. This separates a currently usable output from the failed
post-capture playback context, but does not establish the cause of error 35.
The revised helper plays in a fresh child process, checks progress and the
completion callback, rejects a stalled start, and reports failure instead of
claiming successful playback from the start return alone. Its packaged signed
child completed three of three silent checks and rejected a missing file.
Personal speech playback and intelligibility remain unverified. No additional
microphone capture was made during this playback repair.


### User listening feedback and remaining transport comparison

On the next approved sample, the helper captured 129,600 mono frames at 16 kHz,
and the separate playback child returned successful completion. The user
selected the combined muffled/distorted/interrupted-voice response. This is
perceptual evidence of poor sound during replay, not a measured distinction
between capture and playback distortion. In the capture-through-stop interval,
filtered diagnostic process logs contained no matching error, overload,
underrun, discontinuity or format-mismatch messages. Absence from that log
filter does not establish continuous or undistorted PCM. At inspection the
helper had exited and removed its voice sample, so waveform analysis was no
longer possible. Do not imply it was performed.

Read-only Audio system information confirmed direct Bluetooth transport for
BH74, native mono input at 16 kHz and stereo default output at 44.1 kHz after
capture. These rates alone are not a format bug. Apple's Bluetooth guidance
above describes lower output quality during microphone mode; it does not
prove this headset's recorded phonetic substitutions are expected. The
[official BH74 connectivity specification](https://support.yealink.com/docs/bh74/yealink-bh74-datasheet/42a5293c6b4741f2b7cb1703b6d4e998)
lists USB cable, BT51C adapter and direct Bluetooth. A same-headset USB-cable
comparison in ordinary dictation is the next proposed transport control, with
a built-in Mac microphone as the alternative control. Neither has been
performed. The temporary signed helper, public synthetic silence and its
source copies were removed; no diagnostic voice sample remains.


### AirPods ordinary-dictation control

After the user connected AirPods instead of Yealink, read-only Audio system
information showed AirPods as default input and output over Bluetooth. No
explicit dictation microphone override was stored; the running installed app
follows the system input. Qwen remained selected. The user's requested short
phrase failed with the recognition-limit message. Installed-process logs show
capture at 12:18:32-12:18:40 on October 23, first audio after 33 ms, 121,515
loaded samples (about 7.6 seconds at the loader's 16 kHz), successful drain,
then a DictationError during Qwen decoding. This is not the recording-duration
limit. The current error/log combines the 1,024-token cap and repetitive-token
backstop, so it does not prove which one fired. No transcript or voice sample
was inspected or retained for this ordinary hold.

A temporary synthetic-only XCTest generated the requested phrase with Milena
at native 16 kHz, then called the production DictationEngine six times in one
runtime with ru/en preferences and an APFS clone of the installed cache.
Every output matched the supplied word sequence after case/punctuation and
е/ё normalization; no run reached the decoding guard. This reproduces neither
the AirPods failure nor the real-speech sound quality. It establishes a
passing synthetic control, not that the hardware or model is fault-free.
The test, synthetic WAV and model clone were removed after inspection.
The next proposed control is ordinary dictation with the built-in Mac
microphone and unchanged Qwen model. Bluetooth capture, recognizer sensitivity
to real speech and state of the long-running installed runtime remain open
contributors; a new microphone alone has not resolved the report.


### Built-in microphone ordinary-dictation control

The user selected MacBook Air Microphone and repeated the control phrase with
Qwen unchanged. Readback confirmed the explicit BuiltInMicrophoneDevice UID;
the installed process logged binding to the selected input. The hold at
12:21:31-12:21:38 on October 23 loaded 107,179 samples (about 6.7 seconds at
16 kHz), drained successfully, and completed recognition without error. The
user's returned text had two lexical substitutions against the supplied
reference, treating the output hyphen as a word separator. No audio sample was
saved for analysis. This establishes that phonetic substitutions also occur
with a built-in input; it does not identify recognizer error versus a shared
capture/preprocessing problem. The installed-runtime Qwen state remains an
additional untested contributor. Proposed next control: Whisper Turbo on the
same explicitly selected built-in microphone. The earlier same-clip model
comparison used Yealink audio, so it cannot settle this built-in control.


### Approved installed-app switch to Whisper

The user approved selecting Whisper large-v3-turbo and downloading its assets
for the built-in-microphone control. The model was selected through the running
installed app's Settings picker. The initial preparation reported NSURLError;
subsequent preparation reached `Dictation model ready` at 12:26:46 on October
23. UI readback showed Ready. Defaults readback confirmed `dictationModel` is
`turbo` and the explicit BuiltInMicrophoneDevice UID remains selected. These
assets intentionally remain in the installed cache for the approved test;
Qwen assets were not removed. Ordinary user dictation on this model/microphone
combination remains to be checked; readiness alone is not accuracy evidence.


### Pipeline-wide follow-up

Whisper on the verified built-in input also substituted several words in the
user's returned control text. The installed process logged a successful drain
and Whisper decode for that hold; it was not a Qwen run. The user then asked
for a device-aware audit of the entire pipeline and reported that built-in Mac
microphones work better than all tested headsets. The source audit, primary
references, synthetic signal/recognition matrices and candidate diagnostic
changes are recorded in [the audio pipeline investigation](dictation-audio-pipeline.md).

Before proposing candidate installation, live state was read again: the
installed app had restarted, still used the previously approved 3.7.11 binary,
and was now configured for Qwen and system input. The current system input was
the built-in Mac microphone at 48 kHz. No cause is attributed to the restart
or setting changes. Earlier model-specific results are tied to their observed
process/logs; do not infer current settings from the earlier switch approval
or silently restore an old preference snapshot during replacement.


### Autonomous research and conversion fix, October 23

The user requested completion of the dictation-product research and testing
without further dictated control phrases. The follow-up compares documented
behavior in Wispr Flow, Superwhisper, Aqua Voice, VoiceInk and TypeWhisper, then
keeps explicit microphone selection and raw native capture rather than adding
unmeasured voice processing or an LLM cleanup step. The decision, primary
sources and measured limits are in [the autonomous pipeline follow-up](dictation-audio-pipeline.md).

An owned finite-file loader now selects one stable channel by non-DC energy
instead of summing arbitrary channels, drains the converter and validates the
native duration. A first mastering-filter candidate was rejected when Whisper
worsened an English control. The revised candidate preserves the common-rate
filter and completed a separate 240-result factorial comparison with no worsened
cases; all 54 candidate speech results matched their synthetic references and
all six silence results were empty. These are two generated voices, not a
natural-speech accuracy estimate. Metadata-only native graph checks passed six
starts on the available built-in microphone; no headset was exposed for physical
coverage. No additional user voice was saved or replayed.

At the final installed-state readback, PID 24925 still ran the approved diagnostic
3.7.11 executable with SHA-256
`30da64fa6d28a113a2083ee4f04c3d82b59e53f0427882cf781c9b6f84e75e67`, using Qwen.
The loader change is a separate local candidate, not an installed or published
fix. Installation approval for the preceding diagnostic bundle does not cover
this new behavior. The original headset distortion and built-in lexical
substitutions are not declared resolved by the synthetic comparison.


### Approved installation of the owned loader, October 23, 16:40 PDT

The user explicitly approved replacing the installed app with the tested local
3.7.11 candidate and restarting it while preserving settings and models. The
previous process exited through normal Quit. A staged copy passed deep/strict
signature verification before replacement; the installed executable now has
SHA-256 `4de6f86ab3edd4d34e8282bd7d12e49d83b8c286f4c8c53fe87748d8123fc3a7`.
The new process, PID 23511, registered its shortcuts, prepared the system input
as built-in 48 kHz mono and logged `Dictation model ready`. Qwen remains selected.
The full defaults dictionary is unchanged across quit/restart; all 148 dictation
model files retain their sizes and modification times. The temporary stage and
rollback bundle were removed after verification. No new speech-quality result
is inferred from successful installation and readiness.

Installation receipt and startup evidence:
`~/.local/state/agent-artifacts/translate-like-me/install-audio-loader-20261023T233802Z/`.
This approved installation supersedes the earlier candidate-only status; no
commit, release tag or publication was performed.


### Device compatibility implementation, October 23

The user prioritized correct handling of different microphones and requested
research plus implementation without more dictated phrases. A same-format
route change, numeric ID reuse, missing-input return and notification/drain
race were reproduced with failing tests before fixes. The worker now observes
Core Audio topology and selected-device properties, validates input snapshots,
pins explicit selections even when they equal the default and rechecks route
and running state before accepting the final file. Startup recovery still has
two retries before nonzero audio; interrupted speech is never joined across
routes. Full contract, source references and measured limits:
[microphone compatibility](dictation-device-compatibility.md).

A signed disposable helper prepared six real built-in graphs without starting
capture or retaining PCM. Three explicit bindings to the current default all
succeeded. A separate metadata-only check passed five listener lifecycle cycles.
These checks do not newly verify AirPods/BH74/USB recording or physical mute.
The installed 16:40 loader build was left running while this new candidate was
prepared; installation and publication are separate operations.


### Approved compatibility-build installation, October 23, 19:45 PDT

The user explicitly approved replacing the installed app with the tested device
compatibility build, preserving settings and models. The previous process quit
normally; the staged and installed bundles passed deep/strict signature checks.
PID 39843 runs executable SHA-256
`586ce13571b61fd652c3b04bbe71b8cfd14659fceca9471d98c8578dba9ecede`, local version
3.7.11. Startup registered shortcuts, prepared the built-in system input at
48 kHz mono and reported the selected Qwen model ready. The full preferences
dictionary and metadata for all 171 dictation/translation model files were
unchanged across replacement. The temporary stage and rollback bundle were
removed after verification. This supersedes the earlier candidate-only status;
readiness adds no new Bluetooth/USB speech-quality evidence.

Installation receipt:
`~/.local/state/agent-artifacts/translate-like-me/install-device-compatibility-20261024T024430Z/`.
