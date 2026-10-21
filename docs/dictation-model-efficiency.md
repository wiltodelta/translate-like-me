# Dictation model efficiency

Investigation: October 19, 2026. Scope: the existing WhisperKit implementation,
with Turbo selected in the installed app. The measurements below record the
original CPU/GPU baseline, not a natural-speech accuracy benchmark. After the
user approved implementation, Turbo's encoder and decoder were switched to
CPU/Neural Engine. The October 20 follow-up approval extends that policy to
Small and Large v3. Verification is recorded
under the implementation section below. The subsequent
[Parakeet integration](parakeet-ultra-integration.md) temporarily added a separate backend,
removed at the user's request on October 20;
the comparisons on this page concern the three Whisper models.

## Implementation findings

At the measured baseline, `DictationEngine.prepare` explicitly allowed CPU/GPU
for both the audio encoder and the text decoder. The mel spectrogram retains
the SDK's CPU/GPU default. Neural Engine execution was excluded for the two
main components. In the pinned
WhisperKit 1.1.1 source, the default encoder and decoder policy on supported macOS
is CPU/Neural Engine. A permission to use a device does not establish actual
operator placement or prove it is the fastest configuration.

An exploratory native process sample reached `MPSGraphExecutable`,
`GPURegionRuntime` and Metal command encoding while the GPU arm was recognizing
synthetic speech. GPU acceleration is therefore present on this path. Adding
a separate PyTorch MPS backend would replace the runtime, rather than switch on
an acceleration path missing from this app.

The runtime already remains resident between dictations. Memory pressure or
disabling releases it; an evicted model reloads after recording ends. Model
loading is outside microphone startup. Keep these two latency questions separate,
as described in [capture startup](dictation-startup-latency.md).

`ModelSnapshot` hashes cached files before a reload. This is an integrity
boundary added because the SDK accepts partial or corrupt caches. Removing
these checks to improve a loading number would change that guarantee. It cannot
speed up a dictation with the model already resident.

Silero runs on CPU and stops at the first speech-positive window. Empty or
digitally silent audio skips it and Whisper. It gates the original clip without
cutting words or removing pauses. The inference benchmark records its cost
separately from Whisper.

Whisper processing uses automatic language detection, greedy temperature-zero
decoding initially, timestamp tokens and up to five temperature fallback steps.
Word-level timestamps are already off. The default worker count of 16 does not
parallelize this single audio array: without a chunking strategy the SDK runs
its sequential window loop. Adding workers alone cannot accelerate that loop.

The pinned Turbo metadata declares 480,000 audio samples for MelSpectrogram
and `[1, 128, 1, 3000]` for AudioEncoder input. The SDK pads each window to
30 seconds at 16 kHz. A two-second utterance therefore still runs a full
encoder window. Removing the existing half-second quiet tail or adjusting the
microphone tap buffer cannot shrink this model's encoder graph. A smaller
model or a shorter-context export is a separate accuracy/performance experiment.

WhisperKit's `prewarm` sequentially loads and immediately unloads components
before the ordinary load. Its purpose is to reduce peak specialization memory,
with additional load work. It does not perform a disposable transcription and
should not be enabled under the assumption that it removes first-decode latency.

## Experiment and coverage

The current runner builds an isolated release SwiftPM package from the
production model catalog, integrity checks, speech detector and transcript
cleanup, with runtime revisions read from the app's lockfile. The original
measurements below used directly linked WhisperKit/ArgmaxCore release objects
before FluidAudio was added to the app.
Configurable inference arms call WhisperKit directly with the same audio
loading, speech gate, minimum length, quiet tail and decoding settings as the
engine. This measures processing after capture, not microphone startup,
Accessibility, clipboard delivery or the complete app's memory footprint.

Use the reproducible runner:

```bash
caffeinate -dimu nice -n 10 python3 scripts/benchmark-dictation.py \
  --output .build/diagnostics/model-efficiency-new \
  --models turbo --rounds 2 --repetitions 3
```

