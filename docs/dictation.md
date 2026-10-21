# Local dictation

Unattended verification, its command and its physical limits:
[unattended dictation testing](unattended-dictation-testing.md).

The initial implementation follows the [minimal product scope](dictation-feature-plan.md).
Enable it in Dictation settings, allow microphone access, and wait for the one-time
model preparation. Hold right Option while speaking, then release to recognize
and insert. This is the only recording mode. The menu opens
settings or cancels an active session; it never starts a separate recording.
To choose the other Option, click Hold key and press and release left Option.
The two sides are separate bindings; the binding can also be cleared. Earlier
ordinary-combination preferences are read as right Option. Other input during a
hold cancels that recording, including Option combinations. The system input
device is used each time recording starts.

## Runtime and data

WhisperKit 1.1.1 runs the Whisper models; MLX Audio Swift 0.1.6 runs Qwen. `DictationModel`
offers Whisper Small (`openai_whisper-small`), Whisper Large v3 Turbo
(`openai_whisper-large-v3-v20240930_626MB`, the unchanged default) and Whisper
Large v3 (`openai_whisper-large-v3_947MB`), plus Qwen3-ASR 1.7B 8-bit for 30 languages.
The three Whisper snapshots
contain about 487, 627 and 948 MB respectively, excluding tokenizer and shared
speech-detector assets. Qwen downloads about 2.5 GB, including its tokenizer inputs.
The default Turbo has four decoder layers and 32 encoder layers. Recognition uses automatic language
detection, without a Russian/English allowlist, and transcription rather than
translation. This is an initial integrated configuration, not a claim of model
superiority or production quality across every supported language.

`DictationEngine.swift` pins the shared model repository revision;
`DictationModel.swift` pins each Whisper tokenizer revision and file hashes.
`DictationQwen.swift` pins the MLX export and verifies the required weights and
input tokenizer files. Qwen runs natively on the GPU; its derived tokenizer is
kept outside the verified snapshot. See [Qwen integration](qwen-integration.md)
for lifecycle, cancellation and verification details.
WhisperKit's downloader maintains partial transfers. `ModelSnapshot` checks
all required Core ML components and validates every existing snapshot file
against metadata for the pinned revision: SHA-256 for LFS weights and Git blob
SHA-1 for ordinary files. The SDK itself accepts partial snapshots and skips
content checks on some cache paths. Before resuming a download, the app removes
corrupt files while retaining valid partial transfers. It validates completeness
and hashes again after downloading. Tokenizer files have explicit pinned SHA-256 checks,
working around the SDK's directory-only cache precheck for literal file patterns.
Setup is the download boundary; a normal reload uses `download: false`. The tokenizer is prepared
explicitly so it does not become a hidden first-use network dependency.

