# Local model candidates (October 22, 2026)

> Research snapshot. The shipping catalog is in [dictation](dictation.md) and
> [local translation](local-translation.md); nothing here changed it.

A follow-up to the [dictation survey](dictation-research.md) and the
[local translation benchmark](local-translation.md): what changed upstream
since October 18, and live measurements of the candidates that could replace or
improve the shipping models. No app source, setting, model download or
installed app was changed. Nothing here is a product decision.

## Dictation

### Upstream, October 1-22

A pass over every Hugging Face model tagged speech recognition created since
October 1 found no new checkpoint that recognizes both Russian and English.
New releases were English-only or other languages (Granite Speech 5.0 2B:
en/fr/de/es/pt/ja; Ming-3.0-asr-tiny: zh/en). Relevant changes to known models:

- llama.cpp gained Voxtral Mini 4B Realtime ([PR 30629](https://github.com/ggml-org/llama.cpp/pull/30629),
  merged October 15; [GGUF](https://huggingface.co/ggml-org/Voxtral-Mini-4B-Realtime-2602-GGUF)
  Q4_K_M 2.55 GB plus a 1.06 GB audio projector). A streaming route, if partial
  text during recording ever becomes a requirement.
- [Voz](https://huggingface.co/desert-ant-labs/voz) repackages Parakeet v3 for
  Core ML under a source-available license that needs a commercial license at
  scale.
- mlx-audio 0.6.x added a uniform `hotwords` parameter; mlx-audio-swift 0.1.6
  has no Qwen3-ASR changes.

Apple's engines remain out ([locale check](dictation-research.md#apple-speech-runtime-check)):
the one published FLEURS comparison
([WhisperNotes](https://whispernotes.app/blog/apple-speech-vs-whisper), macOS
27.0) puts `DictationTranscriber` at 13.83% en / 13.13% ru WER against Whisper
Turbo's 5.49% / 5.13%.

### Qwen3-ASR size, precision and context

Same 100 scored clips as the [October 20 comparison](parakeet-ultra-experiment.md#natural-speech-follow-up-october-20-2026)
(the selection is a fixed hash order over pinned dataset revisions), same
normalization and WER definition, Python mlx-audio 0.6.1, greedy, automatic
language, one round per arm. Padding approximates the production speech gate
(one-second minimum, half-second tail). The 8-bit 1.7B anchor reproduced its
October 20 scores exactly, so the rows are comparable with each other.

| Arm | Download | Peak | Russian reading | English reading | Russian podcast |
|---|---:|---:|---:|---:|---:|
| 1.7B 8-bit (shipping) | 2.47 GB | 3.89 GB | 2.64 | 3.83 | 7.98 |
| 1.7B 4-bit | 1.61 GB | 3.03 GB | 3.43 | 4.27 | 9.18 |
| 0.6B 8-bit | 1.01 GB | 2.39 GB | 6.86 | 5.37 | 11.93 |
| 0.6B 4-bit | 0.71 GB | 2.09 GB | 12.14 | 5.91 | 71.50 |
| Turbo, app Core ML (Oct 20, not paired) | 0.63 GB | - | 5.41 | 7.01 | 7.98 |
| 1.7B 8-bit, fixed glossary | same | same | 2.37 | 3.83 | 8.24 |
| 1.7B 8-bit, clip's own Latin terms | same | same | 2.64 | 3.83 | 7.21 |

WER in percent; peak is MLX's peak allocation in the Python process, not the
app's footprint.

- **0.6B 4-bit is broken**, not merely weaker: two podcast clips returned only a
  misspelled language prefix ("language Рускый"), and one looped to
  464 words on a 140-word reference. In the app the repetition backstop would
  turn the loop into an error.
- **0.6B 8-bit does not replace Turbo**; against the 1.7B it was worse on 22 of
  40 Russian reading clips and better on 2.
- **1.7B 4-bit**: against the 8-bit it was worse on 8 Russian clips and
  better on 4. It is the only candidate for the 16 GiB tier, and needs a paired
  run with Turbo in the Swift runner (memory, latency, the app's speech gate)
  before it can be weighed.
- **Context biasing works for the words it names.** Qwen3-ASR reads the system
  turn as background text ([technical report](https://arxiv.org/abs/2601.21337);
  official template: `<|im_start|>system\n{context}<|im_end|>`). Passing each
  podcast clip's own Latin-script terms (the oracle upper bound) raised their
  recall from 6 to 11 of 16; two clips improved, none got worse, and no arm
  returned an empty transcript. A fixed 14-term glossary of
  this project's names, none of them spoken, changed one Russian reading clip
  for the better and two podcast clips for the worse. An
  [English study](https://arxiv.org/abs/2608.05759) found 10 unrelated words
  harmless and 250 harmful. An earlier
  [instruction-style context](dictation-language-detection.md#synthetic-investigation)
  ("preserve the original language") was rejected for adding empty results;
  named terms are a different input. The Swift package already takes it:
  `Qwen3ASRModel.buildPrompt(numAudioTokens:context:language:)`; on October 22
  the app passed no context.
- Timing is not reported: a 12 GB download ran during these arms, and the
  context arms looked slower in a way 14 words of prompt cannot explain.

## Translation and Rewrite

### Candidates checked

| Model | License | Russian | Fit for this app |
|---|---|---|---|
| [Hy-MT2 7B / 1.8B](https://huggingface.co/tencent/Hy-MT2-7B) (May 2026) | Apache-2.0, no territorial clause | listed | MT-specialized; measured below |
| [Gemma 4 12B](https://huggingface.co/google/gemma-4-12B-it) (May 2026) | Apache-2.0 | 35+ languages, Russian not named | `gemma4_unified`, which mlx-swift-lm 3.32.3 loads only through MLXVLM; ships a 0.27 GB MTP draft model; measured below |
| [Index-Translate 9B / 2B](https://huggingface.co/IndexTeam/Index-Translate-9B) (Sep 28) | Apache-2.0 | card says 150 languages; Russian not confirmed | Card claims FLORES COMET-22 0.8789 against TranslateGemma 12B's 0.8732; Qwen3.5 hybrid attention, no mlx-community conversion; not measured |
| Apple Translation | system | installed en→ru, en→de here | No style or instructions, so translation only; a UI-less `TranslationSession` needs macOS 26 |
| Apple Foundation Models | system | **no**: 24 languages on macOS 27, none Russian | Out |
| Tower+, tiny-aya, North-Small-Translate | noncommercial | | Out |

### Benchmark

Fifteen new synthetic cases (the October 20 set was not kept): eleven
translations (en↔ru with a Russian-first pair, en↔de, a German input to a
Russian/English pair, a question, a request, a greeting, a paragraph, two
styled) and four Rewrites (Russian and English self-corrections, a question
for the recipient, a formal style). Three runs each, the app's
`Translator.systemPrompt` and `Rewrite.systemPrompt` ported verbatim, Python mlx-lm 0.32.2 and
mlx-vlm 0.7.10, the app's sampling (0.3 / 0.95; Hy-MT2 its card's 0.7 / 0.6 /
top-k 20), M5 32 GB. Graded by hand: a case passes when all three runs keep the
direction and meaning, neither answer nor echo, add nothing, and keep only the
correction. Style strength is not graded. The `native` Hy-MT2 rows translate
with the model card's own instruction and the correct target supplied, as an
app-side language detector would; their Rewrites use the app prompt.

| Arm | Translation, of 11 | Rewrite, of 4 | Median / p90 | Peak |
|---|---:|---:|---|---:|
| TranslateGemma 12B (shipping) | 10 | 2 | 3.67 / 5.35 s | 7.5 GB |
| Gemma 4 E2B (shipping) | 7, plus 2 echoes the app retries | 2 | 0.49 / 0.83 s | 3.3 GB |
| Gemma 4 12B | 8 | 4 | 5.01 / 9.04 s | 7.6 GB |
| Hy-MT2 7B, app prompt | 3, plus 1 echo | 2 | 2.46 / 3.82 s | 4.8 GB |
| Hy-MT2 7B, native | 9 | 2 | 1.76 / 4.40 s | 4.8 GB |
| Hy-MT2 1.8B, native | 5 | 0 | 0.48 / 1.02 s | 1.7 GB |

Python timings without the app's [prompt-head reuse](local-translation.md#reused-instructions-2026-10-22), so TranslateGemma's
first token (median 2.25 s) is mostly prefill the app no longer repeats.

- **TranslateGemma 12B** reordered the English CI sentence into a different
  claim ("Завтра утром я очищу ... сборка перестанет выдавать ошибки") in 3 of 3
  runs, turned "смержу" into "проверю", and opened the formal Rewrite with
  "Pete,", a recipient the notes never name, taken from the prompt's own
  example, in 3 of 3.
- **Gemma 4 E2B** repeated the [October findings](local-translation.md#benchmark-2026-10-20): English sentences echoed under
  a Russian-first pair, German came out in English, the self-correction kept
  both times ("в три часа нет, в четыре"), "Пети," in the wrong case.
- **Gemma 4 12B** wrote the best Rewrites (all four, including "Возьми с собой
  отчёт" where others kept "Пусть возьмёт"), but looped in empty thought
  channels on the German input in 3 of 3 runs and, given a style, returned the
  styled translation followed by a copy in the other language in 5 of 6. The
  app's hand-written Gemma 4 turn format gave the same result. Both failures
  are the shape Gemma 4 E4B showed in October.
- **Hy-MT2 7B** does not follow the app's direction rule: under the app prompt
  English stayed English, paraphrased, so the echo retry cannot catch it.
  Its Rewrite translated the English notes into Russian and invented "Марк"
  from the prompt's example. With the target supplied it translates well and
  twice as fast as TranslateGemma, but with grammar errors ("на следующую
  четверг" 3 of 3) and "Abrechnungskodex" for billing code.
- **Hy-MT2 1.8B** produced broken Russian ("Я очистим", "Четвернойкальные") and
  nonsense Rewrites.

### Speculative decoding

TranslateGemma 12B, Gemma 3 270M and TranslateGemma 4B share one
`tokenizer.json`. Greedy, two interleaved rounds of the fifteen prompts: a 270M
4-bit draft was faster in 19 of 30 pairs with 2 draft tokens (median speedup
1.03×) and 9 of 30 with 3 (0.95×); 36% of tokens came from the draft. The
paragraph came out reworded in all four of its draft runs; every other draft
run matched the plain output. Not worth adding.

mlx-swift-lm 3.32.3, pinned on October 22, also has `MTPSpeculativeTokenIterator`
and a `gemma4_unified_assistant` drafter for Gemma 4 12B; its
[PR 415](https://github.com/ml-explore/mlx-swift-lm/pull/415) reports about 62%
acceptance and 1.59× on the 31B. Not measured here.

## What this suggests

- Dictation, above 16 GiB: keep Qwen3-ASR 1.7B 8-bit; 0.6B 4-bit is unusable.
- Dictation, 16 GiB and below: Qwen3-ASR 1.7B 4-bit is the one candidate
  against Turbo; it needs the paired Swift-runner comparison first.
- An optional user vocabulary passed as Qwen context is the cheapest measured
  quality gain: a one-argument change, with an effect limited to the words it
  names. Keep it short; whether a long list costs latency is unmeasured.
- Translation: no candidate replaces TranslateGemma 12B as one model for both
  jobs. Hy-MT2 7B would need app-side direction detection and a second model for
  Rewrite. Gemma 4 12B is the one worth another round, with its MTP drafter and
  a prompt that stops the duplicate styled copy and the third-language loop.
- The shipping prompts have failures of their own: TranslateGemma's formal
  Rewrite takes the example's name, and both shipping models alter meaning in
  single cases. Prompt changes need the live XCTest check described in
  `CLAUDE.md`.

Caveats: one style per direction in translation. The ASR corpus is read speech plus 20 podcast clips; code-switched Russian-English
speech has no public benchmark for these models
([CS-FLEURS](https://arxiv.org/abs/2509.14161) evaluates Whisper only).
Transcripts, outputs and summaries are kept outside the repository under
`~/.local/state/agent-artifacts/translate-like-me/local-model-candidates-2026-10-22/`.
