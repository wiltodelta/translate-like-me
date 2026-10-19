# Local dictation model research

Research snapshot: October 18, 2026. Target: Apple silicon, initially an M5
with 16 GB of unified memory or more. Translate Like Me supports macOS 15+.
This is a feasibility study, not an implementation decision or a local ASR
quality benchmark.

The [minimal dictation plan](dictation-feature-plan.md) defines the current product
scope: one default model and one simple dictation flow. The wider model inventory
below is research, not a requirement to ship multiple engines. The subsequent
[FluidVoice source review](fluidvoice-source-review.md) compares its implemented
dictation flow with this app.
The [Handy source review](handy-source-review.md) adds a concrete `transcribe-cpp`
integration reference and model-lifecycle findings; it is not a model benchmark.

The initial evaluation should compare Qwen3-ASR 1.7B, Parakeet Ultra,
Nemotron 3.5 multilingual, and Whisper large-v3/turbo. Confucius4-R2T2 and
VibeVoice-ASR-Streaming 1.5B deserve a second streaming experiment. GigaAM
Multilingual Large is a useful Russian-focused challenger. MOSS and Omnilingual
remain relevant when broader transcription requirements justify their runtime.
These priorities are engineering judgments for this app, not an accuracy ranking.

English, Russian, and speech mixing both languages are separate evaluation
targets. In particular, NVIDIA says Parakeet v3 is not fully tuned for
code-switching in its [original discussion](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/discussions/1).
Ultra's improvements on monolingual benchmarks do not establish that this
limitation has been resolved.

## Scope and evidence

Coverage includes the major downloadable ASR families encountered in current
upstream catalogs, new streaming releases, Russian specialists, small edge models,
and commonly confused text cleanup or audio chat models. It does not enumerate
every community fine-tune or quantization. API-only transcription services are
outside the downloadable-model selection.

Language and architecture claims below come from the specific checkpoint's model
card, source, or runtime documentation. Registry queries checked public access,
actual artifact names, and file sizes. Published benchmark numbers belong to the
publisher's hardware, decoding settings, normalization, and checkpoint precision.
They are not measurements on the target M5.

## Models for English and Russian

