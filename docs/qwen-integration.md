# Qwen integration

> Current catalog: Whisper large-v3-turbo and Qwen3-ASR only. Fresh profiles select
> Turbo through 16 GiB of memory and Qwen above 16 GiB. Existing valid choices
> are preserved; saved Small and Large v3 values resolve to Turbo. Earlier
> four-model catalog and recommendation descriptions below are historical.


Qwen3-ASR 1.7B (8-bit) is offered alongside Whisper large-v3-turbo. Fresh profiles
recommend Qwen above 16 GiB and Turbo on smaller Macs. Existing valid choices
remain authoritative. Removed model preferences fall back to Turbo. Changing a disabled model saves
only its selection; enabling dictation prepares the selected model.

## Runtime and assets

- MLX Audio Swift 0.1.6, revision `a5506c1c7978aeea9a3295f83d43beff3f06bcdf`.
- MLX Swift 0.32.3, revision `19601207e9a0de51e03ee6ec0c3c5f3784275075`.
- [MLX model export](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit/tree/a8379a2e2f9e313c9292cdf1af4055ab56d50d55),
  pinned revision `a8379a2e2f9e313c9292cdf1af4055ab56d50d55`.

The pinned config declares 30 languages. The five required download files are
`config.json`, `model.safetensors`, `vocab.json`, `merges.txt` and
`tokenizer_config.json`, about 2.47 GB together. `ModelSnapshot` verifies
completeness, the pinned revision and each file's Git blob or LFS hash, before
both initial loading and offline reload. Good partial downloads are preserved.
The shared eight-GB free-space preparation guard remains.

Model files live under
`~/Library/Application Support/<bundle id>/Dictation/models/mlx-community/Qwen3-ASR-1.7B-8bit`.
Development and release caches remain separate. The app loads verified local
files with `fromModelDirectory`, with no Python runtime or inference server.

The SDK derives `tokenizer.json`. `DictationQwen` links the verified inputs into
an owned temporary directory and lets the SDK derive its tokenizer there. The
directory is removed after loading. This keeps generated files outside the
verified Hub snapshot and permits another offline reload without treating an
unverified derived file as a downloaded asset.

## Recognition and cancellation

Qwen owns its MLX model and array operations in a separate actor. The existing
speech gate and padded mono 16 kHz samples feed that actor. Language detection
is automatic, without prompts or hotwords. The SDK's low-energy chunker splits
long recordings around 30 seconds, with fresh decoder caches per chunk.
Context biasing with named terms: [local model candidates](local-model-candidates.md).

The wrapper uses the SDK's public forward pass and a greedy loop in the calling
Swift task. After the language prefix it queues each next step on the GPU
before reading the current token, and loading ends with a silent warm-up
([latency](dictation-latency.md)). Cancellation is checked before every prediction; GPU synchronization
finishes queued work before the operation returns or unloads. This preserves the
controller's cancellation drain and model-switch ordering. The SDK streaming API
creates a detached producer without an exposed completion handle, so it cannot
provide that ordering directly.

Language metadata is removed from the decoded text. EOS completes a chunk;
the 1,024-token bound or the SDK-style greedy repetition backstop produces a
localized error instead of inserting partial text. Unloading clears the model
reference, synchronizes GPU work and releases unused MLX buffers. Microphone
startup, ducking restoration and caret delivery retain their existing paths.

The earlier [natural-speech comparison](parakeet-ultra-experiment.md#natural-speech-follow-up-october-20-2026)
used Python MLX Audio. Its WER scores do not establish identical output for this
Swift implementation and its bounded long-recording pipeline.

## Build and checks

`build.sh` builds MLX's Metal kernels with the pinned upstream CMake target,
using the app's macOS 15 minimum. Kernel output is keyed by source revision,
SDK and minimum version. The app embeds the kernels, current materialized SDK
resource bundles and upstream license notices before Developer ID signing.
Old FluidAudio resource bundles in a reused build directory stay out of the app.
MLX Swift requires Swift 6.3; swift-collections 1.6.0 keeps tokenizer dependencies
compatible with CI's Swift 6.3.3. The app's Swift language mode remains 6.

After assembling the development app:

```bash
python3 scripts/check-qwen.py
```

This opt-in check uses synthetic recordings only, without microphone access or
playback. It verifies actual model preparation, Qwen → Turbo → Qwen switching,
short/long Russian and English recognition, silence, offline reload, unload and
cancelled preparation. A separate process denies network access and checks the
same offline path. A reachable loopback canary must fail inside that sandbox
and remain reachable from the parent. `--disable-sandbox` disables only SwiftPM's
nested manifest sandbox; the enclosing network-denial sandbox remains active.

`python3 scripts/check-dictation-audio.py --model qwen3ASR` additionally checks
the native capture-file sink and resampling using already cached Qwen assets.
Pure tests cover EOS, token limits, repetition, deterministic cancellation,
metadata removal, corrupt/missing weights and preference fallback.

## Local verification, October 20, 2026

The native Swift integration passed on the M5 development Mac:

- `bash maintain.sh` exited 0: strict lint, 196 tests with 11 opt-in tests skipped,
  and a Developer ID signed development bundle. The opt-in checks below ran separately.
- The lifecycle check passed all 45 synthetic recognition cases across
  Qwen → Turbo → Qwen, including short and long English/Russian speech and silence.
  Offline reload, unload and cancelled preparation passed. A separate network-denied
  process recognized cached speech while its loopback canary was blocked.
- The capture-file sink, resampling and speech-detection check passed 12 of 12
  recognition cases, including mixed-language speech. No microphone or playback
  was used. These checks establish integration behavior, not natural-speech WER.
- All five cached model files independently matched the pinned source manifest.
  The verified snapshot contained no generated `tokenizer.json`.
- Six decoder mutations were rejected, covering cancellation, EOS, previous-token
  forwarding, the token bound, repetition and metadata removal. The production
  source was unchanged by the mutation check.
- English and German Settings rendered at the minimum 500-point width in light
  and dark appearances. The four-choice picker saved Qwen, and the old Parakeet
  preference initially displayed Turbo. The model summary fit with a 20-point gap
  before the footer; measured contrast was 4.83:1 in light and 5.47:1 in dark.
  All four screenshots were inspected.

Logs, JSON verdicts, screenshot recipes and screenshots remain in the ignored
`.build/diagnostics/qwen-integration/` directory. The first offline attempt failed
before test execution because SwiftPM tried to create a nested sandbox; its logs
are retained separately from the successful run. These are local results; CI on
its older Swift toolchain has not run for this uncommitted change.

The signed development app, compiled Metal build cache and downloaded development
model are retained for local use. Synthetic audio, tokenizer staging directories,
the isolated UI verification app and compiled UI helpers were removed after their
checks. The verification app's preferences and the system appearance were restored;
the only global-preference difference was timestamp precision in macOS's linguistic
asset metadata. The installed app and another session's running development app
were not changed. No commit, push or release was made.
