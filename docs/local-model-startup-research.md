# Local inference optimization research

October 25, 2026. External-source follow-up to the
[startup measurements](local-translation.md#startup-preparation-october-25-2026).
The source survey below records the initial hypotheses; the final section
records the subsequent native experiments and supersedes their prioritization.
The machine identifies itself as Apple M5, with 32 GiB RAM. No additional
runtime optimization was adopted after these experiments.

The inspected dependency checkouts are clean and match `Package.resolved`:
MLX Swift 0.32.3, MLX Swift LM 3.32.3, MLX Audio Swift 0.1.6. Recommendations
below distinguish implementation opportunities from measured improvements.

## Highest-priority experiment: fuse the actual Gemma VLM decode path

Upstream [PR 249](https://github.com/ml-explore/mlx-swift-lm/pull/249)
combines residual-add/RMSNorm and GELU/multiply operations through `compile()`.
Its author reported 23.8% higher median decode throughput on Gemma 4 E2B 4-bit,
M4 Max, after excluding warm-up. This is another model and machine, not an
expected speedup for this app.

The relevant distinction is visible in our exact dependency revision:

- [MLXLLM Gemma4Text.swift](https://github.com/ml-explore/mlx-swift-lm/blob/3b339ad6e3b3f44c8121ecff5131c7fd55e075e6/Libraries/MLXLLM/Models/Gemma4Text.swift)
  already has `_addRMSNorm` and `_geluMul` compiled helpers.
- [MLXVLM Gemma4.swift](https://github.com/ml-explore/mlx-swift-lm/blob/3b339ad6e3b3f44c8121ecff5131c7fd55e075e6/Libraries/MLXVLM/Models/Gemma4.swift)
  executes those corresponding operations separately in its text backbone.
- `LocalModel.loadsThroughVLM` and `MLXLoader.load` route our selected Gemma 4
  12B through `VLMModelFactory`; its `gemma4_unified` registration constructs
  `Gemma4Unified`. Applying a change only to the LLM implementation would miss
  this production path.

A candidate should bring equivalent small fusions into the VLM text backbone,
preserving its normalization, scalar handling and MTP state. Do not simply
switch factories or assume both model implementations are interchangeable.
Measure warm full-answer latency, first-token latency and decode throughput,
with the current drafter and prompt-head cache enabled. Verify output and
meaning against the unchanged arm, including direction, writing styles and
Rewrite self-corrections.

MLX's [compilation documentation](https://github.com/ml-explore/mlx-swift/blob/main/Source/MLX/Documentation.docc/Articles/compilation.md)
explains fusion, initial compilation cost and retracing on shape changes.
Compiling an entire mutable decoder needs explicit state handling; small pure
fragments are a narrower first experiment. Do not infer a whole-model speedup
from an elementwise microbenchmark.

## Memory experiments: buffer reuse before stronger residency policies

[MLX Memory](https://github.com/ml-explore/mlx-swift/blob/main/Source/MLX/Memory.swift)
distinguishes live arrays from reusable freed buffers. It recommends measuring
cache sizes: a larger pool is not universally faster.

Our loader limits the shared pool to 64 MiB; `DictationQwen` clears it after
warm-up and each transcription. The pinned Metal allocator's `clear_cache()`
clears `buffer_cache_`, not model weights, prompt KV state or Metal shader
pipelines. Keeping weights resident therefore does not settle buffer reuse.

Compare the existing policy with bounded pool sizes such as 256 and 512 MiB,
with and without per-utterance pool clearing. If several changes are combined,
separate their contributions. Record latency, active/cache/peak allocation,
process footprint, memory pressure and whether translation weights get evicted
while alternating translation and dictation. Revert a policy whose extra pool
memory causes reloads. These are experimental settings, not recommended new
defaults.

The pinned SDK also provides
[wired-memory policies and tickets](https://github.com/ml-explore/mlx-swift/blob/main/Source/MLX/Documentation.docc/Articles/wired-memory.md).
The app currently uses no wired-memory ticket. A shared policy could coordinate
translation and Qwen budgets, bounded by the device's recommended working set.
Reservation tickets do not keep the wired limit elevated while idle. Raising a
limit is not proof that weights stay resident or a substitute for handling
system pressure. This is lower priority unless memory traces demonstrate a
relevant limit or paging problem; do not change the system-wide `sysctl` as a
first step.

## Dictation: overlap recognition with the hold

The current controller waits for the WAV to drain after release before
recognition. Processing already captured audio during the hold is the main
architectural candidate for reducing the remaining wait after release. Keep
capture limited to the existing hold and insert only one finalized result.
Cancellation must discard provisional work. An evicted-model case must still
start capture without waiting for a reload.

The official [Qwen3-ASR implementation](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/inference/qwen3_asr.py)
has `init_streaming_state`, `streaming_transcribe` and finalization. Its current
implementation is vLLM-only, re-feeds accumulated audio and revises a suffix of
previous text. It is a reference algorithm, not a ready Swift/MLX integration
or proof of efficient cached audio encoding.

The pinned [Swift Qwen implementation](https://github.com/Blaizzy/mlx-audio-swift/blob/a5506c1c7978aeea9a3295f83d43beff3f06bcdf/Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift)
accepts a complete `MLXArray` in `generateStream`; that streams output tokens,
not incoming microphone audio. It exposes `encodeSingleWindow`, but that alone
does not establish end-to-end streaming correctness. Encoder reuse, acoustic
context and text revisions need their own implementation and accuracy checks.

[Whisper-Streaming](https://arxiv.org/abs/2307.14743) likewise treats stable
partial text as a separate algorithm, using local agreement. Its published
latency is not a prediction for our short utterances or M5. Evaluate final
word preservation, silence, multilingual changes and cancellation, together
with release-to-final-text latency and sustained compute cost.

## Options that are not automatic wins

- **More speculative tokens:** Gemma 4 12B already uses its MTP drafter with
  block size 3, previously compared with 4 in the
  [candidate measurements](local-model-candidates.md). Re-measure acceptance
  and full latency if another optimization changes that balance.
- **KV quantization:** the current
  [MTP iterator](https://github.com/ml-explore/mlx-swift-lm/blob/3b339ad6e3b3f44c8121ecff5131c7fd55e075e6/Libraries/MLXLMCommon/MTPSpeculativeTokenIterator.swift)
  can fall back to single-token decoding when quantized shared KV state no
  longer supports its drafter. Memory savings can lose speculative throughput.
- **Persistent prompt caches:** supported by
  [MLX LM](https://github.com/ml-explore/mlx-lm#long-prompts-and-generations),
  but they primarily save repeated prefill after loading. They do not remove
  warm token generation or loading the weights. Cache compatibility must include
  the exact model, tokenizer, prompt and KV representation.
- **A smaller Qwen or lower precision:** prior paired app-path tests already
  found accuracy losses in Russian; see
  [model candidates](local-model-candidates.md#paired-app-path-run-turbo-and-qwen-8-bit-and-4-bit).
  This changes the quality tradeoff and is not a default optimization.
- **A newer backend or M5 kernel tweak:** upstream
  [issue 4720](https://github.com/ml-explore/mlx/issues/4720) reports a dispatch
  problem for specific shapes and explicitly excludes M=1-4 from its proposed
  change. It is not evidence that our MTP block-3 decoding is affected. Capture
  the actual model's Metal kernels before attributing latency to this issue.

## Scope and evidence limits

Apple's Core ML performance article was read as publisher-provided Markdown;
its seven referenced report screenshots returned HTTP 404 at the URLs in the
publisher JSON and were not inspected. No screenshot-derived timings or
placement claims are used here. Core ML-specific caching is background context
for Turbo; the selected Qwen and translation models use MLX.

External sources alone establish no acceleration factor for this machine.
The following experiments tested the VLM fusion and bounded buffer-pool
hypotheses. Overlapping dictation with recording is a larger architectural
change and was not part of these two experiments.

## Native experiment results (October 25, 2026)

**Decision: retain the existing runtime policies.** Neither VLM fusion nor a
larger or retained allocation pool demonstrated a consistent latency advantage
on this busy M5. This does not establish that either optimization is universally
slower, nor does it measure an idle machine.

Each comparison ran serially within an instrumented release build at
`096faa8179d4babf46e1afa118fb1bad29043a34`, with the pinned dependencies above.
The temporary XCTest command was `swift test -c release --arch arm64
--build-system native -Xswiftc -enable-testing --filter <probe>`; subsequent
runs used `--skip-build`. Models came from APFS clones of the installed caches.
No microphone, clipboard, network download or user text was involved. The SDK
patch and probe files lived only in a locked disposable worktree. Pre-run
one-minute load averages were 13.15-26.25, and device utilization readings were
41-59%; these are whole-machine readings, not per-process GPU measurements.
The receipts include sampled load and process RSS during each comparison.

### Correct sampling and the inactive GELU branch

The first pilot used `MLXRandom.seed`, which does **not** seed this SDK's
`TopPSampler`: it constructs its own `RandomState`. An unchanged buffer-pool
arm returning different text exposed the problem. Those pilot and unseeded
runs were excluded. Final translation comparisons pass the same seed into
`GenerateParameters.seed` for each case/repetition, retaining production
`temperature: 0.3`, `topP: 0.95`, MTP block 3 and the three instruction heads.
Each process first verifies two identical seeded requests return identical
text. Do not infer a numerical or quality regression from the discarded
stochastic outputs.

Runtime tracing and the actual 12B `text_config` also ruled out the proposed
GELU fusion: `hidden_size_per_layer_input` is zero, so its branch is never
called. RMSNorm fusion was exercised in the shared text decoder used by the
48-layer target and its assistant. Only that active change was compared in
the final fusion run; there were no two active changes to attribute.

### Warm translation and Rewrite

Eight synthetic cases, three repetitions each, cover both English/Russian
directions, informal style, names, times, a URL, and English/Russian Rewrite
self-corrections. Translation uses `Translator.translateLocally`; Rewrite
uses its production system prompt through `LocalEngine.complete`. Arms rotate
order by case and repetition. Models and all three instruction heads are
prepared before timing. Timings end after the SDK producer drains and exclude
selection, capture and paste delivery. The model remained resident throughout.

Positive reductions below mean less waiting than the control. They are medians
of **paired differences**, not differences between unpaired arm medians.

| Candidate versus control | Pairs | Median waiting reduction | Faster pairs | Two-sided sign p |
|---|---:|---:|---:|---:|
| RMSNorm fusion versus separate operations | 24 | -288 ms | 8/24 | 0.152 |
| 256 MiB pool versus 64 MiB | 24 | -116 ms | 10/24 | 0.541 |
| 512 MiB pool versus 64 MiB | 24 | -246 ms | 8/24 | 0.152 |

The fusion run's median paired decode-throughput change was -13.5%. Case-level
median reductions favored fusion in 2/8 cases (sign p = 0.289). Larger pools
favored 4/8 and 2/8 cases respectively. These noisy loaded-machine results do
not justify any of the changes.

All 24 paired fusion answers matched exactly, as did every paired answer in
the pool comparison. Generated-token counts, accepted/proposed draft counts
and passthrough status also matched each control; MTP never entered
passthrough. This verifies equivalent work on these fixtures, not general
translation accuracy. The sampled decoder can still duplicate a translation;
that existing behavior appeared in both arms.

### Qwen allocation pool: full factorial comparison

Two synthetic `say` AIFF clips, Samantha English and Milena Russian, went
through `DictationEngine.transcribe`, including audio loading, speech gating,
normalization and padding, with language identifiers `["en", "ru"]`. Six
rotating repetitions crossed three pool limits with clearing or retaining
buffers after transcription. Each policy received an untimed preceding
utterance. There were 72 timed transcriptions, 12 per policy, and 72 preceding
utterances. Loading and the existing silence warm-up were outside timing.
Translation was not resident in this comparison.

| Policy versus 64 MiB with clearing | Pairs | Median waiting reduction | Faster pairs | Two-sided sign p |
|---|---:|---:|---:|---:|
| 256 MiB, clear | 12 | -73 ms | 4/12 | 0.388 |
| 512 MiB, clear | 12 | -13 ms | 4/12 | 0.388 |
| 64 MiB, retain | 12 | -29 ms | 5/12 | 0.774 |
| 256 MiB, retain | 12 | +19 ms | 8/12 | 0.388 |
| 512 MiB, retain | 12 | +12 ms | 7/12 | 0.774 |

The factorial contrasts also fail to establish a retention effect: retaining
versus clearing at 64/256/512 MiB reduced waiting by medians -29/+58/+43 ms,
with 5/7/8 of 12 pairs faster (sign p = 0.774/0.774/0.388). Increasing a
retained pool from 64 to 256/512 MiB gave -17/+52 ms (4/8 of 12 pairs faster,
p = 0.388/0.388). Comparisons are exploratory and unadjusted for multiplicity;
there are only two speech fixtures. All transcripts matched their controls
exactly. Retained allocator pools occupied approximately their configured
64/256/512 MiB, so the memory cost was observable without a reliable speedup.
No new policy was selected, and no joint-residency rollout was performed.

### Retained evidence and limits

The three final live tests passed, with zero skips and failures: 48 timed
fusion requests, 72 timed translation-pool requests and 72 timed Qwen requests,
192 measurements total. All finite jobs finished. Probe sources, patches,
synthetic clips, raw results, load samples, build logs and discarded pilot
receipts are retained outside Git under
`~/.local/state/agent-artifacts/translate-like-me/local-optimizations-20261025-26mjvxh/`,
with a review deadline of November 24, 2026; that date does not authorize
automatic deletion. The disposable worktree, model clones and temporary
binaries were removed. The original SDK checkout remained clean.

These trials cover warm inference only. They do not remove weight loading,
actual token generation, the dictation release tail or paste delivery. The
previously implemented background translation preparation remains the verified
startup improvement; its timings are in [local translation](local-translation.md#startup-preparation-october-25-2026).