Preparation also downloads one small, pinned Silero v6.2.1 Core ML speech detector
from [FluidInference's conversion](https://huggingface.co/FluidInference/silero-vad-coreml/tree/b419383c55c110e2c9271fa6ee0ea83d03c70d96).
It checks whether a clip contains speech before the recognizer sees it. The original
clip stays intact, with no trimming at voice boundaries. The detector runs on
CPU and its state resets for every recording. Failures propagate as errors,
rather than silently becoming an empty result.

An empty transcript currently completes without a result popup or error. Empty
or silent samples and speech-detector rejection both return before model
decoding. A quick empty result can hide the indicator before a Recognizing frame
is visible. Notice-level diagnostics distinguish these paths from hold
cancellation, without logging audio or text. The new-Mac report and isolated
controller checks are tracked in [fresh-install verification](fresh-install-testing.md).

The user identified Punto Switcher as the source of the new-Mac failure and
confirmed that fully quitting it restored dictation. This is a reported
keyboard-utility compatibility conflict with a working shutdown workaround;
the exact event sequence has not been captured. The hold monitor's cancellation
on other input is a plausible explanation, not yet a measured diagnosis. The repeated-Option-event
fix is not established as a Punto compatibility fix. Track the affected setting
and controlled checks in the fresh-install verification document.

This gate addresses observed text hallucinations on synthetic noise. WhisperKit
1.1.1's [decoder](https://github.com/argmaxinc/argmax-oss-swift/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/Sources/WhisperKit/Core/TextDecoder.swift#L821)
hardcodes `noSpeechProb` to zero, so its advertised no-speech threshold cannot
reject these clips. Do not treat that field as a measured probability. Keep
timestamp decoding enabled: disabling timestamps lost part of a sentence at a
30-second window boundary in the long synthetic clip. Short clips retain the
quiet tail, and punctuation-only results are discarded.

Before delivery, `DictationEngine.transcript(from:)` removes trailing
`[BLANK_AUDIO]` annotations, including repeated annotations across result chunks.
Whisper can emit this annotation as ordinary text, which `skipSpecialTokens`
does not filter. Other bracketed text and annotations inside a sentence stay
intact. `DictationTranscriptTests` reproduces the reported trailing annotation
with SDK result objects, including a long Russian sentence, repeated markers,
marker-only output and mixed-language text. The regressions failed before the
filter was added. This verifies output cleanup, not why a particular recording
caused the model to emit the annotation.

Before preparation, the app checks the cache volume for at least 8 GB free.
This is a conservative preparation budget, not a measured universal Core ML
requirement. Earlier compilation on an almost-full disk terminated the process
inside LLVM/MPS. The check prevents preparation in that observed low-space
condition; it cannot reserve space against other processes filling the disk.

Models live under `~/Library/Application Support/<bundle id>/Dictation`.
Development builds use their own `.dev` id. Small, Turbo and Large v3 permit
CPU/Neural Engine for both the audio encoder and text decoder.
Whisper mel stays CPU/GPU. Silero stays CPU-only.
A loaded model stays ready; memory-pressure notifications or disabling dictation
release it after active work completes. Press enqueues microphone initialization;
after release, drained audio stays available while a model reload finishes.
Interrupted first preparation restarts after the cancelled task unwinds. The
controller stays preparing until assets are ready; termination suppresses that retry.
Timed two-minute eviction was removed
because diagnostic runs showed a material reload cost. No memory-policy control is exposed.

Compute-policy, decoder and loading experiments, their limits and the synthetic
benchmark recipe are in [model efficiency](dictation-model-efficiency.md).
The [Parakeet Ultra experiment](parakeet-ultra-experiment.md) records the initial
comparison. The historical [Parakeet integration](parakeet-ultra-integration.md) records its
installation, lifecycle, native UI and build checks.

`DictationRecorder` queues capture immediately and publishes metering through a
locked request. `DictationCaptureWorker` owns every engine operation on a serial
user-initiated queue, including configuration callbacks and teardown. The starting
indicator is requested before microphone setup; the press reads no AX target. Release
closes the request's hardware-start gate immediately; the stop task then drains and
finalizes the WAV before recognition. Cancellation queues discard before a later
start. This keeps hardware initialization off the UI and prevents a queued startup
from opening the microphone after an early release. See the
[startup investigation](dictation-startup.md) for the remaining hardware latency.

The worker captures raw `AVAudioEngine` input, without Apple's voice processing.
VoiceProcessingIO initialization took about 1.2 s per press, so speech that began
with the press was lost, and a prepared voice-processing unit kept other audio
ducked while idle. The user chose raw prepared input on October 20, 2026; the
measurements are in the [startup investigation](dictation-startup.md#raw-prepared-input-october-20-2026).
Echo cancellation and noise suppression are therefore gone. Their earlier
benefit was not established (see the comparison below).
Between holds the engine is prepared but stopped, with its tap installed. It
opens no microphone: the process input-running property reads zero. A press
only starts the hardware. The tap forwards audio through a relay only while a
hold's sink is attached. Stop and discard re-prepare the engine; disabling
dictation releases it. Wake, an idle configuration change, or a different
default input or format rebuilds it. The engine's I/O unit reports its own
aggregate device, so the worker compares the default input it recorded at build.
The tap is installed with a nil format, because a stale explicit format raised
an uncatchable exception when AirPods changed format.

During a hold the default output device is muted, if it was unmuted, so media
does not reach the recording. `DictationOutputMute` records the device UID in
preferences while it holds the mute. Release, cancellation and failure unmute
only a device that is still muted, leaving a device the user unmuted meanwhile.
Restoration resolves that UID again, so a reassigned numeric device id cannot
unmute another output. A disconnected device or failed restoration keeps its
recovery record; launch, idle preparation and the next hold retry it. A pending
record blocks a new mute until the original output is restored. The system
volume level is never changed.

The recorder writes only its current temporary PCM WAV at the processed input's
native rate and channel count. WhisperKit's audio loader converts it to 16 kHz
mono before speech detection and recognition. `DictationAudioFile` serializes
non-real-time tap writes, metering and file close with a lock. It finalizes the
WAV header before recognition, rejects late callbacks and bounds recording to
five minutes by counting captured frames. The file is removed after recognition
or cancellation. Device/format changes that stop or invalidate the
engine fail the active recording rather than recognize a partial file. Choose
Try Again in Dictation settings after correcting the devices; a new recording
creates an engine for the current system devices.
Only the latest text result remains in memory, accessible through Copy Last
Dictation. No transcript/audio archive, telemetry, account, or cloud inference
is added. Passing the resulting text to existing translation or Rewrite actions
uses those actions' configured remote provider.

## Delivery and cancellation

Translation/Rewrite shortcuts use Carbon registrations.
Bare Option uses local/global NSEvent monitors and the same pure `OptionKeyGesture`
state machine as the shortcut recorder. It needs the app's existing Accessibility
permission for global keyboard monitoring. Monitor generations reject queued
events after re-registration; Carbon actions explicitly cancel an armed Option
press because Carbon can consume the intervening key before NSEvent sees it.
Repeated flags for the same held Option are ignored. They do not cancel capture
or rearm a hold blocked by another key or input event.
The held-key monitor stays installed through capture. Resetting it on press
would lose the release event. There is no dedicated dictation cancellation key:
reaching for Escape while holding Option is awkward, and the interval after
release can be too short to use reliably. Undo after insertion belongs to the
destination editor. Pointer cancellation and lifecycle invalidation still guard
pending work. Release drains capture even before its first meter update, or
cancels hardware startup if it has not begun. Model preparation happens after
release and cannot delay capture or start a microphone after the key is up.
The starting indicator is requested first, then recorder startup is queued; the
press reads no Accessibility target, so a slow editor cannot postpone hardware
setup. This ordering is covered by a controller regression test; it does not
establish a hardware latency figure. The measured/unmeasured boundary and candidate
preparation strategies are recorded in
[startup latency](dictation-startup-latency.md).
Dictation and text transformations share the busy guard.
A session id rejects late asynchronous results; phase validation also rejects
late recording-meter updates after recognition has begun.

Text goes wherever keyboard focus is when recognition finishes, in any app,
field or custom renderer (user decision, October 20, 2026). Typing, clicking or
switching apps during recognition does not retain the result. The destination is
AX's focused process, else the frontmost app. Only a focused AX-secure text field
or the absence of any focused process retains the result without touching the
clipboard.

Delivery snapshots the clipboard just before writing and promises the transcript
as the pasteboard's string, marked transient, then posts Paste to the destination
process. A paste must read the clipboard, so the first request for the promised
string is the delivery proof, even in renderers that expose no AX text. The
original clipboard is restored 300 ms after that read and never before 700 ms; a
newer user copy is never replaced. Without a read within 3 s the result shows with
Copy, and no second paste is posted. The Paste key code follows the user's
ASCII-capable keyboard layout (`KeyboardLayout`, shared with translation's Copy
and Paste), so Dvorak still sends Cmd+V. The most recent result
remains available through Copy Last Dictation. Since October 20, 2026,
translation and Rewrite deliver through the same `PasteDelivery`, without AX
field evidence; they still require a real text selection to copy and the
original process to keep focus with no typing, clicks or app switches. A
temporary native check drove the production `SelectionWorkflow`,
`LiveSelectionAccess` and `KeyboardLayout` against a disposable AppKit text view,
three runs per case: an editable selection was copied, replaced and the marker
clipboard restored in 3 of 3 (0.8-1.0 s); a read-only selection never read the
paste, returned the result after the 3 s deadline with one Paste posted, and
restored the clipboard in 3 of 3. The activity monitor ignored the app's own
events in all six. Chrome was not verified: its key window was not the test
tab, so Copy reached another window and the runs read as no selection.

## Verification

`DictationTests` exercises session cancellation, stale meter callbacks, delivery
to the focus at delivery time, a read receipt from a fast and a slow destination,
an unread paste retained at the deadline, no destination, a new copy during
snapshot, a new copy after paste, cancellation after paste dispatch, and the
promised string through a real private pasteboard.
`KeyboardLayoutTests` pins the Copy and Paste keys in US, Dvorak and
Dvorak-QWERTY Command layouts.

`DictationControllerTests` drives the real controller with controlled model,
recording and presentation effects. It covers immediate capture after model
eviction, audio retention through reload, cancellation during reload, interrupted
first preparation and termination without restarting preparation. Continuations
control progress; these tests never request the microphone or drive native windows.
`ModelSnapshotTests` covers Git/LFS hashes, streaming across chunk boundaries,
partial-cache repair, pinned revisions and verification after downloading.
`DictationSetupTests` also feeds a corrupted complete fixture through the real SDK,
proving that its accepted snapshot is rejected by the app.

`DictationAudioFileTests` writes synthetic PCM through the actual capture sink,
finalizes and loads it through WhisperKit, and checks native-rate conversion,
metering, the frame limit, rejected late writes and format-change errors without
opening a microphone. Controller tests also cover microphone startup failure
and interrupted capture without recognizing partial audio. These checks do not
measure acoustic suppression or prove hardware route behavior.

The voice-processing records from here through the maximum-ducking release
validation describe the recorder removed on October 20, 2026; they are kept as
history and as the evidence behind that decision.

Native verification on October 19, 2026 used the signed development bundle,
built-in MacBook Air input/output and synthetic speech from a separate `afplay`
process, at the existing system output volume of 19. After explicit
VoiceProcessingIO teardown, twelve consecutive engine captures completed. Early
RMS/bypass comparisons were inconclusive: processing changes gain/frequency
response, and weak playback correlations can be dominated by unrelated noise.
Neither an enabled API flag nor overall PCM energy proves useful suppression.

The final comparison used the original `AVAudioRecorder` implementation from
HEAD as its control, not bypassed VoiceProcessingIO. Six pairs alternated old
and new capture, with minimum ducking and AGC disabled for the new recorder.
Each clip went through the real `DictationEngine` with cached Turbo three times.
The digital reference retained all six target words in all three runs. Target
words appeared in four of six original clips and two of six processed clips,
counting a clip when any repeat matched. Across eighteen inferences per arm,
the six-word reference check counted 41 matches before and 8 after. Four pairs
improved and two tied; the one-sided sign test over non-ties is p = 0.0625, so
these small-sample results do not establish a reliable general improvement.
Suppression is partial: individual playback words still pass. Other nonempty
outputs were not classified or logged, so absence of target words does not mean
an empty or correct transcript. Near-end speech during playback, louder media,
other models and external devices remain unverified.

A separate minimum-versus-maximum ducking experiment did not establish a
consistent improvement. The user approved strong media ducking during the hold,
so maximum fixed ducking is now the default. The comparison above describes the
earlier minimum-ducking build.
The maximum-ducking build then completed six native capture/teardown checks:
all six read back maximum fixed ducking during capture, and both I/O nodes had
voice processing disabled after three stops and three discards. This verifies
the processing lifecycle, not the acoustic amount of attenuation or recovery.
Audio, temporary launch probes and the opt-in measurement test were removed
after analysis. Only aggregate outcomes are retained here. The silent output
graph also has an offline render test, including execution away from the main
actor. Isolated mutations of the frame limit, swallowed format errors and
output format were rejected by the corresponding checks.

### Maximum-ducking release validation, October 19, 2026

The user selected sound verification followed by preparation of the full
candidate. A new run used the exact current recorder and WAV-sink sources in a
separate signed development probe, without initializing the app's hotkeys,
settings or delivery. The control was the released `AVAudioRecorder` source
from v3.6.0. Built-in MacBook Air microphone and speakers remained selected,
with system output 19 and input 27 unchanged. A separate process played
synthetic speech. Six alternating control/processed pairs each went through
the real cached Turbo engine three times. The digital reference retained all
six expected terms in all three runs, but every untreated acoustic control
returned empty text (18/18 inferences). Processed clips returned nonempty text
in 8/18 inferences, with no reference terms in any inference. Those other
outputs were neither classified nor logged. The absent positive acoustic
control prevents an effectiveness conclusion; zero target terms does not mean
successful suppression or correct dictation.

Six additional cycles, three stops and three discards, used an acoustic tone
before and after processing. Only one of six pairs met the predefined
signal-to-noise guard on both sides. These controls cannot establish reliable
audible restoration. Across all twelve processing lifecycles, readback did
confirm both I/O nodes processed during capture, maximum fixed ducking, AGC
disabled, and both nodes unprocessed with the engine stopped after teardown.
This is lifecycle evidence, not acoustic acceptance.

A continuous reference player with advancing-playhead checks was prepared to
verify playback overlap before repeating acoustic measurements. It did not
launch: another session retained the shared desktop notice throughout the
five-minute coordination wait. That session was left untouched. Early probe
failures came from attempting to JSON-encode Apple's `ObjCBool` ducking field;
converting it with `boolValue` fixed the measurement helper. They are not
evidence of a production recorder startup failure.

A usable acoustic playback control, independent near-end speech during
playback, and audible restoration after release and cancellation remain open
checks. The user subsequently authorized the full release with these
limits disclosed. Speech from the same speakers cannot substitute for the
user's voice in that test. Temporary microphone recordings and generated
audio are deleted after analysis; only source recipes and metadata are
retained under `.build/diagnostics/full-audio-validation/`. The local candidate
and remaining publication steps are tracked in
[release 3.7.2](release-3.7.2.md).

`DictationIntegrationTests` is opt-in through `TLM_DICTATION_SAMPLES`, pointing to
a directory with synthetic audio and `cases.json`. Normal tests skip it and never
request microphone access or download weights. The live test prepares the pinned
model, recognizes the supplied clips, unloads it, then reloads with downloading
disabled. Synthetic speech verifies integration; it does not establish natural
speech accuracy or replace an M5 model comparison.

`OptionKeyGestureTests` covers left/right identity, press/release actions,
intervening activity, every neighboring modifier, both Options together, a
pre-held key, repeated flags and shortcut representation. `DictationTests` also covers release
during startup and after capture begins. Hardware-generated global monitor delivery and the
shortcut recorder still need native checks. Six isolated mutations of press,
release, cancellation, initial flags, startup release and captured-audio release
all failed their assertions after the nine-test isolated baseline passed.

The repeated-flags regression failed with four assertions before the fix on
October 19, 2026, then all nine Option tests passed. Previously, a second
same-key Option-down event cancelled capture and the eventual release was
ignored. A disposable minimal package using the production gesture, shortcut
helper, extracted `KeyCombo` declaration and all nine gesture tests also passed;
substituting the gesture source from v3.6.0 made the repeat regression fail with
the same four assertions. A temporary fixture in the signed dev bundle then posted `NSEvent`
flags-change events to its own application queue. The production local monitor
and controller used injected recording/recognition effects. For each Option,
press/repeat/repeat/release produced one stop and one recognition call; inserting
the opposite Option produced cancellation with neither call. All four cases
passed. This verifies the local event route, not physical global event delivery
or the cause on the new Mac. Temporary instrumentation was removed afterwards.

Native capture uses the signed dev bundle, synthetic language pairs, and
`-didCompleteFirstRun YES`. The Dictation pane uses `-dictationEnabled YES` with
`-dictationPreview settings`: the real enabled view renders, but the controller
stays unprepared, never loads a model and cannot record. Other panes and indicator
previews use `-dictationEnabled NO`. `CAPTURE_APPEARANCE=light` runs the light
recipe first so its captures can be inspected before the dark pass. `-dictationPreview recording`
or `-dictationPreview recognizing` renders deterministic indicator states without
opening a microphone. Follow the desktop notice and preflight procedure in the
shared macOS capture rules. Actual microphone permissions, device transitions,
and insertion into each target app need live verification; record results here
before claiming those checks passed.

### Release preparation, October 18, 2026

This section records that day's checks. Later review fixes and native rendering
results below supersede its pending-work and temporary-artifact status.

Candidate version: 3.5.0. The [release notes](release-notes-3.5.0.md) are prepared;
no commit, push, tag, notarization submission or release publication has been made.
The version will come from the approved release tag, not an Info.plist edit.

- The canonical `bash maintain.sh` passed with exit 0: SwiftLint, 117 passed
  tests, one explicitly skipped opt-in ASR test, and the release-config signed
  development bundle. Deep/strict signature verification passed. The arm64
  bundle uses the team Developer ID, hardened runtime, macOS 15 minimum and SDK
  27 stamp, and includes the microphone purpose, audio-input entitlement and
  speech model license notices.
- The current speech pipeline passed 33 recognitions, three repetitions of each
  of 11 synthetic cases: Russian, English, Spanish, French, mixed Russian/English,
  a short English word, digital silence, 82.8 seconds of English, synthetic noise,
  and quiet Russian and English attenuated by 26 dB. Ten cases matched the
  expected text exactly in every repetition. The mixed example rendered
  “pull request” in Cyrillic while retaining GitHub; embedded English spelling
  is not guaranteed. This small integration corpus is not a natural-speech
  accuracy benchmark.
- A separate 165.6-second clip, made by repeating the known passage twice,
  matched all 460 expected words exactly in each of three repetitions. Control
  terms were required twice, so an omitted half would fail. This exercises
  multi-minute decoding, rather than natural conversational accuracy.
- Eleven direct checks of the real Silero model distinguished the nine speech
  examples from silence and noise. Both model caches reloaded successfully
  with downloading disabled. This verifies the cache-only code path, not a
  network-disconnected system test.
- The initial timestamp-free decoder lost a phrase at a 30-second boundary.
  Timestamp decoding recovered the entire 82.8-second example in three repeats.
  SDK decoding without random temperature fallbacks also passed this corpus,
  but the retained pipeline uses Silero with ordinary SDK fallback settings,
  rather than treating deterministic noise outputs as speech detection.
- Three final isolated mutations failed their assertions after a four-test
  baseline passed: removing the storage floor, accepting a partial model cache,
  and admitting a non-speech clip. The cache mutation failed both ASR and VAD
  fixtures. Earlier isolated mutations covered session identity, clipboard
  ownership, Option transitions and startup/release handling. Only copies were
  mutated; every disposable package and its processes were cleaned up.
- Four simplify reviews covered reuse, simplicity, efficiency and altitude.
  Fixes removed repeated tokenizer hashing and report writes, shared the real
  ASR/VAD installation mechanism and SDK cache fixture, and scoped the test's
  extra detector outside the recognition loop. No production framework or
  additional preference was introduced.
- Website changes were rendered in isolated headless Chromium from the same
  assembled assets as Pages, in light/dark at 320 and 960 px. All images loaded,
  eight feature cards fit without horizontal overflow or clipped text, and
  secondary card text measured at least 7.26:1 in light and 7.94:1 in dark.
  The existing native screenshots still need regeneration for dictation.
- The host is an M5 with 32 GB, not a 16 GB validation machine. Other sessions
  were active, and the integration run used an extra detector for assertions.
  No controlled latency, peak-memory or 16 GB suitability claim is made.
- Native rendering, hold/release microphone interaction, input-device transitions
  and insertion into real apps remain **unverified**. During that capture attempt,
  the shared desktop notice belonged to the Rota session, which was not interrupted
  or replaced. Recheck ownership before any new native attempt.
  An earlier owned capture attempt refused a Screenshot overlay; its retry
  stopped when the menu closed before measurement. No valid new captures were
  produced. The temporary ScreenCaptureKit experiment was removed; no foreign
  process was killed. App defaults and system appearance were restored and
  verified after that attempt. Finish the signed dev bundle's light/dark captures
  and real caret-delivery checks before publishing 3.5.0.

The synthetic corpus and reports were kept outside the repository in a temporary
directory. That directory was no longer present on October 19; recreate synthetic
fixtures and a `cases.json` manifest before rerunning the opt-in integration test.
The app's private dev model cache under Application Support is retained for the
assembled bundle. Completed browser, mutation and logging scratch files were
removed after their findings were recorded here.

### Review fixes, October 19, 2026

Three regressions were reproduced before their fixes: capture had not started
when the hold began after model eviction, cancelled first preparation reported
ready without a model, and a corrupted non-LFS Core ML file passed the SDK's
complete-snapshot check. The controller now records before any model await,
reloads against the retained recording after release, and restarts interrupted
setup after cancellation unwinds. If that restart fails, Settings offers Try Again.
Termination suppresses the restart.

The shared ASR/VAD snapshot path now checks pinned revisions, Git blob SHA-1 and
LFS SHA-256, repairs corrupt partial downloads and verifies the downloaded result.
A disposable package ran four snapshot tests and an intentional failure marker
that proved the copied sources were executing. Six isolated mutations were all
rejected: retaining corrupt partial files, skipping post-download verification,
trusting either hash type, ignoring the revision and hashing only the first chunk.
The copied sources were restored, compared with the project and the package was
removed. No live model cache or project source was mutated for these checks.

The updated engine passed 12 recognitions, three each of synthetic Russian,
English, a short English word and silence. Every result matched its expected
text exactly, including three empty silence results. An additional Russian
recognition passed after unloading and reloading with downloading disabled.
The subset manifest and reports were written under that temporary synthetic
corpus directory and are no longer available. This was a functional check,
not a latency, memory or natural-speech benchmark.

The remaining native verification requirements above still apply. These fixes
do not establish microphone interaction, real sleep/wake behavior or caret
delivery in another application.

### Native rendering, October 19, 2026

The signed development bundle produced all 12 native images through the light
and dark passes of `capture-screenshots.sh`. Each image was visually inspected;
the website link preview was regenerated from the recipe. Settings uses its
fixed 500-point width, and the dictation panel measures 280 by 80 points. Scrolling
General brought the lower Updates controls into view. This verifies reachability
at the captured window size, not an absence of scrolling.

The indicator's listening and recognizing symbols originally moved the title
by seven pixels in the 2x captures. A common 20-point icon slot keeps the title
at the same horizontal position in both states. Calibrating the capture and
pixel-reading path with an sRGB `#575757` plate returned exactly 87 in every
channel. Measured secondary text in General ranged from 4.83:1 to 4.95:1 in light
and 5.64:1 to 5.94:1 in dark; indicator titles measured 14.94:1 and 12.27:1.
These are measurements of those text samples, not every control or system-drawn
menu row.

Region capture stopped on system overlays. The renderer now uses ScreenCaptureKit
with an explicit inclusion list for the app and its opaque backdrop. A synthetic green overlay appeared in a
control composite and disappeared when excluded. A wrong target frame was
rejected without an image; removing the frame predicate in an isolated copy
made that negative check fail. Settings activation is allowed to settle before
measuring the frame, and the exact target is checked again after capture.

The dev app's own status menu reported Accessibility as Allowed after relaunch.
macOS therefore did not show another permission dialog. Native hold/release and
caret insertion were not established by the automated attempt: synthetic key
events did not establish the recording states, and the disposable destination
window closed during testing. The later manual check is recorded below. Microphone device changes and real
sleep/wake also remain unverified before publishing 3.5.0. The capture previews
never opened the microphone. The later live test attempt used the normal enabled
controller and must not be confused with those previews.

The dev settings domain matched its pre-test export at teardown. System appearance
and tracked accessibility flags matched the pre-test snapshot; the only untracked
change was the system's accessibility permission History. The installed app was
left running. Disposable native helpers and their session were stopped.

After the indicator change, `bash maintain.sh` passed with exit 0: SwiftLint,
127 passed tests, one skipped opt-in ASR test, and the signed development bundle
assembled in release configuration. Deep/strict signature verification passed.
No commit, push, tag or release was made.

The later manual check used an empty TextEdit document and the enabled signed
dev bundle, with the model prepared from its cache. The user physically held and
released right Option and reported that the phrase was inserted. A subsequent
AX read confirmed nonempty text in that exact document. It did not match the
literal requested test phrase; the actual utterance was not recorded, so this
establishes one native hold/recognize/deliver pass, not an exact recognition score.
Input-device changes and real sleep/wake remain pending. Later destination checks
are recorded below.

### Selection regression investigation, October 19, 2026

The user reported `No text selected` while invoking translation with a global
hotkey on selected text in Slack's compose editor. The installed 3.4.2 copy uses
Option-Command-F. During subsequent observation, its logs showed four Slack
translations with replacement and one result without automatic insertion. These
were separate user actions, not controlled repetitions of the reported failure.
The original no-selection error was not reproduced.

The signed development copy then completed one Slack translation and replacement
on Option-Command-T, confirmed by the user and its process-specific log. Dictation
was disabled for that translation check. This does not establish behavior on the
original shortcut with dictation enabled. Selection diagnostics now persist
metadata for failed copy and insertion guards, including focus, clipboard
ownership and the first invalidating activity class, without recording text.
No selection behavior fix is claimed. A later check of the original shortcut
with dictation enabled is recorded below.

With the user's approval, both running copies were quit normally and the dev
bundle was relaunched using the installed copy's provider, language pairs and
Rewrite presets through the argument domain, with dictation enabled. Launch
arguments were verified, Accessibility was allowed and the dictation menu showed
its configured right-Option hold binding. The installed bundle was retained.

The user then supplied a Slack screenshot showing dictated text already in the
compose field together with a dictation replacement-failure popup. This is
evidence of a false failure indication after insertion, not evidence of its
cause. The user repeated the symptom, but the temporary external observer did
not receive that attempt's events, so it supplied no timing evidence.

Delivery previously checked AX evidence once after 120 milliseconds; its
additional 600-millisecond wait did not recheck it. A deterministic test with
injected time reproduced rejection of an acknowledgement arriving after 300
milliseconds. Delivery now rechecks before restoring its clipboard write and
observes cancellation after that wait. A never-acknowledged paste is still
reported as unconfirmed, and neither case posts another paste. Diagnostics inside
the app distinguish focus/element mismatch, a range outside the AX value, value
inequality and missing caret evidence, without logging text.

The next instrumented Slack attempt still inserted text and showed the popup.
Its first AX check saw the original one-character value and a collapsed range at
zero. The later check saw the inserted value and its final caret, but equality
failed because the expected value had one additional edge newline. The diagnostic
comparison ignoring edge newlines matched. Thus both late AX updates and a
disappearing empty-editor newline contributed in that attempt; this is one
functional observation, not a latency benchmark.

The additional acknowledgement path is restricted to dictation at offset zero
in an otherwise empty field represented by a single LF. It accepts removal of
that placeholder only when the inserted value matches exactly and the collapsed
caret is at its UTF-16 end. Exact-value confirmation remains the normal path.
Regression cases preserve requested newlines and spaces, reject nonempty fields,
missing or misplaced carets and selection replacement, and keep the exception
disabled for translation. The user subsequently confirmed that dictation worked
in Slack. The app's later logs also recorded confirmed delivery after an initially
negative AX check; these are functional observations, not a pass-rate benchmark.

On October 20 the user reported the symptom again in Slack's compose editor
with 3.7.3 installed and a screenshot of the selected text under the error. The
persisted diagnostics recorded four translations over 17 seconds, each
`Copy skipped: target pid 52802, focused pid -1, activity none, Accessibility
true`, while `NSWorkspace` named Slack frontmost. The system-wide AX focused
application had not answered, so the copy guard posted no Cmd+C and the run read
as no selection. Shortly after, with Slack brought forward, a read-only probe
saw the system-wide query name Slack and its focused `AXTextArea` report a
140-character selected range, so the unanswered state was transient and was not
reproduced. A probe without a window server connection got
`kAXErrorCannotComplete` for every frontmost app and is not a witness for this.
`SelectionTarget.focusedPID` now falls back to the frontmost app only when AX
fails to answer, and logs the AX error code; an AX answer naming another process
still blocks the copy. Element, range, text and activity guards are unchanged,
so insertion still needs AX evidence. A unit test pins the order and caught the
swapped-order mutation. The fix has not been exercised in the unanswered state.

### Custom-rendered destination, October 19, 2026

Superseded on October 20, 2026 by [delivery to the current focus](#delivery-to-the-current-focus-october-20-2026):
the window target described here was removed.

The user reported that super.engineering retained the transcript in the result
popup and left its compose field empty. Native inspection through Computer Use
and direct AX metadata exposed only a standard window, with no accessible editor
or selection range. The binary contains GPUI and WebKit; linking WebKit was not
evidence that its main composer was a web editor. No other task or draft was edited.
A separate native read with the app frontmost confirmed that its focused AX
element and focused window have the same identity, satisfying the new window gate.
The driver's temporary enhanced-accessibility flag was restored to its initial
false value and verified in a fresh read; temporary inspection screenshots were removed.

Dictation now has a window target only when the focused AX element is the exact
focused standard window and its exposed children are standard window controls
only. A native read found just close, full-screen and minimize buttons in
super.engineering. The activity monitor and process/window identity still
guard dispatch, and a later change retains the result. Exposed secure fields, sheets,
dialogs, unknown roles and translation are excluded. Delivery distinguishes
confirmed text, dispatch without text confirmation, and a retained result.
Unit checks cover that policy, a single dispatch and clipboard restoration,
and changed windows before and after dispatch. In an isolated package, the four
window checks passed normally and rejected three deliberate mutations: admitting
unsupported windows, claiming that dispatch proved insertion, and ignoring a
window change after dispatch. The copied sources were restored, compared with
the project and removed with the package.

The user then confirmed that a right-Option dictation in super.engineering
inserted text without a warning. The running dev build logged capture of that
app's window and one paste dispatch with the same window still focused. Actual
insertion is established by the user's observation, not by AX text confirmation.
This is a functional native check, not a pass-rate measurement. The full
maintenance gate passed with 138 tests passing and one opt-in ASR fixture test
skipped; the signed dev bundle passed strict signature verification.

### Microphone startup latency, October 20, 2026

The user reported delayed Listening feedback after installing 3.7.4. A read-only
correlation of six installed-app holds with Core Audio events in a 95-second
window found 820-1,472 ms from press to the voice processor's processing-start
message, median 1,030 ms. Target-captured messages followed 2-16 ms later.
These processing-start messages are not measurements of the first tap buffer
or the first visible frame. The agent did not open the microphone, retain
recordings or read transcript text for this investigation.

The 3.7.4 recorder creates an AVAudioEngine and enables VoiceProcessingIO
on every hold, synchronously on the main actor. Its stop path destroys that
engine and disables voice processing to release other-audio ducking. The
indicator is constructed only after recorder startup and AX target capture;
a 50 ms timer changes Starting to Listening after the sink has received frames.
The installed logs show voice-processing device configuration during the delay,
so changing the model cannot address this startup path. Missing early speech
is consistent with short clips being shorter than the hold, but exact first
buffer timing and lost words have not been measured.

The follow-up [startup investigation](dictation-startup.md) measured the
preparation/reuse candidate and rejected it because ducking persisted while idle.
Version 3.7.5 instead moves setup and teardown off the UI, requests starting
feedback first, and gates late hardware start on the held key. Physical startup
latency remains unresolved. A continuously running microphone
would change the privacy and audio-session policy and requires an explicit
product choice; it is not an implemented or measured remedy. Apple documents
that `AVAudioEngine.prepare()` preallocates startup resources, whereas `stop()`
releases prepared resources. Neither contract proves a latency improvement
for this voice-processing graph; benchmark the actual lifecycle before choosing.
See [prepare](https://developer.apple.com/documentation/avfaudio/avaudioengine/prepare())
and [AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine).
The metadata-only correlation is stored in
`.build/diagnostics/dictation-startup/observed-startup.json`.
The [raw prepared input](dictation-startup.md#raw-prepared-input-october-20-2026)
replaced voice processing later that day, at the user's choice.

### Return right after insertion, October 20, 2026

Superseded later that day by [delivery to the current focus](#delivery-to-the-current-focus-october-20-2026),
which no longer rechecks activity or window identity after the paste.

The user reported the result popup after pressing Return as soon as dictated text
appeared. The window path rechecked the activity monitor at the end of the 720 ms
clipboard wait, so that keystroke counted as an interruption. In seven days of
installed and dev logs for super.engineering, 9 of 124 window dispatches were
retained after the paste was posted: 8 invalidated by keyboard and 1 by pointer
activity. The pre-dispatch guard already requires unchanged activity, so the
post-dispatch check now compares only the window identity. A regression test
failed with the previous check and passes with the change; a window change after
dispatch and input before it still retain the result.

### Delivery to the current focus, October 20, 2026

The user reported that insertion after dictation still failed, including in simple
cases. Metadata-only logs of 209 holds over about a day (installed and dev builds)
showed these retained results with nonempty text: 9 with no AX target at press
(Chrome, Claude, Slack), 6 pointer, 4 application and 1 keyboard invalidation
during recognition, 6 window dispatches retained after posting (5 by keyboard
input on the build before the Return fix, 1 by an AX lookup that failed after
the paste), and 1 focus on another process. 148 window dispatches to
super.engineering carried no proof of insertion either way. The user chose
delivery wherever the cursor is when the text is ready, in any app.

The earlier window path also restored the clipboard after a fixed 720 ms. A
destination that handles Cmd+V later reads the restored clipboard and pastes the
user's older content. A promised pasteboard string replaces that timer with a
read receipt. A standalone check confirmed the mechanism on this Mac: no read in
3 s with nothing pasting, and exactly one read from `pbpaste`.

A disposable AppKit target whose paste ran 0.2 s or 1.5 s after Cmd+V compared
the production delivery sources at HEAD with the new ones, three runs each, with
a marker string seeded on the clipboard. HEAD inserted in 1 of 3 runs at 0.2 s
(one dispatch to a window target left the field empty, one was retained) and
3 of 3 at 1.5 s, where its AX confirmation call blocked until the paste finished.
The new delivery inserted in 6 of 6 and restored the marker each time. The 0.2 s
HEAD failures followed the target's launch closely, so they show the old target
capture racing a fresh window, not a measured failure rate.

In a Chrome window opened for the check, the new delivery inserted Russian and
English text into an input, a textarea and a contenteditable element in 4 of 4
runs where Chrome held focus, with reads after 50-150 ms. In 2 more runs macOS
refused to activate Chrome and focus stayed in super.engineering: the posted
paste was not read there, so both were retained, with the clipboard restored.

Driving Slack, Messages and WhatsApp was stopped. System Events typed with the
active Russian layout, so a Cmd+K that never registered left six characters in
the draft of a direct message; the agent deleted exactly those characters, and
a capture confirmed the empty composer. Nothing was sent. Real-app checks in
Slack, WhatsApp, Messages and super.engineering need the user's own dictation
with the dev build; its log names each destination and read latency.

The first live dictation with that dev build crashed (`EXC_BREAKPOINT` in
`dispatch_assert_queue`): the Paste key lookup reads Text Input Sources, which
trap off the main thread, and the delivery closure in `DictationInteraction.live`
ran on a cooperative thread although the compiler accepted its call. The lookup
now sits in a main-actor static function behind a `@MainActor` closure type, so
an off-main call no longer compiles. A thread assertion in the controller test's
fake survived reverting the type, because a test-defined closure keeps the test's
main actor, so it was not kept as a pin.

### Release candidate check, October 19, 2026

Before releasing 3.5.0, the user selected text in Slack and invoked the original
Option-Command-F shortcut with dictation enabled in the signed dev copy. The user
confirmed that translation replaced the selected text. The same process's live
log recorded Slack as the destination and `Translate done, selection replaced`.
The original failure was not reproduced, so this closes the pending functional
check without attributing its earlier cause or claiming a measured failure rate.
Physical microphone-device changes and sleep/wake remain unverified; cancellation
and restart behavior have injected-effect coverage, not equivalent hardware evidence.

### Dedicated settings pane and model selection, October 19, 2026

At the user's request after 3.5.0, Dictation moves from General to its own pane.
Existing pane indices stay unchanged. The status menu's dictation action opens
that pane. The optional Small/Turbo/Large v3 picker retains Turbo as the default
for existing users and absent or unrecognized preferences. Choosing a model while
disabled only saves the choice. While enabled it prepares the selected model;
changing during preparation cancels and unwinds first. Capture, recognition and
cancellation block model changes. Old model files remain cached; only one runtime
is loaded, and its identity comes from WhisperKit's actual model folder.

The pinned Core ML catalog and each pinned OpenAI tokenizer were checked against
their source repositories. The real engine loaded Turbo, Small, Large v3 and Turbo
again, checking its actual folder and required words in two synthetic English and
Russian utterances per step. All eight transcriptions passed. Every variant also
loaded with downloading disabled. These are functional checks, not comparative
accuracy, latency, RAM or 16 GB suitability measurements. The shared dev cache is
retained for using the models; temporary synthetic audio is removed after testing.

Nine controller checks passed. In an isolated source copy, four mutations were
rejected by assertions: forcing Turbo, dropping preference persistence, allowing
changes during capture and suppressing preparation restart. Live adapters that
these tests do not exercise trap instead of performing desktop or microphone work.

The signed dev bundle rendered 14 light/dark captures through the project recipe,
including the new Dictation pane and all toolbar neighbors. All were inspected.
The pane measures 500 by 440 points in both appearances, at the fixed minimum
width; the live Ready state grows to 477 points high. AX geometry kept exposed
controls inside the window. Sampled model-description text measured 4.83:1 in
light and 5.62:1 in dark. A known sRGB gray plate through the same compositor read
87 in every channel for `#575757`. Two precision candidates were dismissed after
inspection: native mini-switch centering against text, and different left edges
of right-aligned Ready text and a switch. Radii are not measured by the AX collector.

Native AX interaction selected Small and Large v3, verified the stored preference
and the restored picker value after relaunch, then enabled Small and observed
Ready. The dev preference domain was restored and compared. `defaults import`
merges newly created keys, so teardown also removes only the model, enable, hold
binding and pane keys that this check created, after quitting its own dev process.
No recording or real destination editing was part of this settings check.

Model labels now spell out Whisper Large v3 Turbo, keeping its generation visible
alongside Large v3. Each selection has one short description and its approximate
download size; only Turbo carries the recommendation. Repository revisions stay
internal. All three selections and the open picker were rendered and inspected
in both appearances at 500 by 440 points, without clipped labels or controls.
Description contrast remains 4.83:1 in light and 5.62:1 in dark, with zero-delta
sRGB gray calibration through the same compositor. The precision analyzer's only
candidate is the previously inspected native switch/text top-edge difference of
1.88 points. The maintenance gate passed again: 142 tests passed, two opt-in tests
were skipped, and the signed development bundle built successfully. The capture
run restored and compared both the system appearance and all six dev preferences.


## Parakeet removal

Parakeet Ultra was removed from the app on October 20, 2026 at the user's
request after trying it. The removal kept Small, Turbo and Large v3; Qwen was added separately afterward.
A saved `parakeetUltra` value follows the existing unknown-preference fallback
to Turbo; other selections and the enabled state remain intact. Turbo prepares
normally if enabled and not cached. Downloaded Parakeet files are left alone;
this update does not delete user data. The Parakeet loader, runtime, integration
checks, bundled attribution and FluidAudio dependency were removed. Silero
uses Core ML directly and continues to gate speech unchanged.

The standalone comparison scripts remain research tools with an explicit
FluidAudio pin, separate from the app dependency graph. Their historical
measurements remain in [the experiment report](parakeet-ultra-experiment.md).


Removal verification on October 20, 2026:

- `bash maintain.sh` exited 0: strict SwiftLint, 188 tests (nine explicit opt-in
  skips) and the assembled Developer ID signed release-configuration bundle.
- The new preference regression failed on the original `parakeetUltra` selection
  and passed after removal, through the real `Settings.dictationModel` getter.
  Small, Turbo, Large v3 and unknown preferences are covered in the same test.
- `scripts/check-dictation-audio.py --skip-build` passed all 12 offline Turbo
  recognitions, including silence. No microphone or speakers were used.
- The finished bundle has no FluidAudio symbols, resource bundle, licenses or
  Parakeet attribution. Its code signature verifies. Silero assets and the
  Whisper caches are preserved.
- Native AX selection and screenshots verified English and German at the
  minimum 500-point window width, light before dark. Both menus contain exactly
  the three Whisper choices. Launching with the old Parakeet preference shows
  Turbo; selecting Small and returning to Turbo persists the new value. All
  four captures were inspected; model-summary contrast is 4.83:1 in light and
  5.47:1 in dark, with measured picker and footer bounds.

The UI check used a signed temporary copy with the unique bundle identifier
`com.wiltodelta.translatelikeme.parakeet-removal`, because another probe already
owned the development identifier. The owned app was stopped and deleted; its
preferences and system appearance were restored. The global-defaults comparison
around the dark-mode switch differed only in `NSLinguisticDataAssetsRequestTime`;
that unrelated changed value was preserved. The initial AX helper failure was
resolved by initializing `NSApplication.shared`, as the project's existing
standalone-probe rule requires. This was a harness failure, not an app crash.

`.build/diagnostics/parakeet-removal/` retains logs, JSON verdicts, four captures
and the UI recipes as local verification evidence. The temporary app, compiled
helpers, synthetic audio and full global-defaults backup were removed. The
runnable development bundle remains at `Translate Like Me.app`. No release was
published by this removal task.