| Family and checkpoint | Relevant capabilities | Local integration and selection judgment |
| --- | --- | --- |
| [Qwen3-ASR 0.6B and 1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) | Both languages among 30 languages plus 22 Chinese dialects. Language detection, context conditioning, offline and streaming inference in the upstream toolkit. | MLX conversions and native Swift implementations exist. Include 1.7B in the quality comparison and 0.6B in the resource comparison. |
| [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | Automatic language detection, punctuation, timestamps, 25 European languages including English and Russian. | Core ML through FluidAudio; retain as the baseline for Ultra and Redux. No proven Russian-English mixed-speech advantage. |
| [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) | Post-trained v3 with the same architecture and languages. | [FluidAudio's comparison](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md) favors Ultra over v3 on the tested English and multilingual sets at similar speed. First compact candidate for dictation finalized after recording. |
| [Parakeet Redux](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetRedux.md) | Ternary v3 derivative emphasizing a small download. | About 220 MB, macOS 15+. Its multilingual mean improves, but English and Russian regress against v3 in the published comparison. Smaller does not mean faster on the Neural Engine. |
| [Nemotron 3.5 ASR Streaming 0.6B](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) | Cache-aware streaming, language prompts or automatic detection, punctuation. Russian and English are in its transcription-ready tier among 40 locales. | Core ML through FluidAudio, MLX, and C++ implementations exist. First candidate for native streaming; measure the selected port's actual buffering delay. |
| [Whisper large-v3 and turbo](https://huggingface.co/openai/whisper-large-v3-turbo) | Broad multilingual transcription. Turbo reduces decoder depth from 32 to four layers, trading some quality for speed. | WhisperKit and whisper.cpp provide Apple silicon paths. Compare both with a multilingual checkpoint; keep them as strong baselines rather than assuming newer models always win. |
| [Confucius4-R2T2](https://huggingface.co/netease-youdao/Confucius4-R2T2) | Qwen3-ASR derivative producing committed, append-only text. Optimized for Chinese and English, with Russian among its additional cross-lingual capabilities. | A documented [C++ Metal path](https://github.com/0xShug0/audio.cpp/blob/main/docs/models/r2t2.md) exists. Promising streaming experiment; Russian quality and the custom weight license need explicit consideration. |
| [Voxtral Mini 4B Realtime 2602](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602) | Native streaming, 13 languages including Russian and English, adjustable delay. | [audio.cpp documents Metal streaming](https://github.com/0xShug0/audio.cpp/blob/main/docs/models/voxtral_realtime.md). It is a larger alternative, not automatically disqualified by the original CUDA serving example. |
| [VibeVoice-ASR](https://huggingface.co/microsoft/VibeVoice-ASR) | Over 50 languages, explicitly stated code-switching support, speaker attribution, timestamps, hour-scale recordings. | The original large model is oriented toward long recordings. Keep it behind smaller dictation candidates for a 16 GB machine. |
| [VibeVoice-ASR-Streaming 1.5B](https://huggingface.co/microsoft/VibeVoice-ASR-Streaming-1.5B) and [7B](https://huggingface.co/microsoft/VibeVoice-ASR-Streaming-7B) | Both list ten languages including Russian and English, live speaker attribution, and hotwords. | A [C++ runtime](https://github.com/0xShug0/audio.cpp/blob/main/docs/models/vibevoice_asr.md) supports both. Evaluate the smaller checkpoint first. The 1.5B name is not the full parameter or memory inventory. |
| [MOSS-Transcribe-Diarize 0.9B](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize) | The card states 50+ languages, long-form transcription, speakers, timestamps, and hotwords; its reported multilingual challenge includes Russian. | Native Swift support is listed in [speech-swift](https://github.com/soniqo/speech-swift). Interesting for recordings and meetings; short dictation latency and Russian accuracy still need their own comparison. |
| [GigaAM Multilingual 220M and 600M](https://huggingface.co/ai-sage/GigaAM-Multilingual) | The released ASR models cover Russian, English, Kazakh, Kyrgyz, and Uzbek. Seventy-plus languages describes encoder pretraining, not equivalent ready-to-use ASR quality. | Official ONNX export plus community Core ML conversions. A Russian-focused challenger with weaker published English performance than Whisper. |
| [Canary 1B v2](https://huggingface.co/nvidia/canary-1b-v2) | ASR in 25 European languages and translation between English and the other languages. Russian is included. | Official NeMo and Transformers inference. Secondary candidate: native integration would need more validation than the available Parakeet path. |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr), including v2 and Unlimited | CTC and LLM variants, over 1,600 languages. Updated v2 checkpoints and long-form Unlimited variants are available from Meta's linked artifacts. | Swift/Core ML/MLX ports exist, but a port's exact checkpoint generation must be verified. CTC and LLM variants have different total sizes and output behavior. Relevant if language breadth becomes a requirement. |
| [Russian-specialized Whisper turbo](https://huggingface.co/coriollon/whisper-large-v3-turbo-russian) | Community fine-tune emphasizing Russian punctuation and conversational audio. | The author explicitly reports degraded English versus vanilla turbo. Consider as a Russian-only experiment; do not silently replace the bilingual baseline. |
| [Vosk](https://alphacephei.com/vosk/models) | Offline recognizers with separate English and Russian models, small CPU-oriented variants and configurable vocabularies in some models. | A useful low-resource baseline, but separate models do not themselves solve recognition of both languages inside one utterance. |

## Modern models with a different scope

| Family or artifact | Reason it is outside the first bilingual comparison |
| --- | --- |
| [Granite Speech 4.0 1B and 4.1 2B](https://huggingface.co/ibm-granite/granite-speech-4.1-2b), including Plus and NAR | The supported ASR list is English, French, German, Spanish, Portuguese, and Japanese. Russian is absent. Translation target languages must not be mistaken for speech input support. |
| [Cohere Transcribe March 2026](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) | Fourteen supported languages, without Russian. Strong English results cannot establish suitability for this bilingual task. |
| [Moonshine and Moonshine Streaming](https://moonshine-voice.readthedocs.io/en/latest/models/available-models/) | The current published STT catalog includes English and several other languages, but not Russian. Russian TTS support in the surrounding toolkit would not change that. |
| [Whistle](https://huggingface.co/Cactus-Compute/whistle) | The recent 16.9 MB model supports seven named languages, without Russian. Interesting for very small English deployments. |
| [Phonon-2](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Phonon2.md) | An English-only quantization-aware Parakeet derivative. Its shared v3 architecture and tokenizer do not restore v3's multilingual capabilities. |
| [Parakeet Unified English](https://huggingface.co/nvidia/parakeet-unified-en-0.6b), [EOU 120M](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml), and v2 | These checkpoints are English-specific. Do not inherit v3's language list from the family name. |
| [Voxtral Mini 3B](https://huggingface.co/mistralai/Voxtral-Mini-3B-2507) and [Small 24B](https://huggingface.co/mistralai/Voxtral-Small-24B-2507) from 2025 | Their named multilingual speech list omits Russian. They are different checkpoints from the 2026 Realtime model. |
| [Canary-Qwen 2.5B](https://huggingface.co/nvidia/canary-qwen-2.5b) | Its checkpoint card explicitly describes English ASR, despite a conflicting broad family row in one NeMo catalog. Canary 1B v2 is the bilingual candidate. |
| [Distil-Whisper distil-large-v3](https://huggingface.co/distil-whisper/distil-large-v3) | English series. It is not a multilingual replacement for large-v3. |
| [Fun-ASR-MLT-Nano-2512](https://huggingface.co/FunAudioLLM/Fun-ASR-MLT-Nano-2512) | The released 31-language list omits Russian. The separately marketed cloud Fun-ASR service has a different language scope. |
| [SenseVoiceSmall](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) | The released checkpoint's inference choices and metadata name Chinese, English, Cantonese, Japanese, and Korean. Broader family claims do not prove Russian support in Small. |
| [GLM-ASR-Nano-2512](https://huggingface.co/zai-org/GLM-ASR-Nano-2512) | Its stated focus is Mandarin, English, Cantonese, and Chinese dialects; Russian is not an established supported target in this card. |
| [FireRedASR2](https://huggingface.co/FireRedTeam/FireRedASR2-LLM) and [X-AuT](https://huggingface.co/XPENG-AI/X-AuT) | Their published focus and evaluations are Chinese/English. A Qwen-derived architecture does not prove retention of all upstream languages after training. X-AuT's checked weights also use CC-BY-NC-4.0. |
| [Higgs Audio v3 STT](https://huggingface.co/bosonai/higgs-audio-v3-stt) | The checked checkpoint is tagged English; Russian support and quality are not established by its use of a Whisper encoder. |
| [Tiron](https://huggingface.co/Trelis/tiron) | A Whisper-derived meeting model with speaker handling. The card allows language tokens, but does not establish comparable Russian dictation performance. Keep it as a meeting-specific investigation. |
| [VibeVoice-ASR-BitNet](https://huggingface.co/microsoft/VibeVoice-ASR-BitNet) | Compact CPU-oriented variant; the explicit language metadata and published rows do not include Russian. Do not inherit the original VibeVoice's full language coverage without validation. |
| [GigaAM v3](https://github.com/salute-developers/GigaAM) and [T-one](https://huggingface.co/t-tech/T-one) | Russian specialists. T-one is a 71M streaming model optimized for telephony; GigaAM v3 has end-to-end normalized-text variants. Neither replaces a bilingual model. |
| [Kyutai STT](https://github.com/kyutai-labs/delayed-streams-modeling) | The released STT variants are English and English/French. |
| [SeamlessM4T v2](https://huggingface.co/facebook/seamless-m4t-v2-large) | Broad speech translation and transcription, including Russian, but the checked weights use CC-BY-NC-4.0. Different product scope and redistribution conditions from the first candidates. |
| [Phi-4 Multimodal](https://huggingface.co/microsoft/Phi-4-multimodal-instruct) | Russian is in the text list, not the audio list. Modality-specific coverage matters. |
| [Audio Flamingo Next](https://huggingface.co/nvidia/audio-flamingo-next-hf) | General audio understanding, sound/music questions, and conversation. Its 8B-class audio chat stack is not the first architecture to add for small desktop dictation; the checked weights also use NVIDIA's OneWay Noncommercial license. |
| [S1-mini](https://huggingface.co/superwhisper/s1-mini) | An English text normalization model, not an audio recognizer. It processes an existing ASR transcript. |

## Published accuracy comparisons

WER is word error rate; lower is better. Read rows only within their stated
experiment. Different reference normalization, corpus versions, filtering,
decoders, and language choices prevent constructing a single ranking by copying
numbers across model cards. WER also omits much of punctuation and formatting
quality important to dictation.

| Publisher and experiment | Comparison | Implication |
| --- | --- | --- |
| [Qwen, 12-language FLEURS subset](https://huggingface.co/Qwen/Qwen3-ASR-1.7B#evaluation), including Russian | Qwen 1.7B: 4.90%; Whisper large-v3: 5.27%; Qwen 0.6B: 7.57% | Supports testing 1.7B separately from 0.6B. This mean is not an isolated Russian score or a score for a quantized Mac port. |
| [GigaAM Multilingual card](https://huggingface.co/ai-sage/GigaAM-Multilingual), filtered/normalized FLEURS | Russian: Large 3.0%, Whisper 3.1%; English: Large 9.4%, Whisper 3.9% | The same model can be competitive in Russian and materially weaker in English. The publisher excludes long utterances and digit-bearing references. |
| [FluidAudio, v3 versus Ultra](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md) | English test-clean: 2.27% versus 2.13%; 24-language FLEURS mean on 100 clips/language: 14.81% versus 11.67% | Supports Ultra as an alternative to v3 in the same runtime. It does not benchmark Russian-English code-switching. |
| [NVIDIA Nemotron 3.5](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b#performance), 1.12-second chunk setting | Russian with language hint: 9.17%; automatic: 10.03% | Language selection changes quality; streaming chunk choices also matter. This is not a comparison with Ultra under the same scoring pipeline. |

Two source interpretation traps affect the newer models. The inspected benchmark
image on the VibeVoice Streaming **1.5B** card actually labels its plotted model
**7B**, so it cannot establish 1.5B performance. MOSS's public evaluation table
primarily concerns meeting transcription and speaker assignment; its challenge
announcement mentioning Russian does not supply a separate Russian short-dictation
score. The MOSS architecture image depicts the audio encoder and autoregressive
speech language model, consistent with its structured transcript output.

## Download sizes and memory

The following sizes were calculated from Hugging Face file metadata on the
snapshot date. They are decimal GB of the selected artifact set, not process RAM,
installer size, a Core ML compilation cache, or all variants in the repository.

| Selected artifact | Size | Selection |
| --- | ---: | --- |
| [Parakeet Ultra Core ML](https://huggingface.co/FluidInference/parakeet-ultra-coreml) | 0.632 GB | Compiled pipeline and its supporting files. |
| [Parakeet v3 Core ML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) | 0.483 GB | `Encoder.mlmodelc`, `Decoder.mlmodelc`, `JointDecisionv3.mlmodelc`, `Preprocessor.mlmodelc`, and vocabulary files. The repository also holds other encoders and source packages. |
| [Parakeet Redux Core ML](https://huggingface.co/FluidInference/parakeet-redux-coreml) | 0.220 GB | Compiled pipeline and its supporting files. |
| [Nemotron 3.5 Core ML](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML) | 0.664 GB | Only `multilingual/1120ms/`, including the fused and separate decoder files distributed in that folder. |
| [Qwen3-ASR 0.6B MLX 4-bit](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-4bit) | 0.713 GB | Weights and supporting files; not only the tensor file. |
| [Qwen3-ASR 1.7B MLX 4-bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit) | 1.608 GB | Weights and supporting files. |
| [Whisper large-v3](https://huggingface.co/ggerganov/whisper.cpp/tree/main) | 3.095 GB / 1.081 GB | `ggml-large-v3.bin` / `ggml-large-v3-q5_0.bin`, respectively. |
| [Whisper turbo](https://huggingface.co/ggerganov/whisper.cpp/tree/main) | 1.625 GB / 0.574 GB | `ggml-large-v3-turbo.bin` / `ggml-large-v3-turbo-q5_0.bin`, respectively. |
| [MOSS original checkpoint](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize) | 1.833 GB | Published weights and supporting files, excluding Markdown and Git attributes. |
| [Voxtral Realtime BF16](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602/tree/main) | 8.859 GB | `model.safetensors` alone. Do not also count the alternate `consolidated.safetensors` representation. Quantized ports have a different footprint. |
| [GigaAM Multilingual Large community Core ML](https://huggingface.co/vadimsuhanov/gigaam-multilingual-large-ctc-coreml) | 2.342 GB | Published FP32 conversion and supporting files. This particular export requires macOS 26+, beyond the app's macOS 15 minimum. |

The selected Hugging Face repositories above reported `gated: false`. Public
availability of an artifact is distinct from successful compilation, inference,
and parity on the target Mac.

Selected artifact revisions for reproducing the inventory:

| Repository | Revision |
| --- | --- |
| `FluidInference/parakeet-ultra-coreml` | `95eaa59a39d4394f047a4dc5cce480388a60d1b6` |
| `FluidInference/parakeet-tdt-0.6b-v3-coreml` | `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe` |
| `FluidInference/parakeet-redux-coreml` | `8c5ef97a29cd120dc76b354b3f22b7fec3b486f9` |
| `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML` | `1a41b75758b0337ff67db7d5408280aaaf23074e` |
| `mlx-community/Qwen3-ASR-0.6B-4bit` | `313d850181767edf09f00a9c289becca70e58cd0` |
| `mlx-community/Qwen3-ASR-1.7B-4bit` | `78a389c776a5483b2d0d4ea5494e11012e0d6159` |
| `ggerganov/whisper.cpp` | `5359861c739e955e79d9a303bcbc70fb988958b1` |

A [speech-swift repeated-request memory probe](https://github.com/soniqo/speech-swift/blob/main/docs/benchmarks/qwen3-asr.md)
on an M5 Pro with 48 GiB measured fixed-version peak process footprints of
2.74 GiB for Qwen 0.6B/4-bit and 4.95 GiB for 1.7B/8-bit. It used repeated
synthetic variations of one fixture, not a language quality corpus. Earlier
cache behavior retained substantially more memory. These figures support
investigating both sizes on a 16 GB machine; they do not guarantee headroom
alongside the user's other applications.

The probe's fixed commit, `5dd31eaa048f945ef21b3a9bbfe7bfb3e0dc6e0a`, is
[15 commits ahead of v0.0.28](https://github.com/soniqo/speech-swift/compare/v0.0.28...5dd31eaa048f945ef21b3a9bbfe7bfb3e0dc6e0a).
That release therefore does not contain this cache fix. Pin and validate the
runtime revision when using these memory figures; the existence of a published
model module alone does not establish equivalent memory behavior.

## Runtime choices and compatibility

| Runtime | Relevant paths | Integration consequence |
| --- | --- | --- |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Native Swift, Core ML, Parakeet family, Nemotron streaming, VAD. | A compact initial experiment can compare Ultra and Nemotron within one SDK. Package traits can omit unrelated TTS and diarization subsystems. |
| [speech-swift](https://github.com/soniqo/speech-swift) | Native Swift modules for Qwen, Whisper, MOSS, Omnilingual, and other models. | macOS 15+ is compatible with the current app target. Pin the exact modules and weight conversion rather than treating every MLX repository as interchangeable. |
| [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) | Native Swift and Core ML Whisper implementation. | An alternative Whisper integration; its artifact size and latency differ from whisper.cpp's GGML files. |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | C/C++, quantization, Metal and optional Core ML acceleration. | Practical baseline with downloadable GGML files. Shipping a helper or bridging C/C++ is an integration choice. |
| [audio.cpp](https://github.com/0xShug0/audio.cpp) | C++/GGML and Metal paths for Qwen, Nemotron, R2T2, Voxtral, VibeVoice, and others. | Broad prototype coverage; backend existence is not evidence that every model is equally mature or has verified Russian parity. |
| [MLX Audio](https://github.com/Blaizzy/mlx-audio) | Python MLX implementations and converted model repositories. | Useful for comparative experiments. A Python prototype does not imply shipping Python with the app. |
| [sherpa-onnx](https://k2-fsa.github.io/sherpa/onnx/) | Offline and streaming models, C APIs, macOS/iOS support. | Useful for ONNX-based Russian specialists. It is a runtime/catalog, not a single ASR model. |

Released-source checks found Ultra's enum case and the multilingual Nemotron
downloader in [FluidAudio v0.17.7](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.7),
and MOSS sources in [speech-swift v0.0.28](https://github.com/soniqo/speech-swift/releases/tag/v0.0.28).
Those checks establish that the paths are present in published tags, rather than
only an unreleased README. They do not replace a build and transcription run.

The [Qwen Swift inference guide](https://github.com/soniqo/speech-swift/blob/main/docs/inference/qwen3-asr-inference.md)
distinguishes its batch model from `StreamingASR`, which splits audio with VAD
and a maximum segment duration. That wrapper does not provide the same incremental
encoder behavior as a cache-aware streaming RNNT. Qwen's upstream toolkit and a
specific Mac implementation therefore need separate streaming evaluations.

For Nemotron, the current [loader source](https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/ASR/Parakeet/Streaming/Nemotron/StreamingNemotronMultilingualAsrManager+Shared.swift)
and the [published artifacts](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML)
supersede the older guide's statement that models are local-path-only. The loader
routes English hints to a Latin-pruned vocabulary; Russian or automatic mode
uses the full multilingual model. The inspected `multilingual/1120ms/metadata.json`
contains `ru-RU` and `ru` prompt IDs and a 13,087-token vocabulary. Use the full
model for mixed Russian/English input even if English is selected as a preference.
The full vocabulary preserves available characters; it does not prove mixed-speech
accuracy. The SDK also records punctuation thinning at its 560 ms tier.

R2T2's C++ documentation describes stable output prefixes but accumulated-audio
re-decoding and buffering limits. Append-only output is a user-facing guarantee,
not proof that compute cost stays constant for arbitrarily long recordings.

## Apple Speech runtime check

A read-only query on the research machine, macOS 27.0.1, returned:

| Query | Relevant result |
| --- | --- |
| `await SpeechTranscriber.supportedLocales` | English locales present; `ru_RU` absent. |
| `await DictationTranscriber.supportedLocales` | `ru_RU` and English locales present. |
| `SFSpeechRecognizer(locale: ru_RU).supportsOnDeviceRecognition` | `false`; the runtime also reported no Russian Assistant asset. |
| `SFSpeechRecognizer(locale: en_US).supportsOnDeviceRecognition` | `true`. |

These are local capability/asset observations, not transcription accuracy tests.
The older recognizer's false result does not establish that Russian assets can
never be downloaded. Supported, installed, and successfully offline-tested are
different states. No speech assets were installed as part of this query.

Apple documents dynamic capability checks in [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
and describes the separate [DictationTranscriber path](https://developer.apple.com/videos/play/wwdc2025/277/).
The macOS 26+ analyzer APIs cannot be the only implementation while the app
supports macOS 15.

## Licenses and distribution

Checkpoint licenses and SDK licenses are separate. The checked Qwen, MOSS,
Voxtral Realtime, and Granite cards use Apache-2.0; Whisper and GigaAM use MIT;
Parakeet v3/Ultra/Redux and Canary v2 use CC-BY-4.0; Nemotron 3.5 uses OpenMDW-1.1.
Retain the relevant model attribution and notices in any implementation.

R2T2's code is Apache-2.0, while its weights have the separate
[NetEase Model Use License Agreement](https://raw.githubusercontent.com/netease-youdao/Confucius4-R2T2/master/MODEL_LICENSE).
Its terms include downstream obligations and restrictions on using it to improve
other models. Do not label the weights Apache-2.0 because the runtime is.
SeamlessM4T v2's checked checkpoint is noncommercial. S1-mini has a naming
condition in addition to its Apache-derived terms. These distinctions affect
which artifacts can be offered as downloads in a distributed app.

## Evaluation before implementation

Use identical recordings and fixed reference spellings for every candidate.
Keep the initial benchmark finite and separate its recording-level groups:

1. Record 30 Russian, 30 English, and 30 mixed utterances, covering short messages
   and 5-60 second dictation, with declared expected spellings for product names.
2. Add ten negative or difficult cases: silence, background sound, long pauses,
   very short words, interrupted speech, and a microphone route change in the
   capture layer. Include a ten-minute recording to check sustained streaming.
3. Score raw ASR and optional cleanup separately. Measure normalized WER/CER,
   English term preservation inside Russian, punctuation, omitted endings,
   repetition, hallucinated text, and manual correction time. Never make
   transliteration disappear through an overaggressive scorer.
4. On the same M5 with 16 GB, measure first launch, warm launch, first partial,
   final text delay after recording stops, physical memory peak, retained memory
   after repeated dictations, and energy use. Match silence thresholds and
   distinguish model inference from capture, endpointing, cleanup, and insertion.
5. Run each timing arm alone, with three warm repetitions per recording. Pin OS,
   app/runtime revision, model revision, precision, language hint, decoder settings,
   VAD policy, and normalization. Compare paired per-recording differences; report
   distributions and a sign test instead of one aggregate speed claim.
6. Compare the exported/quantized candidate against its upstream reference on the
   same recordings. A good BF16 vendor score does not validate a 4-bit conversion
   or a different Core ML decoder.

Initial candidate configurations: Qwen3-ASR 1.7B and 0.6B with explicitly chosen
MLX precision; Parakeet Ultra plus v3; Nemotron full multilingual at 1120 and
2240 ms; Whisper large-v3 and turbo. Add R2T2 and VibeVoice Streaming 1.5B for
live text, and GigaAM Multilingual Large when Russian accuracy warrants the
additional integration. Include MOSS or Omnilingual if the first group leaves a
specific accuracy or language-coverage gap.

Store benchmark recordings outside the repository unless separately cleared for
publication. Keep model selection independent of the existing translation and
Rewrite provider. Local ASR remains offline only through recognition; passing
its transcript to the current provider sends text through that provider's CLI.
