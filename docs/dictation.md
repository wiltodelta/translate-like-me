# Local dictation

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

WhisperKit 1.1.1 runs the selected multilingual Core ML model. `DictationModel`
offers Whisper Small (`openai_whisper-small`), Whisper Large v3 Turbo
(`openai_whisper-large-v3-v20240930_626MB`, the unchanged default) and Whisper
Large v3 (`openai_whisper-large-v3_947MB`). Their pinned repository snapshots
contain about 487, 627 and 948 MB respectively, excluding tokenizer and shared
speech-detector assets. The default has four decoder layers and 32 encoder layers. Recognition uses automatic language
detection, without a Russian/English allowlist, and transcription rather than
translation. This is an initial integrated configuration, not a claim of model
superiority or production quality across every supported language.

`DictationEngine.swift` pins the shared model repository revision;
`DictationModel.swift` pins each matching tokenizer revision and file hashes.
WhisperKit's downloader maintains partial transfers. `DictationSnapshot` checks
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
It checks whether a clip contains speech before Whisper sees it. The original
clip stays intact, with no trimming at voice boundaries. The detector runs on
CPU and its state resets for every recording. Failures propagate as errors,
rather than silently becoming an empty result.

This gate addresses observed text hallucinations on synthetic noise. WhisperKit
1.1.1's [decoder](https://github.com/argmaxinc/argmax-oss-swift/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/Sources/WhisperKit/Core/TextDecoder.swift#L821)
hardcodes `noSpeechProb` to zero, so its advertised no-speech threshold cannot
reject these clips. Do not treat that field as a measured probability. Keep
timestamp decoding enabled: disabling timestamps lost part of a sentence at a
30-second window boundary in the long synthetic clip. Short clips retain the
quiet tail, and punctuation-only results are discarded.

Before preparation, the app checks the cache volume for at least 8 GB free.
This is a conservative preparation budget, not a measured universal Core ML
requirement. Earlier compilation on an almost-full disk terminated the process
inside LLVM/MPS. The check prevents preparation in that observed low-space
condition; it cannot reserve space against other processes filling the disk.

Models live under `~/Library/Application Support/<bundle id>/Dictation`.
Development builds use their own `.dev` id. Core ML uses CPU/GPU compute units.
A loaded model stays ready; memory-pressure notifications or disabling dictation
release it after active work completes. Press starts the recorder synchronously;
after release, drained audio stays available while a model reload finishes.
Interrupted first preparation restarts after the cancelled task unwinds. The
controller stays preparing until assets are ready; termination suppresses that retry.
Timed two-minute eviction was removed
because diagnostic runs showed a material reload cost. No memory-policy control is exposed.

The recorder writes only its current temporary 16 kHz mono WAV. Recording is
bounded to five minutes. The file is removed after recognition or cancellation.
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
The held-key monitor stays installed through capture. Resetting it on press
would lose the release event. There is no dedicated dictation cancellation key:
reaching for Escape while holding Option is awkward, and the interval after
release can be too short to use reliably. Undo after insertion belongs to the
destination editor. Pointer cancellation and lifecycle invalidation still guard
pending work. Release drains the already-started recorder even before its first
meter update. Model preparation happens after release and cannot delay capture
or start a microphone after the key is up.
Dictation and text transformations share the activity guard.
A session id rejects late asynchronous results; phase validation also rejects
late recording-meter updates after recognition has begun.

The starting app, AX element, caret/selection and available text must still match
before insertion. Typing, clicking, or switching apps invalidates that destination;
the Option hold produces modifier events, not text-edit events. Missing evidence or a
failed insertion shows the text with Copy. Clipboard snapshots retain rich
representations and never replace a newer user copy. AX-secure text fields are not
automatic insertion targets.
If a custom renderer exposes only a focused standard window, dictation can use
that window's AX identity and the uninterrupted activity monitor as its target.
Its exposed children must be standard window controls only; ordinary accessible
content and unknown children do not qualify for this path.
It posts Paste to the original process only while that window remains focused.
This path records dispatch, without claiming AX text confirmation. It cannot
detect a programmatic focus change inside a window whose fields are not exposed.
The most recent result remains available through Copy Last Dictation. Translation
and Rewrite retain their requirement for a real text selection and AX field evidence.
AX range decoding rejects negative locations and lengths before caret opt-in;
that opt-in admits a zero-length range only. The real AXValue regression fixture
first failed for three malformed ranges, then passed after validation moved to
the decoder used by both capture and replacement verification.

## Verification

`DictationTests` exercises session cancellation, stale meter callbacks, direct
caret delivery without copying a selection, changed targets, a new copy during
snapshot, a new copy after paste, and cancellation after paste dispatch.

`DictationControllerTests` drives the real controller with controlled model,
recording and presentation effects. It covers immediate capture after model
eviction, audio retention through reload, cancellation during reload, interrupted
first preparation and termination without restarting preparation. Continuations
control progress; these tests never request the microphone or drive native windows.
`DictationSnapshotTests` covers Git/LFS hashes, streaming across chunk boundaries,
partial-cache repair, pinned revisions and verification after downloading.
`DictationSetupTests` also feeds a corrupted complete fixture through the real SDK,
proving that its accepted snapshot is rejected by the app.

`DictationIntegrationTests` is opt-in through `TLM_DICTATION_SAMPLES`, pointing to
a directory with synthetic audio and `cases.json`. Normal tests skip it and never
request microphone access or download weights. The live test prepares the pinned
model, recognizes the supplied clips, unloads it, then reloads with downloading
disabled. Synthetic speech verifies integration; it does not establish natural
speech accuracy or replace an M5 model comparison.

`OptionKeyGestureTests` covers left/right identity, press/release actions,
intervening activity, every neighboring modifier, both Options together, a
pre-held key, and shortcut representation. `DictationTests` also covers release
during startup and after capture begins. Global/local monitor delivery and the
shortcut recorder still need native checks. Six isolated mutations of press,
release, cancellation, initial flags, startup release and captured-audio release
all failed their assertions after the nine-test isolated baseline passed.

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

### Custom-rendered destination, October 19, 2026

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