The output directory must be new. The runner compiles and signs a terminal-only
benchmark, uses the existing development
cache and verifies its pinned assets through the real engine with downloading
disabled. It never opens a microphone, plays audio, changes preferences or
launches the app. Missing assets fail instead of initiating model downloads.
The SDK can still fall back to its tokenizer downloader if a locally loaded
tokenizer fails; this experiment is not proof from a network-disconnected host.

Four synthetic cases use installed Samantha and Milena voices: short English,
short Russian and a longer message in each language crossing a 30-second
window. Each arm runs in a fresh process. The first inference pass is retained
separately, followed by three warm passes with rotating case order. The second
round reverses arm order. Model files, tokenizer, inputs and decoding settings
stay fixed while compute policy changes. Mel remains CPU/GPU in all arms.

| Arm | Encoder | Decoder |
| --- | --- | --- |
| `gpu` | CPU/GPU | CPU/GPU |
| `ane` | CPU/Neural Engine | CPU/Neural Engine |
| `ane-gpu` | CPU/Neural Engine | CPU/GPU |
| `gpu-ane` | CPU/GPU | CPU/Neural Engine |
| `all` | All permitted | All permitted |

Additional arms isolate other changes against `ane`: `ane-prewarm` changes
only loading policy; `ane-no-fallback` disables temperature retries;
`ane-vad` enables VAD chunking with two workers. `--stress` replaces the long
messages with three identical paragraphs, deliberately exercising repetition
and fallback behavior. Do not merge this stress corpus with ordinary messages
when reporting speed or accuracy.

The report records stage timings, current physical footprint, process CPU time,
thermal state, output hashes, required-term counts and synthetic word errors.
Text normalization preserves non-Latin scripts, folds Russian `ё` to `е`, and
ignores punctuation/case. It does not hide missing repeated terms. Word errors
use edit distance against the generated text; punctuation quality, natural
speech and code-switching remain unmeasured. Hashes can establish equal outputs
without retaining transcripts. Generated audio is temporary and removed on
normal completion, failure or handled interruption. A partial JSON file is not
a completed arm; validate the complete case/iteration set and process exit.

The SDK's `totalDecodingFallbacks` is not a reliable retry count: the pinned
loop assigns the zero-based failing attempt index to it, rather than incrementing
a counter. A first failed attempt can therefore leave it at zero. Inspect
`decodingFallback` time and the actual loop as well. Fallback time overlaps
decoder work; do not add it to prediction time as an independent cost. Positive
temperature sampling uses `Float.random`, so repeated stress results can differ
without a compute-policy change.

Physical footprint is sampled at boundaries, not continuously, and excludes
some system-owned accelerator allocations. CPU seconds are not energy use.
There is no power measurement or 16 GB suitability conclusion. Other background
jobs were active on the host; they were left untouched. Interpret the reversed
order and paired comparisons as observations under that load, not an idle-device
performance guarantee. Repetitions of the same four synthetic inputs are not
independent speech samples.

## Evidence locations

The ordinary-message run is under
`.build/diagnostics/model-efficiency-message/`. Its metadata pins source and
binary hashes; per-arm reports contain every retained measurement.
The ordinary-priority confirmation is under
`.build/diagnostics/model-efficiency-priority/`, with its own metadata and
`summary.json`. Both complete runs are retained as measurement evidence.
The earlier `.build/diagnostics/model-efficiency/` contains exploratory repeated
paragraph runs, incomplete arms, setup pilots and a GPU process sample. Those
pilots changed scoring during setup and must not be used as a controlled
compute-policy comparison.
Generated audio and disposable benchmark executables are removed after
verification. The existing development model cache remains available to the
app. The two retained scripts rebuild the benchmark for a new output directory.

## Local results at background priority

The first complete matrix used Apple M5, 32 GB, macOS 27.0.1 (26A434),
Swift 6.4, release optimization and process nice level 10. All recorded thermal
states were `fair`. Five policies, two arm orders, four cases and four passes
produced 160 recognitions, including 120 warm measurements. Each cell below
has six warm observations of that case; values are median processing seconds,
including audio loading, speech detection and transcript cleanup.

