# Local translation engine

The `Local model` engine (`Provider.local`) translates and rewrites on this Mac
with MLX on Metal, in the app's own process: no CLI, no account, no network once
the model is downloaded. This file records why these models, how the engine is
built, and how it was measured.

Settings keeps the model picker and shows **Manage Models…** beside
its status. The sheet uses `ModelManagementView`, shared with Dictation, to list
all models and download, cancel or confirm removal without changing the selection.
`LocalModelDownloads` reports removal progress and failures in that same list.

## Models

Two 4-bit MLX conversions from `mlx-community`, pinned in `LocalModel`:

| Model | Revision | Download | Peak memory | Minimum Mac |
|---|---|---|---|---|
| TranslateGemma 12B (default) | `f3dcfd54df14` | 6.65 GB | 7.5 GB | 16 GB |
| Gemma 4 E2B | `238767527555` | 3.58 GB | 3.3 GB | 8 GB |

Licenses: TranslateGemma is under the Gemma Terms of Use (gated by manual
approval on `google/translategemma-12b-it`, not on the `mlx-community`
conversion); Gemma 4 E2B is Apache 2.0 at `google/gemma-4-E2B-it` (the
conversion's card says `gemma`). The app downloads from Hugging Face on the
user's request and does not redistribute weights; the Translation pane's footer
names both licenses.

## Benchmark (2026-10-20)

M5, 32 GB, Python `mlx-lm`, the shipping `Translator.systemPrompt` and
`Rewrite.systemPrompt` exported by a temporary test. Fifteen cases, three runs
each: en↔ru and en↔de, a third language, a question, a request, a bare
greeting, a writing style, Rewrite with and without a style and a spoken
self-correction ("на три часа нет на четыре"). Graded by hand.

| Model | Correct of 15 | Median / p90 | Generation | Peak |
|---|---|---|---|---|
| TranslateGemma 12B, app prompt in the user turn | 15 | 3.86 / 4.58 s | 16 tok/s | 7.5 GB |
| Gemma 4 E2B | 13 | 0.57 / 0.74 s | 79 tok/s | 3.3 GB |
| Gemma 4 E4B | 12 | 1.80 / 2.84 s | 33 tok/s | 4.8 GB |
| TranslateGemma 4B | about 7 with the app prompt | 1.31 / 1.57 s | 37 tok/s | 2.4 GB |
| HY-MT1.5 1.8B | weak | 0.69 / 0.92 s | 99 tok/s | 1.2 GB |

- Gemma 4 E2B misplaced the self-correction in all six Rewrite runs ("на три
  часа, не на четыре"), which changes the meaning; the model summary says so.
- Gemma 4 E4B, with a style, returned a literal translation followed by a
  restyled copy in the source language, in all nine runs.
- TranslateGemma 4B with the app prompt echoed the input, answered a greeting,
  translated in the wrong direction and translated Rewrite output; in its own
  template it turned "build fails" into "сборка завершается".
- HY-MT1.5 produced nonsense on the technical sentence, and its license
  excludes the EU, the UK and South Korea, which rules it out for a distributed
  app.
- Reasoning models (Qwen3, gpt-oss) looped in their reasoning without an
  answer in arXiv 2605.31452 and were not run.

Caveats: 15 cases, one style, three languages, graded by one person, not a
metric. Speed was measured in a separate pass; runs that overlapped another GPU
job were left out of the medians. The raw outputs stayed in `/tmp/tlm-bench`
and are not kept.

## Live check of the app's path (2026-10-20)

A temporary XCTest ran the app's own path (`LocalModelFiles`, `LocalEngine`,
WhisperKit's tokenizer, MLX Swift) in a debug build, with the pair written
Russian first and English first, three runs per case. Other jobs kept the load
average at 70 to 180, so its timings are not comparable with the benchmark.

- Gemma 4 E2B downloaded and verified in 251 s; loading from a warm disk cache
  took 3.9 s, TranslateGemma 12B 5.5 s.
- TranslateGemma 12B, Russian first: "The build fails on CI…" came back
  unchanged in 2 of 3 runs; English first, every case was translated. Rewrite
  resolved the self-correction ("на четыре часа") in 6 of 6.
- Gemma 4 E2B, Russian first: "When is the release planned?" came back
  unchanged in 3 of 6 runs, and German came out in English instead of Russian
  in 6 of 6. Rewrite kept "на три часа, не на четыре" in 6 of 6.
- The benchmark wrote every pair English first, so it never took the
  prompt's "every other case" rule for English and missed the echo.
- `Translator.translateLocally` therefore asks once more, with the pair
  reversed, when the output equals the input. With it, TranslateGemma 12B
  translated the technical sentence in 3 of 3 runs (the retry fired twice),
  Gemma 4 E2B the question and the technical sentence in 3 of 3 each.

## Prompt format

`LocalModel.prompt` writes the turn markers by hand, so no Jinja chat template
is needed: TranslateGemma's template refuses a system turn, so the system
prompt opens the user turn (what the benchmark ran); Gemma 4 gets a system turn
and no thinking channel, since its default template starts reasoning instead of
answering. The MLX conversions list only `<eos>`, so generation also stops on
`<end_of_turn>` and `<turn|>` (`LocalModel.stopTokens`); without them a run
continued to the token limit. Control tokens are removed from the selection
before it is placed in the user turn.

The tokenizer is WhisperKit's (`ArgmaxCore`, the Hugging Face tokenizer without
Jinja). On the shipping translation prompt it produced the same ids as Python
`transformers` for both models (389 and 384 tokens, compared id by id,
2026-10-20).

## Runtime

- `LocalEngine` (an actor) keeps one model resident, loads it on the first run,
  frees it ten minutes after the last run (`idleDelay`), on a memory-pressure
  warning when idle, when the model is switched in Settings or removed.
  A pressure notification during generation is remembered until the operation
  drains. Loading, generation and deletion share an exclusive queue across awaits,
  so onboarding checks cannot load a second model or race removal with translation.
  `LocalLoading` hides MLX, so the lifecycle is unit tested with a fake loader
  and an injected sleep.
- Sampling is the benchmark's: temperature 0.3, top-p 0.95. The token limit is
  twice the selection's characters, at least 256 and at most 8192. The SDK's
  `generateTask` producer is awaited even after consumer cancellation, before model
  access is released. Only a normal EOS completion can return text; reaching the
  token limit reports an error instead of inserting a partial translation.
  The cancellation-drain test waits for the producer's cancellation notification.
  Counting `Task.yield()` calls raced the CI scheduler on October 21, 2026;
  yields are not a completion signal. The event proves cancellation propagation;
  the blocked-producer assertion is not a deterministic oracle for removal of
  `await producer.value`, because consumer scheduling can mask an early return.
  A deterministic negative test for that drain remains a coverage gap; production
  still directly awaits the producer before checking cancellation.
- `LocalModelFiles` downloads one file at a time, so progress follows bytes
  (the Hub client weighs each file equally), resumes partial files, refuses a
  download that would leave less than 2 GB free, verifies every file against
  the revision's Hub hashes (`ModelSnapshot`) and then writes a marker. A launch
  checks only the marker and exact sizes.
- `Memory.cacheLimit` is 64 MB, so freed buffers are returned rather than kept
  up to the memory limit.

## Build

`build.sh` uses the native build system, which compiles no `.metal` sources.
`scripts/build-mlx-metallib.sh` builds MLX's kernels with its own CMake recipe
(`MLX_METAL_JIT=ON`) into one `Contents/Resources/mlx.metallib`, shared with
Qwen dictation since both pin the same mlx-swift. MLX looks for that file only
beside the executable, so `MLXKernels.use()` points it there before either
engine loads a model. The JIT kernels are compiled from source at first use and
kept in the system shader cache: the first generation in a fresh binary took
about 5 s instead of 0.4 s, the next process 0.5 s. Without the metallib MLX
fails with "Failed to load the default metallib".

Load times checked 2026-10-20 on a release build with the earlier per-kernel
metallib, before the shared one: Gemma 4 E2B answered a short question in
0.36 s and TranslateGemma 12B in about 2 s after a 2.3-2.5 s load (load average
still above 70).

The [3.7.6 code review](review-3.7.6.md) records the lifecycle regressions and fixes.

The opt-in `LocalModelIntegrationTests` runs both models through the native
`Translator.translateLocally` path, three times in each English/Russian direction,
and checks required synthetic terms and unloading. After `./build.sh`, set
`TLM_LOCAL_CHECK_REPORT` to a JSON output file and `TLM_LOCAL_METALLIB` to
`Translate Like Me Dev.app/Contents/Resources/mlx.metallib`, then run
`swift test --filter LocalModelIntegrationTests`. It uses verified Dev downloads
by default. `TLM_LOCAL_MODELS_BASE` selects an isolated model directory; only
`TLM_LOCAL_CHECK_DOWNLOAD=YES` permits this test to download missing models through
`LocalModelFiles.download`. No microphone, clipboard or user text is involved.
