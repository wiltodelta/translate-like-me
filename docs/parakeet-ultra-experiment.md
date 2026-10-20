# Parakeet Ultra experiment

Historical experiment. After reviewing these results, the user approved the
[app integration](parakeet-ultra-integration.md) on October 20. The measurements
below describe the standalone build, before that integration.

Experiment date: October 20, 2026. This is a standalone local comparison,
not an app model-catalog change. Whisper Turbo remains the app's default.
The experiment never opens a microphone, plays audio, changes preferences,
or sends audio or transcripts to a service. Only model and SDK downloads
use the network; recognition uses local paths.

## Reproduction

```bash
caffeinate -dimu nice -n 10 python3 scripts/benchmark-parakeet.py \
  --output .build/diagnostics/parakeet-ultra-new
```

The output directory must be new. A separate generated Swift package depends
on FluidAudio and WhisperKit, leaving the app's manifest and lockfile alone.
It copies the current production dictation sources and existing Whisper
benchmark into that package. Only the existing benchmark's `@main` attribute
is removed, allowing its complete Whisper arm and scoring functions to run
beside the experimental Parakeet entry point. The dependency lockfile, source
hashes, binary hash and signing identity are recorded with the report.

Pinned inputs:

- FluidAudio v0.17.7, commit `503b4bd1bbf7220882de39fe8ae6716aae4132da`.
- `FluidInference/parakeet-ultra-coreml`, revision
  `95eaa59a39d4394f047a4dc5cce480388a60d1b6`.
- WhisperKit 1.1.1 and the app's pinned Whisper Turbo, tokenizer and Silero assets.

The runner validates every downloaded model file against the pinned Hub
metadata, using SHA-256 for LFS and Git blob SHA-1 for ordinary files. It
checks lengths too. `AsrModels.loadLocal(version: .ultra)` loads those exact
files without the SDK's automatic downloader. The SDK's default puts the
preprocessor on CPU and the encoder, decoder and joint model on CPU/Neural
Engine. The experimental package disables the optional NeMo text-processing
trait. That trait controls a text-normalization dependency, not ASR languages.
SDK transcript logging is suppressed.

The downloaded files occupy 632,316,735 bytes, excluding filesystem overhead.
They are cached separately from the app's model catalog at
`~/Library/Caches/com.wiltodelta.translatelikeme.dev/ParakeetUltra/<revision>`
for repeated experiments.

## Comparison contract

Both arms run in the same optimized executable with the same audio loader,
Silero speech gate, minimum one-second input and half-second quiet tail.
Whisper uses its production automatic-language decoding and transcript cleanup.
Parakeet uses the SDK's default long-form path without a language hint and
starts a new TDT decoder state for each recording.

The six synthetic inputs are short English, short Russian, about 50-second
English and Russian messages, a Russian sentence containing GitHub, pull
request and release notes, and two seconds of digital silence. Voices are
Samantha and Milena. No recordings from the user's files are used.
Each arm runs once in each round, with reversed arm order in round two.
Every invocation retains a first pass and three warm repetitions, rotating
case order. There are 96 recognitions/gate decisions in total, 48 per model,
with six warm observations per input and model. Loading is measured separately.

Reports keep normalized word errors, required-term omissions, output hashes,
latency, CPU time, sampled physical footprint and thermal state. They contain
no transcript text. Expected synthetic text and audio hashes are retained for
reproduction; generated audio is removed when the runner exits. Silence is
expected to be rejected by the shared speech gate, so its empty output does
not establish either model's resistance to hallucination without that gate.

The scorer ignores punctuation and case, folds Russian `ё` to `е`, and
preserves non-Latin characters. It does not grade punctuation or manual
correction effort. Repeated TTS from two voices is not a natural-speech quality
benchmark, and sampled process footprint is not peak or accelerator memory.
No energy measurement is made. An app integration would still need model
installation integrity, lifecycle, cancellation and rendered model-selection
verification.

## Results

The completed run used an Apple M5 with 32 GiB, macOS 27.0.1 and Swift 6.4,
at nice 10. Metadata reports complete and all 96 expected rows are present.
Source and executable hashes were checked against metadata and the executable's
strict Developer ID signature check passed. The resolved dependencies contain
the pinned FluidAudio and WhisperKit revisions and ArgumentParser 1.8.2.

Warm medians below include loading the audio, the speech gate and recognition,
but exclude loading the model. Each cell has six warm observations.

