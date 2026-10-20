# Parakeet Ultra integration

Implementation and verification: October 20, 2026. The user approved adding
Parakeet Ultra as a separate model after the [standalone comparison](parakeet-ultra-experiment.md).
Whisper Large v3 Turbo remains the default for absent or unknown preferences
and remains marked Recommended. No existing preference is migrated to Parakeet.

## Runtime and installation

The existing Dictation picker now lists four models. Parakeet's description
states its 25 European languages and approximate 632 MB download. English,
Russian and the other eight interface languages retain the same model names;
the new description is translated into all nine non-English localizations.

`DictationEngine` owns the selected WhisperKit or FluidAudio runtime. It unloads
the previous runtime before loading another, clears its reference before
awaiting SDK cleanup, and keeps the selected runtime resident under the same
memory-pressure and disabling policy. Cancellation checks prevent cancelled
preparation or recognition from publishing a late result. Parakeet starts a
fresh TDT decoder state for every recording. Capture and caret delivery are
shared and unchanged.

FluidAudio is pinned to 0.17.7, commit
`503b4bd1bbf7220882de39fe8ae6716aae4132da`. SwiftPM tools 6.2 enables the trait
that omits the unused NeMo text-processing binary. Swift 6 language mode,
macOS 15 deployment and the app's native shell remain. Other FluidAudio
subsystems still share its library target; the trait does not remove them.

`DictationParakeet.swift` pins `FluidInference/parakeet-ultra-coreml` revision
`95eaa59a39d4394f047a4dc5cce480388a60d1b6`. Its components live at the repository
root. Required model names and vocabulary come from the pinned SDK's v3-family
contract. `DictationSnapshot` validates completeness and Git/LFS hashes before
use and after download. It excludes Hub's `.cache/` metadata from the root
asset walk. Corrupt assets cannot become an offline-ready model. FluidAudio
loads only the verified local directory; its automatic downloader is not used.

The app-owned cache is
`~/Library/Application Support/<bundle id>/Dictation/models/FluidInference/parakeet-ultra-coreml`.
It is separate from the standalone experiment's cache. Installation uses the
existing progress/retry UI. Offline reload disables downloads. The shared
Silero speech gate, original audio, one-second minimum and quiet tail remain.
Parakeet uses CPU/Neural Engine for encoder, decoder and joint, with a CPU
preprocessor; Whisper retains its measured CPU/Neural Engine placement and
CPU/GPU mel computation. SDK transcript logging is suppressed.

The bundle includes FluidAudio's resource bundle, its Apache 2.0 license and
upstream third-party notices. Parakeet attribution and its CC BY 4.0 source
links ship in `Parakeet NOTICES.txt`. The SDK and checkpoint licenses are
separate. The app does not modify the published model weights.

## Reproducible software checks

```bash
python3 scripts/check-parakeet.py --report .build/parakeet-check/report.json
python3 scripts/check-dictation-audio.py --model parakeetUltra \
  --report .build/parakeet-audio-check/report.json
bash maintain.sh
```

The first opt-in test installs pinned assets if needed and uses generated
English and Russian short/long messages plus digital silence. It performs
Parakeet → Turbo → Parakeet, with three recognitions per input at each stage,
then unloads, reloads offline and verifies cancelled preparation. Its report
stores model identities, case identifiers and counts, never transcript text.
The second check uses finalized 48 kHz seven-channel WAVs through the actual
capture-file sink, resampling, speech detection and selected model. Neither
check opens a microphone or plays audio. `--skip-build` can reuse a current
test bundle. The bounded subprocess deadline is 600 seconds.

The recorded run started without the app's Parakeet cache. All 45 recognition
checks passed through both runtimes, including offline reload, unloading and
cancelled preparation. All twelve WAV-path checks passed: English, Russian,
Russian foreground with weaker English background, and silence, three times
each. Required terms survived in every speech case and silence stayed empty.
Generated audio was removed on completion. This verifies software behavior,
not physical microphone echo cancellation or natural-speech accuracy.

Unit checks cover the complete root snapshot, corrupted vocabulary, missing
joint weights, selection persistence while disabled, and rejection of every
catalog model during capture. A mutation of a disposable copy of the real
snapshot validator that treated Hub metadata as assets changed the root-snapshot
check from success to failure. A second mutation that extended the metadata
exclusion into Whisper variant directories admitted an unverified asset; the
new variant check rejects it. The production source was never mutated in place.

The existing benchmark scripts now use SwiftPM to link the added runtime and
its C dependencies with the app's pinned revisions. Executable copying preserves
the build's mode before signing. A Turbo CPU/Neural Engine smoke run checks
compatibility; its one-arm results are not a speed comparison.

## Native interface verification

The signed development bundle was driven through native Accessibility with an
on-screen notice. English and German were checked at the fixed 500-point
width; the window is not resizable, so this is also its minimum width.
All four menu entries were read, Turbo initially showed Recommended, and an
AX menu selection changed the live picker to Parakeet Ultra. The stored raw
preference was verified as `parakeetUltra`. Dictation stayed disabled during
UI driving to avoid recording or permission prompts; actual installation and
recognition were checked separately above.

Light captures were inspected and measured before the dark pass. All four
captures were visually reviewed. English measures 500 × 440 pt and German
500 × 470 pt at 2× raster scale. The summary is one line in English and two
in German; it stays aligned with the Model label and leaves 20 pt before the
footer. The selector, summary and footer stay within the window without overlap.
New description contrast is 4.83:1 in light and 5.44:1 in dark. The capture and
reader path reproduced a known sRGB `#575757` swatch exactly. Precision analysis
reported no new model-row findings. Its existing 1.88 pt Toggle/text top-edge
finding belongs to the unchanged native Enable switch; the same bounds occur
before selection. Native control drawing was preserved. VoiceOver task
completion and physical keyboard navigation were not tested.

System appearance and the full development preference dictionary were restored
and compared. Owned app, backdrop, calibration and notice processes stopped.
The installed app was neither quit nor reconfigured.

### Capture cleanup correction

The new selection exposed a defect in the capture recipe: `defaults import`
restores old values but keeps a key that did not exist in the backup. The
probe used an isolated disposable preferences domain and reproduced that
behavior. `setPersistentDomain` restored the exact original dictionary,
including removing the new key. `capture-screenshots.sh` now waits for its
owned app to stop and restores with that API. The temporary Parakeet preference
was removed and the real development domain was verified against its backup.
The UI driver also reads translated labels from the built bundle instead of
guessing German menu or window titles.

## Artifacts and limits

`.build/diagnostics/parakeet-integration/` retains lifecycle and WAV reports,
unit/build/gate logs, snapshot and defaults-restoration mutation verdicts,
English/German light/dark captures, AX geometry, contrast and precision reports,
plus the native verification recipe. Model assets remain in the app's cache
for ordinary use. Temporary audio, copied mutation sources and helper
executables are removed after verification. No commit, push or release is part
of this change. Recognition quality on natural recordings remains unmeasured;
the initial speed figures belong to the standalone synthetic comparison.