| Case | Audio seconds | GPU/GPU | ANE/ANE | All/all | ANE/GPU | GPU/ANE |
| --- | --- | --- | --- | --- | --- | --- |
| en-short | 2.65 | 1.263 | 0.922 | 1.057 | 1.406 | 1.297 |
| ru-short | 3.53 | 1.551 | 1.129 | 1.222 | 1.658 | 1.596 |
| en-long | 49.79 | 6.781 | 3.886 | 4.781 | 7.347 | 6.588 |
| ru-long | 51.75 | 9.931 | 5.128 | 6.097 | 9.917 | 8.339 |

ANE/ANE reduced pooled median latency by about 27% on the two short cases,
43% on the longer English message and 48% on the longer Russian message.
This hides a real order effect: the long Russian case had ANE medians of
3.855 and 6.838 seconds in the two rounds, against GPU's 9.948 and 9.738.
The short Russian case even reversed in round two: ANE 1.525 seconds, GPU
1.351. Do not describe this as a uniform short-utterance improvement or an
idle-device benchmark. There are only four distinct synthetic inputs; the
case-paired sign test on pooled medians is 4/4 favorable, two-sided p=0.125.

All 160 exact output hashes matched the GPU baseline for their case, with no
missing required term counts and zero SDK fallback time. The long Russian
reference still has five normalized word errors out of 108 words in every
arm; the other three have zero. Equal output establishes equivalence on these
inputs, not general natural-speech accuracy.

The initial observed ANE load took 173.443 seconds: 153.311 for encoder loading
and 19.646 for decoder loading. A sample of the caller was waiting inside the
ANE compilation path. The compiler service itself could not be sampled without
additional privileges; no privilege escalation was requested. The next fresh
ANE process loaded in 2.115 seconds. These are observed cache states, not a
controlled experiment with Apple's specialization cache cleared. `all` loaded
in 61.759 then 2.420 seconds. First-load compilation must remain separate from
resident-model recognition.

Pooled median CPU seconds for the long Russian case fell from 5.736 to 1.204
and for short English from 0.464 to 0.062. This is process CPU work, not energy.
Measured process footprint was lower for ANE, but system-owned accelerator
memory was not accounted for, so no total RAM-saving figure is claimed.

The complete two-by-two encoder/decoder matrix matters: changing just one
component did not preserve the full joint policy's benefit in this run.
Lower decoder timing under joint ANE placement cannot, by itself, prove that
an independent decoder-only change causes the same improvement. The mechanism
behind the hybrid results remains unmeasured.

The report-shape validator accepted the real 16-row GPU output and rejected six
mutations: a missing row, duplicate row, empty rows, wrong iteration, false
speech flag and absent reference words. A second real SDK run compared unchanged
synthetic audio against changed references. Both passes detected an added absent
word and a missing repeated occurrence while preserving the baseline transcript
hash. Both muted-audio passes skipped decoding, returned empty output and were
scored against the nonempty reference as errors. All temporary audio from those
checks was removed. These checks validate measurement behavior, not microphone
or natural-speech performance.

## Control at ordinary process priority

A second experiment repeated only GPU/GPU and ANE/ANE at nice level 0, with
both arm orders and the same four audio files (all input SHA-256 hashes match
the first experiment). It completed 64 recognitions, including 48 warm
measurements, six per case/policy cell. This is a separate corroborating run,
not an isolated test of nice level: it ran later while background work continued.
Do not merge its absolute timings with the background-priority matrix.

Reproduce the shorter control without lowering process priority:

```bash
caffeinate -dimu python3 scripts/benchmark-dictation.py \
  --output .build/diagnostics/model-efficiency-priority-new \
  --arms gpu ane --rounds 2 --repetitions 3
```

| Case | GPU seconds | ANE seconds | Median latency reduction | CPU seconds, GPU / ANE |
| --- | --- | --- | --- | --- |
| en-short | 1.458 | 1.150 | 21.1% | 0.518 / 0.083 |
| ru-short | 1.822 | 1.362 | 25.2% | 0.603 / 0.139 |
| en-long | 8.377 | 5.028 | 40.0% | 3.732 / 0.973 |
| ru-long | 11.132 | 6.447 | 42.1% | 5.826 / 1.515 |

