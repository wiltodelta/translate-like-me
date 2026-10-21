# Parakeet Ultra experiment

> Historical record. Parakeet Ultra has been removed from the app at the user's
> request. The measurements below describe the earlier implementation. Current
> behavior and preference fallback are in [local dictation](dictation.md#parakeet-removal).

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

## Post-release quality review, October 20, 2026

The user reported poor Parakeet quality after trying the optional model. The
synthetic speed result above is not evidence against that report. Natural
Russian and mixed-language quality had not been validated at that point. The
natural-speech follow-up below now supplies a limited public-recording test.

Primary-source comparisons reviewed:

- [NVIDIA technical report, Table 11](https://arxiv.org/html/2509.14128v1):
  Russian FLEURS WER is 4.17% for Whisper large-v3 and 5.51% for ordinary
  Parakeet-TDT-0.6B-v3, within that evaluation. This is not an Ultra comparison.
- [Russian STT benchmark](https://github.com/vakovalskii/stt-ru-benchmark):
  775 read-speech, 296 audiobook and 20 spontaneous-speech utterances.
  Reported WER for Whisper Turbo versus ordinary Parakeet v3 is respectively
  4.44/5.56%, 9.89/10.84%, and 7.73/9.27%. The spontaneous-speech intervals
  overlap. Published raw outputs and the scoring harness permit reproduction;
  these results were read, not independently rerun. Most engines use hosted
  endpoints, while Parakeet uses a local RTX 4090. These are not Mac timings.
- [Moondream Ultra model card](https://huggingface.co/moondream/parakeet-ultra):
  Russian FLEURS improves from 5.91% to 5.21% against its own ordinary-v3 arm.
  Both use different runtimes (NeMo versus Photon on NVIDIA), and the card
  cannot establish quality for our Core ML export. Do not compare these
  absolute numbers with NVIDIA's table as though the scorers were identical.
- [FluidAudio Ultra guide](https://github.com/FluidInference/FluidAudio/blob/503b4bd1bbf7220882de39fe8ae6716aae4132da/Documentation/ASR/ParakeetUltra.md):
  reports a Russian improvement of 1.3 percentage points over its own v3 arm,
  but no same-run Whisper or natural mixed-dictation comparison.
- [Qwen3-ASR card](https://huggingface.co/Qwen/Qwen3-ASR-1.7B): 1.7B is a
  candidate, not an established replacement. Its reported FLEURS aggregate
  beats Whisper large-v3 on the 12-language subset (4.90/5.27%) but loses on
  the 30-language subset (12.60/8.16%). Neither is a Russian-specific score.
  [MLX Audio](https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/stt/models/qwen3_asr/README.md)
  provides a local Apple-silicon implementation; latency, export parity and
  integration in this Swift application remain untested.

Recommendation: use existing Large v3 as the immediate quality baseline and
benchmark Qwen3-ASR-1.7B separately before adding another model. Compare real
public speech across Russian, English and mixed speech where a suitable
licensed set exists, with identical normalization, per-item paired errors,
required-term retention, punctuation review and local latency. The small
Latin-token subsets in the Russian benchmark (38 and five utterances) do not
establish code-switching superiority. Do not use the user's recordings without
specific permission or repeat a TTS-only test as a natural-speech quality claim.
No model settings, catalog, code or release changed during this review.


## Natural-speech follow-up, October 20, 2026

A separate local benchmark compared the app's three existing model paths with
Qwen3-ASR 1.7B on the M5 Mac (32 GiB). No app source, model selection, settings,
microphone or user recording was used or changed. This tests the complete ASR
configurations below, not the theoretical quality of each model family.

### Corpus and protocol

- 40 Russian and 40 English read-speech clips from
  [FLEURS, pinned revision](https://huggingface.co/datasets/google/fleurs/tree/70bb2e84b976b7e960aa89f1c648e09c59f894dd)
  (CC BY 4.0). Selection sorts the test filenames by SHA-256 and takes one
  recording per reference sentence ID. One additional clip per language is
  calibration only.
- All 20 test clips from
  [Podlodka Speech, pinned revision](https://huggingface.co/datasets/bond005/podlodka_speech/tree/4a9161485a70ea849ccaa54a72faa9bfc0a60627):
  conversational Russian from four podcast episodes, with some English terms.
  The dataset card does not declare a license; recordings are not redistributed.
- 100 scored clips plus two calibration clips, two fresh-process rounds per
  model, 816 total recognitions. The second round reverses model order. Model
  inference is serial. Repeats assess stability, not additional independent data.
- All arms receive shared mono 16 kHz audio after the production Silero speech
  gate, minimum one-second padding and a half-second silence tail. No clip was
  rejected. Language is automatic, without prompts, hotwords or forced language.
- WER is aggregate substitutions + insertions + deletions divided by reference
  words within each corpus: 758 Russian, 913 English and 1,165 podcast words.
  Unicode normalization ignores case and punctuation and equates Russian ё/е;
  it does not equate spelled-out numbers with digits. Punctuation accuracy was
  not graded. There is no pooled score across these different domains.

Whisper uses the app's pinned WhisperKit 1.1.1 and Core ML exports (Large v3
947 MB variant; Turbo 626 MB variant), CPU/Neural Engine allowed for encoder
and decoder, and production transcript cleanup. Ultra uses the pinned
FluidAudio 0.17.7 path and model revision already documented above, with fresh
decoder state for each clip. Qwen uses
[the pinned MLX 8-bit export](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit/tree/a8379a2e2f9e313c9292cdf1af4055ab56d50d55),
mlx-audio 0.6.1, greedy decoding, a 1,024-token limit, and synchronization around
inference. Its weights file is 2,463,307,541 bytes. This is not a full-precision
Qwen comparison. Source hashes, SDK object hashes and package pins identify
the actual standalone build against app commit `8aa5410`.

### Quality

First-round WER, percent; lower is better:

| Model | Russian reading, 40 | English reading, 40 | Russian conversation, 20 |
|---|---:|---:|---:|
| Qwen3-ASR 1.7B, MLX 8-bit | 2.64 | 3.83 | 7.98 |
| Large v3, app Core ML export | 4.88 | 5.91 | 10.30 |
| Turbo, app Core ML export | 5.41 | 7.01 | 7.98 |
| Parakeet Ultra, app Core ML export | 2.90 | 6.24 | 7.38 |

In round two, Qwen and Ultra retained every normalized scored transcript.
Large v3 changed three of 100: WER became 4.49%, 5.81% and 10.30% respectively.
Turbo changed six: 5.80%, 6.79% and 8.07%. No first-round output was empty.

Qwen has the lowest observed reading WER. Its Russian difference from Ultra
is only two errors (20 versus 22), with seven utterance wins and six losses,
so this sample does not establish superiority over Ultra in Russian. English
paired sign tests favor Qwen against each alternative (unadjusted p values
0.012, 0.0015 and 0.0072 against Large, Turbo and Ultra); these remain exploratory
comparisons on a small selected corpus, without a speaker-cluster analysis.

Ultra has the lowest observed podcast WER, seven errors fewer than Qwen.
The 20 clips cover only four episodes; the episode-cluster Qwen-versus-Ultra
bootstrap interval crosses zero, as does the Qwen-versus-Turbo interval.
Episode sign tests do not establish a conversational winner. Large v3 did not
lead in any of these three groups under the app's current configuration.

Technical spelling remains a problem for every arm. Five podcast clips contain
24 Latin reference-word occurrences. Strict normalized spelling missed 14 for
Qwen, 16 for Large, nine for Turbo and eight for Ultra. These are occurrences,
not 24 distinct terms, and five clips cannot establish code-switching quality.
For example, Qwen wrote Russian phonetic forms for both occurrences of
`observability`, while Turbo retained the Latin spelling in that clip. A good
reading WER therefore does not establish suitability for the user's mixed
Russian/English dictation. Microphone startup, live personal speech, punctuation
and caret delivery are outside this test.

### Timing and verification

The Mac was heavily loaded by unrelated work throughout the measurement.
A saved instantaneous sample during the accepted run showed only 4% CPU idle
and a load average of 129.31. Runs were serial at nice 6, but reversing model
order cannot remove changing external contention. These figures describe this
busy-machine run; they are not clean M5 performance or energy estimates.

Median inference seconds, computed from each clip's two-run median, excluding
model loading, calibration and shared audio preparation:

| Model | Russian reading, median audio 11.58 s | English reading, 10.11 s | Conversation, 21.67 s |
|---|---:|---:|---:|
| Qwen3-ASR 1.7B | 7.99 | 5.47 | 16.10 |
| Large v3 | 9.87 | 7.09 | 19.96 |
| Turbo | 2.97 | 2.30 | 5.09 |
| Parakeet Ultra | 1.16 | 1.03 | 2.38 |

Qwen is a useful separate quality candidate, especially for English reading,
but this run does not justify replacing the default or promising faster
interactive dictation. Ultra's good aggregate result also does not invalidate
the user's poor experience on different speech.

The reproducible entry points are `scripts/benchmark-natural-asr.py` and
`scripts/NaturalASRBenchmark.swift`. The diagnostic evidence is retained locally
in `.build/diagnostics/natural-asr-comparison/`: corpus provenance, pinned model
manifests, source/build hashes, both rounds' metrics, paired comparisons,
scorer mutation checks, logs, dependency freeze and the exact executed recipe.
Setup failures and a lower-priority partial pilot are excluded from the scores.
No audio, weights or full recognition output is committed to the repository.

Post-run verification matched the downloaded weights, tokenizers and Silero
files against pinned registry hashes. Swift and Python consumed bit-identical
float32 PCM for all 102 clips, with no duplicate PCM hashes. The native
benchmark's hash and signature passed verification. Mutating a registry-checked
file in a disposable copy rejected both same-size corruption and truncation;
mutating a Russian hypothesis through the real aggregation seam increased WER
from zero to 50% and left the other model unchanged. All eight raw reports
contain exactly 102 outputs. The app's Ultra cleanup would leave their scored
words unchanged. Temporary public audio, Qwen weights, environments and native
build products are removed after these checks; existing app model caches are
preserved. Full public recognition outputs remain only in the ignored local
evidence folder, alongside the recipe needed to audit their scores.


After app removal, standalone comparison packages retain their own explicit
FluidAudio 0.17.7 pin. They no longer link the app's cached release objects;
`benchmark-natural-asr.py` uses the shared isolated SwiftPM comparison build.
The executed cached-object recipe and original source hashes remain in the
ignored evidence folder. This harness adjustment does not replace the measured
run or change its scores.
