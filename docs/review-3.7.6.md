# Code review for 3.7.6

The release review covers the changes after 3.7.5 through the local translation
engine, including Qwen dictation, prepared microphone capture, output muting,
shared paste delivery, keyboard layouts, model installation, Settings, onboarding,
localization and release packaging. The review followed the production call paths
and pinned SDK implementation before adding regression tests. It is a code review,
not a new ASR quality benchmark or a whole-product visual audit.

## Findings and corrections

| Area | Finding | Correction and evidence |
|---|---|---|
| Output restoration | Failed unmute and disconnected devices lost their recovery record. Numeric Core Audio ids can be reassigned. | Resolve the saved UID, keep unsuccessful restoration pending and retry on preparation/launch/another hold. Fake Core Audio regressions reproduced the failures without changing real volume. A reassigned-id case preserves the other device. |
| Local model lifetime | Actor reentrancy allowed overlapping model loads and removal during generation. | An exclusive queue covers the entire load/generate/remove operation. Tests block the active generation and prove another load or deletion cannot begin. |
| Memory pressure | A warning during generation was dropped, leaving the resident model until the idle timeout. | Remember the release request and apply it after generation drains. The blocked-generation regression failed before the correction. |
| Cancellation | The SDK streaming consumer can stop before its background worker finishes using the model/GPU. | Use the pinned SDK's `generateTask` handle and await it before releasing model access. A controlled producer test checks cancellation propagation. The October 21 follow-up found a scheduling gap in its drain-ordering assertion; see [local translation](local-translation.md). |
| Partial answers | A local translation reaching its token limit was returned as a complete answer. | Require a normal EOS completion; surface a translated error instead of pasting partial text. The finished-stream regression failed with the previous collector. |
| Qwen errors | The recording-limit error's shorter-recording guidance was hidden by the generic controller error. | Preserve that error message through the controller; a recognition failure test reproduced the missing guidance. |
| Paste cancellation | Cancellation during destination lookup could still post Paste. | Check cancellation again after resolving the destination, before writing the clipboard. The regression simulates cancellation inside the real destination seam. |
| Paste retention | Reading near the three-second deadline shortened the promised 300 ms post-read hold. | The deadline bounds waiting for the first read; a received read gets its full hold. The fake-clock regression reproduced restoration at 3.00 s instead of 3.25 s. |
| Readiness | An installed local model was reported ready even on a Mac below its memory minimum. | Reuse `LocalModel.fits` in readiness, covering both models and missing downloads. |
| MLX initialization | Both model actors could rewrite the same C++ metallib path without synchronization. | Serialize the shared setup and avoid resetting an unchanged path. The pinned MLX source exposes a shared `std::string` setter without a lock. |
| Development identity | Development and release bundles shared their display name and directory name. | Build `Translate Like Me Dev.app`, set both bundle names, and update capture, Qwen test and branch-archive paths. Production bundles retain `Translate Like Me.app`. |

The build and notarization scripts also remove their owned temporary plist/upload
files. Test latches are shared, rather than implemented separately for each suite.

## Verification and limits

The original mute, memory, recognition-message, partial-answer and paste regressions
were run before the corresponding corrections. Unit fixtures use private preferences,
sparse synthetic model files, a named pasteboard or fake clipboard, controlled
continuations and injected delays. They never open a microphone or change real output.

Eight isolated source mutations were rejected by assertions in the 23-test
regression selection; the unmodified and restored candidates passed. The mutations
cover lost mute recovery, deferred memory release, producer draining, partial
answers, exclusive model access, paste retention/cancellation and memory readiness.
The harness verifies that the intended source replacement occurred and that tests
ran, rather than accepting a compiler failure as a rejected mutation.

Validation includes the canonical lint/test/signed-bundle gate, native Qwen WAV
recognition, native local translation, controlled cancellation-drain checks, and rendered Settings
in light/dark appearances at minimum width. Qwen passed twelve synthetic WAV checks
(four cases, three runs each). Both local model descriptions were rendered in English
and German at 500 pt window width: description contrast was at least 4.83:1 in
light and 5.39:1 in dark, with picker/footer bounds checked. All eight images were
inspected. Both local models passed twelve native translations in total
(two directions, three repetitions per model); explicit unloading also passed.
TranslateGemma was downloaded and hash-verified in an isolated directory, while
the verified Gemma files were cloned from the Dev cache. The isolated UI app and preferences were removed, and system appearance
was restored. Logs, mutation verdicts and capture recipes
remain under the ignored `.build/diagnostics/review-3.7.6/` directory of the main checkout.
CI must succeed on the exact candidate commit before its release tag is pushed.

Physical microphone route changes and actual speaker restoration are not exercised
by these synthetic checks; earlier hardware observations remain in
[dictation startup](dictation-startup.md). Paste receipts record a read by any process,
not an authenticated acknowledgement from the destination: clipboard managers that
ignore the transient marker can read the promise. An editor that does not consume
Paste within three seconds still falls back to an explicit Copy result. Cancellation
cannot retract a Paste already posted. These are boundaries of the current delivery
protocol, not claims of guaranteed insertion into every application.

The initial native translation assertion required the literal stem `сбор` and
`CI`. TranslateGemma instead returned `Построение` and sometimes expanded CI to
`системе непрерывной интеграции`, preserving the sentence meaning. The check now
accepts those explicit alternatives; it remains a smoke check, not a quality score.

Existing local-model quality limitations and the prior measurements are retained in
[local translation](local-translation.md) and [Qwen integration](qwen-integration.md).
