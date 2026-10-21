# Short-utterance language detection

Implementation status: a shared translation-language preference now applies to
all four offered dictation models. The earlier sections retain the research
history; implementation behavior and validation are recorded below.

## Report and current behavior

On October 21, 2026, the user reported that Qwen3-ASR transcribed Russian
`делай` as Chinese `叫。`, with language mistakes occurring more often on short
phrases. This is the reported spoken word and returned text, not a recording.
The production preference on this Mac selected `qwen3ASR`. The user later
clarified that similar short-phrase language mistakes occur with other models
and that Qwen remains their preferred model. Model replacement is not the
requested remedy.

`DictationQwen` currently calls `buildPrompt(numAudioTokens:)` with no context
or language. The model generates its own language prefix, which
`DictationQwenDecoding.transcript` strips from the result. Whisper also uses
automatic detection. The initial investigation preserved every model language.
The user subsequently proposed deriving a smaller candidate set from translation
pairs and requested research covering every offered model. The cross-model
proposal below supersedes the earlier assumption that only unrestricted
detection should be investigated. No runtime restriction has been implemented.

## Synthetic investigation

The investigation used the production sources at `fcdaf97`, the existing verified
Qwen3-ASR 1.7B 8-bit cache and packaged Metal kernels, with downloads disabled.
It did not use the microphone, play audio or read personal recordings. Installed
macOS voices generated synthetic files through `say -o`.

Each corpus has its own size; the expanded corpora include the initial controls.
A match ignores punctuation, whitespace and case with the Unicode normalizer
`re.sub(r"[\W_]+", "", text.casefold())`.

| Corpus | Cases | Exact matches | Language coverage |
|---|---:|---:|---|
| Initial short speech at 180 words/minute | 12 | 12 | 6 Russian, 4 English, 1 German, 1 Chinese |
| Initial controls plus Russian speech at 100, 250 and 350 words/minute | 30 | 29 | 24 Russian, 4 English, 1 German, 1 Chinese |
| Initial controls plus Russian onset-cropping stress cases | 36 | 31 | 30 Russian, 4 English, 1 German, 1 Chinese |

The unmodified pipeline recognized synthetic `делай` correctly. At 350
words/minute it returned `Дедой.` for one version. Cropping Russian `да` returned
`The.` and `Yeah.` at two offsets. This demonstrates a related language error
under damaged input; it does not reproduce `делай` becoming Chinese or prove
that the user's microphone dropped the start.

The crop experiment decoded each initial Russian AIFF into mono 16 kHz PCM,
found the first sample above absolute amplitude 0.005, and removed 0, 50, 100 or
150 ms after that point. The result then passed through the production speech
detector, minimum-duration padding and quiet tail. This threshold is a stress
fixture boundary, not a measured speech onset in the user's audio.

A temporary copy of the production Qwen adapter compared three alternatives
on those same 36 cases. Its no-context baseline was asserted equal to every
result from the real `DictationEngine` before accepting comparisons.

| Variant | Exact matches | Empty results |
|---|---:|---:|
| Existing automatic detection | 31/36 | 2 |
| Context asking to preserve the original language and words | 29/36 | 6 |
| Context saying Russian/English are primary, with other languages possible | 31/36 | 4 |
| Explicit correct language supplied from each fixture's metadata | 35/36 | 0 |

Context changes were rejected: they replaced some mistakes with silence and
provided no accuracy gain. The last arm knows the intended language in advance.
It tests a possible manual override, not an improved automatic detector. Its
remaining error was clipped `сделай` becoming `делай`. This small synthetic
comparison cannot establish accuracy on the user's voice or all supported
languages. The actual Chinese substitution remains unreproduced.

## Automatic-only follow-up

The user explicitly chose automatic detection only, without a manual language
picker. Preserve this decision; the explicit-language arm above is an oracle
comparison, not an approved feature.