| Input | Turbo seconds | Ultra seconds | Word errors, Turbo / Ultra |
| --- | --- | --- | --- |
| English short, 2.65 s | 0.830 | 0.051 | 0 / 0 of 7 words |
| Russian short, 3.53 s | 0.959 | 0.051 | 0 / 0 of 6 words |
| English long, 49.80 s | 3.347 | 0.234 | 0 / 0 of 132 words |
| Russian long, 51.75 s | 4.460 | 0.283 | 5 / 6 of 108 words |
| Mixed Russian-English | 1.065 | 0.077 | 2 / 2 of 14 words |

Ultra is 13.8-18.9 times faster on these five speech inputs. The direction
holds in both rounds. A case-level sign test favors Ultra on 5/5 inputs,
with two-sided p=0.0625. Repetitions are not independent speakers, and this
small TTS set does not establish a general accuracy ranking or real-speech
latency distribution. The SDK's default ANE policy was tested; no GPU-policy
ablation or quantization comparison was performed for Ultra.

Both models returned identical normalized output hashes on the mixed phrase,
including its two word errors. In every mixed repetition, the required
`release notes` spelling was absent. Both retained GitHub, pull request and
the required Russian term. This is a shared spelling failure against the
synthetic reference, not a demonstrated extra code-switching regression in
Ultra. The long Russian output had one additional normalized word error
with Ultra. All three other speech cases had zero errors in every repetition.
Both models returned empty text on all eight silence passes per model, through
the shared speech gate. No speech case was empty. Thermal states were nominal
for Ultra and nominal or fair for Turbo.

The speedup is much larger than the reduction in CPU time. Warm CPU medians
for the five speech cases ranged from 0.056-1.025 seconds for Turbo and
0.033-0.682 for Ultra. Sampled process physical footprint was 107-163 MB for
Turbo and 83-97 MB for Ultra (decimal MB). Neither figure includes all external
accelerator allocations or establishes peak memory. No battery-life or energy
claim follows from these measurements.

Observed Ultra model loading took 11.060 seconds initially and 0.101 seconds
on the second invocation. Turbo loading took 1.190 and 1.941 seconds after a
separate production-engine preparation lasting 69.555 seconds. A native sample
during that preparation reached `MILCompilerForANE` and `compileModel`.
These are observed cached/preparation events, not a controlled fresh-install
startup comparison. The first inference passes are retained separately.

The model-integrity helper accepted intact ordinary and LFS files and rejected
both a same-size one-byte mutation and truncation, using disposable copies.
A separate six-row check passed through the real Ultra executable: two normal
short-English passes; two passes with one extra required reference word, which
produced one word error and one missing term while retaining the baseline
output hash; and two actually muted inputs, which reached the no-speech path.
The scorer therefore detects the intended changes rather than merely checking
that a report exists. All generated audio was removed.

Verdict: Ultra is a strong candidate for an optional fast dictation model.
Keep Turbo as the default until natural Russian and mixed-language recordings
are compared. The standalone build and the synthetic result justify trying
an app integration, but do not establish parity for microphone capture,
cancellation, long-term residency or caret insertion with a new runtime.
No app catalog, dependency or default was changed by this experiment.

Retained measurement artifacts:

- `.build/diagnostics/parakeet-ultra-comparison-retry/`: metadata, manifest,
  dependency lockfile, build/preparation/per-arm logs, all 96 rows, summary,
  source/executable verification and six-row scorer check.
- `.build/diagnostics/parakeet-ultra/`: runner logs, the preparation sample,
  integrity mutation verdict, summarizer and final app maintenance log.
- `.build/diagnostics/parakeet-ultra-comparison/`: an intentionally cancelled
  setup attempt before inference, retained as failed setup evidence. It was
  stopped to correct the throwing decoder-state initializer before compiling
  the successful harness; it is not a model-quality failure.

The generated build packages, inspection clone and temporary bytecode are
removed after verification. Downloaded model files remain in the separate
cache above for subsequent trials. The app's existing Whisper cache is kept.

## Sources

- [FluidAudio's pinned Ultra guide](https://github.com/FluidInference/FluidAudio/blob/503b4bd1bbf7220882de39fe8ae6716aae4132da/Documentation/ASR/ParakeetUltra.md).
- [Pinned local loader](https://github.com/FluidInference/FluidAudio/blob/503b4bd1bbf7220882de39fe8ae6716aae4132da/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift).
- [Pinned model files](https://huggingface.co/FluidInference/parakeet-ultra-coreml/tree/95eaa59a39d4394f047a4dc5cce480388a60d1b6).
