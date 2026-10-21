# Unattended dictation verification

> Since October 20, 2026 capture uses raw input without voice processing; see
> [raw prepared input](dictation-startup.md#raw-prepared-input-october-20-2026).
> The echo-cancellation, ducking-restoration and foreground-preservation sections
> describe the removed path. The software path still applies.

The user requested checks without reading a phrase, responding to timed prompts
or pressing the dictation key. Do not restart the earlier interactive procedure.
Keep software validation and physical echo cancellation as separate verdicts.

## Software path

Parakeet installation and runtime switching are checked separately with
`python3 scripts/check-parakeet.py`. That opt-in run downloads its pinned
assets if needed, verifies offline reload and cancellation, and uses only
synthetic fixtures. See [Parakeet integration](parakeet-ultra-integration.md).

Run from the checkout:

```bash
python3 scripts/check-dictation-audio.py
```

The runner generates English and Russian speech with installed macOS voices,
mixes a weaker English background into Russian speech, and adds digital silence.
It never plays these files or opens a microphone. Full Xcode, the installed
Samantha and Milena voices, and an already prepared development Turbo cache are
required by default. `--model parakeetUltra` selects an already installed
Parakeet cache instead. It disables model downloading. Missing prerequisites fail the run.
`--skip-build` reuses a test bundle containing `DictationAudioValidationTests`.

Each fixture passes through the production `DictationAudioFile` sink as 48 kHz,
seven-channel, noninterleaved float PCM, then through the real audio loader,
speech detector and selected cached recognizer. The discrete channel layout is
explicit: the convenience format initializer does not support this channel
count. The test verifies finalized frame/channel counts, all six expected words
in each speech case, and empty output for silence, with three recognitions per
case. The seven identical channels reproduce the format observed on this Mac;
this is not coverage of every hardware format.

The runner writes `.build/dictation-audio-check/report.json` and a test log.
Its report contains identifiers and counts, never transcripts. It removes
generated audio and captured WAVs on success, failure, timeout or interruption.
Subprocess deadlines kill the entire owned process group. Ordinary `swift test`
skips this opt-in check.
The recognition subprocess has a 600-second deadline including model
preparation. Turbo uses CPU/Neural Engine; first-use specialization in the
XCTest host can exceed the previous 180-second budget even when a separate
CLI benchmark already prepared the same model cache.

This verifies the path after voice processing. The mixed case simulates a
residual background at that boundary. It cannot establish how much speech the
echo canceller removes or preserves.

The October 19, 2026 run passed all twelve recognitions: each speech case
retained its six terms in all three runs, and silence returned empty text in
all three. A deliberate mutation replaced only the mixed foreground with
verified zero PCM. All three recognitions rejected it, failing the emptiness
and required-term assertions each time. The other speech cases still passed.
The process-group timeout check killed its synthetic grandchild, and five
incomplete, duplicated or empty report shapes were rejected against the real
recognition output. Temporary audio was removed after each check. These are
software-path results, not acoustic acceptance.

## Acoustic playback and restoration

These checks can run without a person speaking. The development harness uses
separate signed processes for reference playback, untreated microphone capture
and the candidate recorder. The untreated process must never enable voice
processing. Keep the source playing across each comparison and verify its
advancing playhead, rather than trusting a successful player launch.

Measure an initial untreated reference before starting any voice processing.
After both stop and discard, compare recovery to that initial reference as well
as to the immediately preceding sample. Two equally attenuated samples do not
prove restoration. Require an audible acoustic control, adequate signal-to-noise
and finalized recording lengths. A weak control means inconclusive, not passed.
Stop on the first invalid control instead of repeating a long playback session.
Never retain the candidate's audio engine for inspection after stop: let it
follow the production lifetime. API flags alone are not acoustic evidence.

The earlier experimental recipes and metadata remain in the ignored directory
`.build/diagnostics/full-audio-validation/`. That run was stopped by the user;
its recordings were deleted. It did not clear release acceptance. A stronger
tone produced a material first-cycle decrease in the recorded reference; the
independent-process follow-up was interrupted. That recording change has not
been attributed to playback attenuation versus microphone-path changes.

## Foreground preservation

A physical preservation test needs a source independent of the Mac's playback
reference, such as a prerecorded voice played by a separate speaker near the
microphone while the Mac plays the background. It can be automated when that
equipment is available; a live reader is not required.

This Mac currently exposes its built-in speakers and microphone plus an iPhone
microphone, with no independent playback device. Do not activate the phone or
install audio drivers as a side effect of the test. Apple explicitly excludes
voice processing from manual rendering in its
[AVAudioEngine overview](https://developer.apple.com/videos/play/wwdc2019/510/).
Feeding a synthetic file after processing, or playing both voices through this
Mac's speakers, cannot stand in for independent foreground speech.

Until an independent source is available, report physical voice preservation
as not tested and keep acoustic release acceptance open. The previous empty
interactive recordings are not evidence of lost speech: the user confirmed
missing the first recording window, and the later timed attempts were not
confirmed before the stop request.