Further comparisons used the same 36-case corpus, all languages available, no
context and no language supplied by the user. Every baseline was checked against
the real pipeline's saved results. Each arm had 12 untouched controls and 24
onset-cropping cases.

| Automatic variant | Exact matches | Result |
|---|---:|---|
| Existing pipeline | 31/36 | Baseline |
| Remove the app's Whisper padding, keep SDK minimum of 1 s | 32/36 | One empty result recovered; language errors remain |
| Remove app padding and use a 0.5 s SDK minimum | 32/36 | One recovered result; another wrong language becomes empty |
| Detect on three copies with 150 ms gaps, then decode original | 31/36 | No accuracy gain; adds wrong-language substitutions |
| Detect on three copies without gaps, then decode original | 31/36 | No accuracy gain |
| Detect with 500 ms leading silence, then decode original | 33/36 | Two recovered results, but an existing language error becomes Spanish |
| Decode once with 200 ms leading silence | 30/36 | Regressions |
| Decode once with 500 ms leading silence | 32/36 | Gains and regressions |
| Decode once with 1 s leading silence | 30/36 | Regressions |

The app currently pads to 1 s and appends a 500 ms tail for Whisper before
branching to Qwen. Qwen's SDK also pads its chunks to a 1 s minimum. Removing
or moving this padding is not a demonstrated fix for the reported language
substitution. The two-pass variants use only the same model; a provisional
language is inferred from transformed audio, and only the original audio is
used for the delivered transcription. Repetition and silence changes were
rejected as fixes because their gains did not establish reliable detection and
some changes damaged previously correct cases. No production behavior has
changed.

A real recording of the reported spoken word is still needed to distinguish
acoustic input loss from model language selection and verify an automatic fix.
Clean synthetic `делай` is still correctly recognized, so it cannot validate
that repair. Runtime metadata contains neither words nor audio and cannot
identify the exact failed recording. The installed app observed during this
investigation was 3.7.6; its Qwen adapter, engine and dependency lock match the
investigated sources. The local compiler and packaged Metal kernels can differ
from the release build; source equality alone does not prove numeric equality.

## Previous-language experiment

The next prototype reads the model's automatic language result from a separate
long synthetic Russian or English dictation, then adds a soft preference to
that language token while decoding a short clip. It does not force a language
or remove other languages. Each short case is tested with both histories,
including histories that disagree with the actual speech language. Multipliers
of 1, 4, 16 and 64 correspond to adding their logarithm to the language-token
logit. These are experimental weights, not calibrated confidence estimates.

The initial prototype indexed a two-dimensional logits slice incorrectly and
did not apply the intended preference. Its unchanged results are invalid as
evidence about language history. The corrected probe uses the vocabulary
vector, checks the actual scalar logit change against its expected dtype-rounded
value, requires that the language branch is reached and verifies each unmodified
output against the real engine baseline. The first corrected six-case subset
passed these checks. The full comparison also passed: 36 cases, two histories
and four weights, totaling 288 decodes.

| Previous automatically detected language | Weight | Exact matches |
|---|---:|---:|
| Russian | 1 (baseline) | 31/36 |
| Russian | 4, 16 or 64 (each) | 33/36 |
| English | 1, 4, 16 or 64 (each) | 31/36 |

The Russian prior recovered the clipped `делай` and `нет` cases that previously
returned empty text. It did not correct clipped `да` becoming `The.` or `Yeah.`.
The English prior changed no normalized transcript. No new switch regression
appeared in this small corpus; that is not evidence for all languages, speakers
or stronger weights. This is a candidate for limited recovery, not a validated
fix for the reported wrong-language substitution. Production sources remain
unchanged. Further investigation should evaluate automatic language candidates
on real failing audio before introducing a persistent preference.


## Cross-model research

The recommendation is a shared candidate-language policy using each selected
engine's own audio language scores. Start by benchmarking constrained detection
against the existing automatic mode. A separate language-ID network is an
alternative to evaluate later, not a prerequisite for common behavior. This is
an architectural recommendation from source inspection, not an accuracy result.