Both policies produced identical exact output hashes in all 64 cases, with
zero fallback time and no missing required term counts. The normalized errors
remain the same as in the first matrix. All thermal samples were `fair`.
The long-message improvement repeats at ordinary priority, and the short
medians improve too. Four distinct inputs are still too few for a general
accuracy or device-wide tail-latency promise. The case-level sign test remains
4/4 favorable with two-sided p=0.125, rather than treating repeated TTS as new
independent speakers.

The measured candidate for the currently selected Turbo is joint
CPU/Neural Engine placement, with the mel spectrogram left on CPU/GPU.
Keep the resident runtime, CPU speech gate, pinned-file validation, automatic
language detection, quiet tail and timestamp handling. These experiments do
not justify disabling fallback, changing model weights, or extending the
compute-policy verdict to Small and Large v3 without their own runs.

## Small and Large v3 follow-up

The user requested the same GPU/ANE comparison for both remaining catalog
models. The run uses the same four synthetic inputs, three warm repetitions
per input and two rounds in opposite arm order, at nice 10. Each model has
64 recognitions including first passes, with six warm observations per
input and policy. It runs serially after the Turbo production-path check.
This is a within-model compute comparison; it does not rank natural-speech
accuracy between model families.

Small completed both rounds. CPU/Neural Engine reduced the warm median in
all four cases. Every exact output hash matched the corresponding GPU output
across all 64 calls, with no missing required term counts. The normalized
errors were unchanged: zero on both short cases, 1/132 on long English and
10/108 on long Russian. All thermal samples were fair.

| Small case | GPU seconds | ANE seconds | CPU seconds, GPU / ANE |
| --- | --- | --- | --- |
| en-short | 0.506 | 0.359 | 0.497 / 0.105 |
| ru-short | 0.810 | 0.519 | 0.844 / 0.180 |
| en-long | 5.001 | 3.258 | 4.812 / 1.395 |
| ru-long | 7.932 | 5.383 | 7.608 / 2.316 |

Large v3 also completed both rounds, without missing required term counts
or fallback time. The short cases had zero normalized word errors, long
English 1/132 and long Russian 2/108 under both policies. All normalized
output hashes matched. Eight ANE outputs, all long English, differed in
exact hash from GPU while retaining the same normalized hash. Normalization
removes case, punctuation and whitespace distinctions and folds Russian
`ё` to `е`; the saved hashes do not identify the literal difference. Do not
claim byte-identical text for this model.

| Large v3 case | GPU seconds | ANE seconds | CPU seconds, GPU / ANE |
| --- | --- | --- | --- |
| en-short | 1.672 | 1.234 | 1.194 / 0.264 |
| ru-short | 2.553 | 1.742 | 1.878 / 0.495 |
| en-long | 17.628 | 9.985 | 14.980 / 3.940 |
| ru-long | 26.635 | 14.681 | 23.744 / 6.092 |

The pooled median latency reductions are 29.2-35.9% for Small and 26.2-44.9%
for Large v3. Both models favor ANE on all four distinct inputs, with a
case-level two-sided sign-test p=0.125 for each model. This remains a small
synthetic corpus. Large v3's GPU round medians moved substantially: long
English 22.980 to 14.329 seconds and long Russian 38.051 to 21.430 seconds.
ANE remains faster within both rounds, but the pooled reduction is not a
stable hardware-wide speed promise. Large thermal samples were nominal or
fair; Small samples were fair.

First observed ANE loading took 39.939 seconds for Small and 32.435 seconds
for Large v3; repeat loading took 0.914 and 0.434 seconds. GPU loading was
0.811-2.087 and 1.607-3.884 seconds respectively. First inference passes are
stored separately and excluded from the warm medians; Small and Large v3's
initial GPU English-short calls took 11.836 and 13.410 seconds. These are
observed preparation costs, not a fresh-install or uncached-device guarantee.

Sampled warm process physical footprint ranged from 437-645 MB on GPU
versus 146-171 MB on ANE for Small, and 667-1167 MB versus 241-280 MB for
Large v3 (decimal MB). These are process samples, not total accelerator
memory or measured peaks. No energy measurement was made.