### Evidence and limits

Google documents alternative-language recognition specifically for short commands
and search, and recommends minimizing candidate languages. This supports the
candidate-set approach, but does not establish an improvement percentage for our
local engines. [Google Speech-to-Text](https://docs.cloud.google.com/speech-to-text/docs/v1/enable-language-recognition-speech-to-text).

Microsoft explicitly documents the closed-set failure mode: when the spoken
language is absent, identification still selects a supplied candidate. Language
pairs describe translation configuration, not verified knowledge of everything a
person speaks. An out-of-set test is therefore mandatory, rather than treating
a smaller set as guaranteed correctness. [Azure language identification](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/language-identification#candidate-languages).

The reference Whisper detector scores language tokens before transcription and
returns their distribution. Restricting the argmax to a subset eliminates
outside winners; it does not add acoustic evidence. In particular, equal-weight
restriction to Russian and English preserves their relative score ordering.
Renormalizing their probabilities can make a weak choice look confident without
improving it. Preserve scores before restriction; do not use the renormalized
winning probability as proof that an utterance belongs to the candidate set.
This conclusion follows directly from the masking and softmax operations in
[Whisper's detector](https://github.com/openai/whisper/blob/main/whisper/decoding.py#L17-L71).

Separate audio language identification is technically viable. SpeechBrain's
VoxLingua107 model produces language scores, but its own model card warns about
foreign accents and other domain biases. Published development-set accuracy is
not evidence of accuracy on subsecond dictated words. An additional model also
needs native packaging, supported-language mapping and measured resource costs.
[SpeechBrain model card](https://huggingface.co/speechbrain/lang-id-voxlingua107-ecapa).

Research on language-ID front ends measures downstream transcription as well as
language errors. The broadcast/institutional study by Valente et al. is useful
for that evaluation principle; its speaker-informed method explicitly does not
target language switching by the same speaker. Its broadcast results cannot be
transferred to short personal dictation. [Paper](https://arxiv.org/html/2406.09290v1).

### Capability matrix for the shipped catalog

Verified against `DictationModel`, `DictationEngine`, `DictationQwen` and the
clean dependency checkouts at the revisions in `Package.resolved`:

| Offered model | Engine | Where to apply the common policy |
|---|---|---|
| Whisper Small | WhisperKit 1.1.1 | Audio language-token scores before text decoding |
| Whisper Large v3 Turbo | WhisperKit 1.1.1 | Same mechanism, using this model's tokenizer and scores |
| Whisper Large v3 | WhisperKit 1.1.1 | Same mechanism, using this model's tokenizer and scores |
| Qwen3-ASR 1.7B 8-bit | MLX Audio Swift 0.1.6, app-owned decoding loop | Language-prefix generation before `<asr_text>` |

WhisperKit's `TextDecoder.detectLanguage` applies its private language-token
filter and then the supplied `TokenSampling` object. It does not run configured
custom `logitsFilters` there. `TranscribeTask` then uses that detected language to
prefill text decoding. Consequently, adding `suppressTokens` or a normal text
logits filter to the current call does not restrict this detection path.
The public `langProbs` result is built from sampled tokens and their log
probabilities; with the default one-step greedy sampler, it contains the winner,
not the full language distribution. Filtering that dictionary after detection
cannot recover the best permitted alternative. Sources:
[TextDecoder](https://github.com/argmaxinc/argmax-oss-swift/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/Sources/WhisperKit/Core/TextDecoder.swift),
[TranscribeTask](https://github.com/argmaxinc/argmax-oss-swift/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/Sources/WhisperKit/Core/TranscribeTask.swift).

The inspected API supports an injected `TextDecoding` implementation. A wrapper
can delegate normal operations, and delegate `detectLanguage` with a sampler
that observes the full language logits, applies the common policy, then samples.
This is a feasible seam from code inspection, not a compiled implementation.
It can reuse the current encoder output rather than requiring another Whisper
model or a second audio encoding. Sources:
[Configurations](https://github.com/argmaxinc/argmax-oss-swift/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/Sources/WhisperKit/Core/Configurations.swift),
[TokenSampler](https://github.com/argmaxinc/argmax-oss-swift/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/Sources/WhisperKit/Core/Text/TokenSampler.swift).

Qwen's existing app-owned loop exposes logits before each greedy token choice.
The adapter can constrain the generated language prefix to supported candidate
names. Language names must be encoded with the actual tokenizer: multi-token
names and shared prefixes require a prefix tree or equivalent complete-prefix
handling, not a hardcoded one-token mask. Preserve termination, no-speech behavior
and mixed-language controls. Once text decoding starts, remove the language
constraint; restricting alphabets would damage names and borrowed words.
The SDK also permits forcing one language through `buildPrompt(language:)`, but
passing a list as a prompt is not a documented candidate-set API. Source:
[Qwen3ASR.swift](https://github.com/Blaizzy/mlx-audio-swift/blob/a5506c1c7978aeea9a3295f83d43beff3f06bcdf/Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift).

### Alternatives and recommendation

| Approach | Benefit | Limitation | Decision |
|---|---|---|---|
| Constrain native language detection to translation-pair candidates | Uses existing model; removes irrelevant language choices | Does not solve confusion within the set; can misread a third language | First prototype for all four models |
| Give configured languages a soft preference | Allows a strong outside-language result to win | Requires tuning per engine; cannot guarantee removal of irrelevant choices | Compare against hard restriction |
| Separate shared audio language-ID model, then selected ASR with a language | Same detector for every ASR model | Extra runtime; short-clip and accent errors; detector becomes a shared failure point | Later comparison if native approach is insufficient |
| Decode once per candidate language and rank transcripts | Can examine more than the first language decision | Multiple decodes; transcript likelihoods and token lengths require validation | Reserve for measured ambiguous cases |
| Detect language from the returned text or remove foreign script | Easy to attach after any model | Measures the possibly wrong answer rather than the speech | Reject as the primary fix |

Recommended shared behavior for the prototype:

1. Collect distinct languages from complete configured translation pairs. Use all
   configured pairs, not whichever translation shortcut was used last.
2. Map BCP 47 script/region variants to each engine's supported spoken-language
   identities explicitly. Deduplicate equivalents such as Portuguese regions;
   do not silently merge distinct languages such as Mandarin and Cantonese.
3. If pairs are absent, retain unrestricted detection. If any configured language
   cannot be mapped to the selected engine, preserve existing detection for the
   prototype instead of silently forcing the remaining language.
4. Re-evaluate every recording. No manual language choice per recording and no
   persistent lock to the previous detected language.
5. Compare unrestricted, hard candidate restriction and soft preference using
   the same audio. For a production automatic mode, prefer candidates under
   uncertainty and allow a strongly supported outside language only if a
   separately validated escape rule improves out-of-set transcription.
6. Do not choose a universal duration or confidence threshold from intuition.
   Measure speech duration rather than padding duration, retain original scores,
   and calibrate decision thresholds per engine. Shared behavior does not imply
   interchangeable numerical confidence values.

Hard restriction is the simplest measurable first arm. A guarded automatic mode
is the preferred product direction because translation pairs are an inferred
preference, not an explicit promise never to speak another language. Whether the
guard is accurate enough remains an experiment; literature does not supply a
reliable universal threshold for our microphones and subsecond phrases.

### Validation before shipping

Run the same corpus on every offered model, serially when measuring latency.
Include natural single words, short and long phrases, speakers with accents,
realistic microphone conditions, rapid Russian/English alternation, a third
language outside the pair, related-language pairs, proper names and mixed speech.
Also cover missing pairs, duplicate pair languages, unsupported languages and
script/region mappings. Synthetic speech and cropped fixtures remain useful
stress controls but cannot replace naturally recorded short speech.

Report language errors and normalized transcript errors separately, plus newly
empty/hallucinated outputs, switching failures and latency. Compare per-clip
changes, keep a held-out set for thresholds, repeat nondeterministic inference
and report pass rates. Mutate the actual language mask to prove tests reach the
real detection seam on both engines. A shared policy is not validated until all
four models have results; the earlier Qwen-only experiments do not meet this bar.

This research changed documentation only. No ASR behavior, weights, recording
policy, application preferences or user data changed; no commit or release was
made.

## Implementation and validation

`DictationEngine` snapshots the languages from all complete translation pairs at
recognition time. `DictationLanguagePreference` normalizes region/script variants
to spoken-language codes, deduplicates them and resolves the whole set against
the active engine. No pairs, an unresolved identifier or an unsupported candidate
preserves unrestricted detection. Nothing persists a last detected language.

Both engines add `log(4)` to preferred language logits at language selection.
This is a finite heuristic weight, not a calibrated confidence threshold; a
strong outside-language candidate can still win. The policy applies to each
recording, with no separate language setting, new download or second ASR pass.
The recording and delivery paths are unchanged.

Whisper uses `DictationWhisperLanguage`, a forwarding `TextDecoding` and
`WhisperMLModel` adapter. It replaces only the language sampler, delegates text
sampling and forwards loading/unloading to the original decoder. Candidate token
IDs and the supported inventory come from the loaded tokenizer, so Small,
Turbo and Large v3 share the behavior without sharing model-specific IDs.

Qwen uses tokenized preferred language prefixes from the loaded model's language
inventory. A prefix can span several tokens; each matching language-prefix step
receives the finite preference. Application stops when a preferred name is
complete or generation leaves the preferred prefix, before transcript text.
The vocabulary vector is selected explicitly from batch x sequence x vocabulary
logits. This is a prefix preference in greedy generation, not exhaustive ranking
of complete language hypotheses or a ban on other scripts.

The first end-to-end comparison used the same 36 synthetic cases described
above, with both unrestricted and Russian/English preference arms on each model.
All arms ran through `DictationEngine`, with verified existing caches and no
microphone, playback or downloads. This initial exploratory pass has one decode
per clip and arm; Whisper fallback can be nondeterministic on damaged audio.

| Model | Unrestricted exact matches | With preference | Untouched controls, both arms |
|---|---:|---:|---:|
| Whisper Small | 29/36 | 30/36 | 11/12 |
| Whisper Large v3 Turbo | 31/36 | 31/36 | 12/12 |
| Whisper Large v3 | 30/36 | 30/36 | 12/12 |
| Qwen3-ASR 1.7B 8-bit | 31/36 | 33/36 | 12/12 |

Small already returned English `Thank you.` for the German `Danke.` control in
both arms. No untouched control changed its normalized transcript. Damaged clips
showed both recovered words and changed wrong answers, including newly generated
annotations, so unchanged aggregate accuracy must not be read as an absence of
all regressions. The original `делай` to `叫。` report remains unverified without
its audio. These figures do not establish effectiveness on natural recordings.

Unit tests exercise actual Core ML and MLX sampling inputs: a close outside
winner becomes a preferred language, a strong outside winner survives, preferred
languages can alternate, and Qwen stops biasing before text. They also cover
region/script deduplication, multi-token names, unsupported candidates, missing
pairs and malformed identifiers. Standalone copied-source mutation checks make
an empty prefix matcher and partial-support filtering fail instead of silently
passing. Probe sources, build hashes and synthetic results remain in the ignored
evidence directory.

### Repeated runtime comparison

A second run on the refactored implementation repeated each initially changed
clip plus English, German, Chinese and two long Russian/English controls three
times per arm. Selection was based on the initial results, so this is a targeted
stability check, not a held-out accuracy estimate. Each table row counts its own
selected corpus; the models have different denominators.

| Model | Selected clips | Decodes per arm | Unrestricted matches | Preferred matches |
|---|---:|---:|---:|---:|
| Whisper Small | 8 | 24 | 11/24 | 11/24 |
| Whisper Large v3 Turbo | 8 | 24 | 12/24 | 12/24 |
| Whisper Large v3 | 9 | 27 | 13/27 | 14/27 |
| Qwen3-ASR 1.7B 8-bit | 7 | 21 | 12/21 | 18/21 |

Qwen recovered clipped `делай` and `нет` in all three repetitions each; the
unrestricted arm returned empty text for all six. Small's initial one-clip gain
did not survive repetition: that case was correct in 2/3 runs in both arms.
Large v3 changed one damaged case from 1/3 to 2/3; this does not establish a
stable improvement. All English/German/Chinese control outputs and both long
utterance outputs matched between arms for each model. Correctness is separate
from stability: Small's German control and errors in long Russian speech remain.

The initial per-clip paired sign tests are inconclusive: Small has one win and
no losses (two-sided p = 1), Qwen two wins and no losses (p = 0.5); Turbo and
Large v3 have no discordant correctness outcomes. Repetitions of the same two
Qwen clips are not six independent clips. No statistically established general
accuracy gain is claimed.

All 192 repeat decodes completed and XCTest reported zero failures. The overall
command then exited 1 because its subsequent Swift Testing helper could not
load Sparkle while the queued maintenance build was starting. This is recorded
as a runner failure, not a successful process exit. The full ordinary suite
subsequently ran its XCTest and Swift Testing stages successfully. Run native
build/test commands sequentially through process exit, including helper stages;
waiting on SwiftPM's build lock alone was insufficient in this run.

The normal maintenance gate exited 0: 230 tests collected, 217 executed and
13 opt-in integration tests skipped, with zero failures. It assembled a release
configuration dev bundle under `com.wiltodelta.translatelikeme.dev`, signed with
the team Developer ID and hardened runtime; deep strict signature verification
passed. The assembled Metal library matched the one used by the runtime checks.
The installed application was not replaced or restarted. No commit, push or
release was part of this implementation.

### Configuration and language-inventory audit

A subsequent verification found a real mapping defect: macOS and the model
inventories use different spellings for some equivalent language identifiers.
Two regression tests failed before the fix. `DictationLanguagePreference` now
uses Foundation's canonical language identifiers for both configured languages
and the model inventory, returning the model's native spelling. This also maps
legacy Tagalog to Qwen's Filipino name, without merging distinct languages such
as Norwegian Bokmal/Nynorsk or Mandarin/Cantonese. Nine focused unit tests pass,
including round trips through every Whisper language code and re-reading complete
translation pairs after settings change. Settings tests restore the volatile
argument domain and do not write persistent preferences.

The opt-in `DictationLanguageAuditTests` ran the real engine with existing verified
caches on all four models. Six configurations per model covered no pairs,
incomplete pairs, three complete pairs with script/region duplicates, an
unsupported language, strong English speech outside German/Chinese preferences,
and switching back to Russian/English. All 24 transcripts matched their expected
text after Unicode punctuation/whitespace/case normalization. Each recording read
the current pairs exactly once without reloading the model. Each model also
passed silence, cancellation before recognition, skipped preference reads for
both early exits, and unloading checks. The complete test process exited 0.

The audit resolved all 329 language identifiers currently offered by this Mac
against the verified inventories. It found no unmapped model language that the
interface offers: Small covered 98 of 98, Turbo and Large v3 each 99 of 99, and
Qwen 30 of 30. Whisper additionally supports Latin, which this Mac's locale
inventory does not offer. The first audit incorrectly required that language to
appear in the interface; the corrected assertion derives the offered subset
rather than treating a missing UI locale as a mapping failure. These inventory
counts describe this audit, not a fixed platform contract.

Copied-source mutation checks verified that removing canonicalization, accepting
partial support, or disabling prefix matching each triggers an assertion; the
unmodified copy passes. All three mutations were confirmed in copied source and
failed at runtime, rather than through compilation errors. Reports and source
hashes are retained separately from the earlier comparison evidence. This audit
checks integration behavior on synthetic speech; it does not establish accuracy
on natural short utterances or reproduce the original Chinese substitution.

The final serial `bash maintain.sh` run after the alias fix exited 0: 235
collected tests, 221 passed, 14 opt-in tests skipped and zero failures. The
release-configuration dev bundle passed deep strict signature verification with
the team Developer ID and hardened runtime. Its Metal library SHA-256 matched
the runtime-check artifact. The installed application was not replaced or
restarted. The audit reports remain local and no commit, push or release was made.

### Clean CI Metal dependency

The first pushed implementation compiled on CI but its Qwen sampling unit test
terminated while initializing MLX: the runner had no default Metal library yet.
Local Xcode builds had generated a SwiftPM Metal resource bundle, hiding that
prerequisite. A missing-library override reproduced the failure locally.

`Device.withDefaultDevice(.cpu)` first initializes MLX's global stream pair.
An explicit CPU stream bypassed that initialization, but a second probe still
failed during array allocation: MLX's native allocator also initializes Metal.
The explicit-stream prototype was rejected and production sampling is unchanged.
CI now builds the pinned native kernels with the existing script before tests
and exports `TLM_QWEN_METALLIB`. The Qwen sampling test uses the existing
`DictationQwenTestSupport.configure()` helper. It skips only when a local checkout
has neither an assembled dev app nor an explicit library path; an explicit but
missing library fails. CI always supplies the path and must execute this test.
A fresh local checkout can run `./build.sh` first, or provide the kernels through
that environment variable. No model download or microphone is needed.

### Re-running the runtime check

The permanent opt-in test accepts `cases.json` with `id`, `file`, `expected` and
`language` fields. It checks every `DictationModel.allCases` entry with and
without Russian/English preference, using existing verified dev caches only.
It records accuracy inputs rather than asserting that damaged speech must be
recognized perfectly. All four caches and a built dev bundle are required.

A minimal synthetic control fixture can be generated without microphone access
or playback (the named macOS voices must already be installed):

```bash
python3 - <<'PYTHON'
import json
from pathlib import Path
import subprocess

folder = Path(".build/dictation-language-fixture").resolve()
folder.mkdir(parents=True, exist_ok=True)
cases = []
for index, (voice, language, text) in enumerate([
    ("Milena", "ru", "Делай."),
    ("Samantha", "en", "Do it."),
    ("Anna", "de", "Danke."),
    ("Tingting", "zh", "你好。"),
]):
    audio = folder / (str(index) + ".aiff")
    subprocess.run(["/usr/bin/say", "-v", voice, "-r", "180", "-o", str(audio), text], check=True)
    cases.append(dict(id=str(index), file=str(audio), expected=text, language=language))
(folder / "cases.json").write_text(json.dumps(cases, ensure_ascii=False, indent=2))
PYTHON
TLM_LANGUAGE_PREFERENCE_CHECK="$PWD/.build/dictation-language-fixture" \
    swift test --filter DictationLanguageIntegrationTests
```

This four-clip control fixture is not the historical 36-clip stress corpus.
Exact reproduction of those measurements uses the retained audio and hashes.
The temporary three-repeat investigation driver is archived there separately;
it is excluded from ordinary test collection.

## Retained evidence

Local synthetic audio, manifests, comparison results, source hashes, logs and
the temporary probe sources are retained in `.build/dictation-language-check/`
(gitignored). They support the next automatic-only comparison; remove them after the
reported case is verified. The runtime metadata log is private local evidence
and must not be committed. The temporary tests were removed from normal test collection.