Artifacts are under `.build/diagnostics/whisper-small-large-compute/`.
`metadata.json` reports complete; `summary.json`, per-arm JSON and logs,
`verification.json` and the summarizer retain the evidence. All 128
recognitions were present. Source and binary hashes matched the run's
metadata before cleanup, and strict binary signature verification passed.
Generated audio was removed by the runner; the benchmark process exited.
Small and Large v3 initially retained CPU/GPU under the original Turbo-only
approval. On October 20, the user approved switching both models to
CPU/Neural Engine for encoder and decoder and checking the build.

## Optimization decisions

The compute policy remained unchanged during measurement. Evaluate
encoder and decoder independently using the four CPU/GPU and CPU/Neural Engine
combinations. Prefer a policy only after inspecting latency, CPU time, memory
and output differences together. `all` permits OS placement; it is not a promise
of fastest execution.

Keep integrity checks, automatic multilingual detection, the speech gate,
complete-window timestamp behavior and model residency. VAD chunking or
removing retries changes recognition behavior and needs separate quality
acceptance, particularly around quiet words, pauses and window boundaries.
Do not trade away those guarantees using a speed-only result.

Streaming recognition during a held key could move work before release while
preserving hold-only microphone capture, but the current Whisper window decoder
can repeatedly reprocess accumulated audio. It is a separate architecture
experiment, not a compute-unit flag. It needs cancellation, route-change,
boundary and mixed-language checks plus measured total work. It does not
authorize continuous capture or a pre-press audio buffer.

## Implementation and production-path verification

The user initially approved joint CPU/Neural Engine placement for Turbo while
preserving Small and Large v3, then approved extending it to both remaining
models after their comparison. `DictationEngine.prepare` now passes
`.cpuAndNeuralEngine` to both encoder and decoder for the whole catalog.
The per-model compute conditional is removed. Mel, Silero,
model revisions, decoding settings and runtime residency stay unchanged.

The first implementation maintenance gate exited 0. XCTest executed 177 tests:
168 passed and nine opt-in tests were skipped. The gate assembled the arm64
development app with Developer ID signing and hardened runtime. A separate
strict signature check passed and the bundle id is
`com.wiltodelta.translatelikeme.dev`.

The production-path synthetic check passed all twelve cases: English, Russian,
Russian foreground with weaker English background, and digital silence,
three times each. All six required terms survived in every speech case;
silence stayed empty. This exercises the real engine through a finalized
48 kHz, seven-channel WAV, resampling and speech detection. It does not test
physical microphone capture or acoustic echo cancellation.

The first attempt reached the runner's old 180-second deadline. A sample of
the XCTest host was waiting in Core ML's ANE compilation path. The process
finished after cancellation and no test process remained; temporary audio was
removed. The runner's bounded deadline is now 600 seconds to cover preparation
and recognition. Retrying with that budget passed. A separate benchmark's
cache does not guarantee a compilation-free XCTest invocation.

Artifacts are retained under `.build/diagnostics/turbo-ane-implementation/`:
`maintain.log`, the initial failed `audio-check.json`, the successful
`audio-check-retry.json` and test log, and the native compilation sample.
No transcripts or recordings are retained. The existing model cache is kept
for the app. The Small and Large v3 follow-up build log is stored at
`.build/diagnostics/all-models-ane-implementation/maintain.log`.

## Primary sources

- [Pinned compute defaults](https://github.com/argmaxinc/argmax-oss-swift/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/Sources/WhisperKit/Core/Models.swift#L92).
- [Pinned load and prewarm contract](https://github.com/argmaxinc/argmax-oss-swift/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/Sources/WhisperKit/Core/Configurations.swift#L48).
- [Pinned transcription and chunking](https://github.com/argmaxinc/argmax-oss-swift/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/Sources/WhisperKit/Core/WhisperKit.swift#L1017).
- [Pinned decoder fallback loop](https://github.com/argmaxinc/argmax-oss-swift/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/Sources/WhisperKit/Core/TranscribeTask.swift#L315).
- [Apple compute policies](https://developer.apple.com/documentation/coreml/mlcomputeunits).
