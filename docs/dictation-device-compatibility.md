# Dictation microphone compatibility

October 23, 2026. This is an engineering contract and a record of checks, not
certification of every headset or third-party driver. The user prioritized
correct handling of different input devices over model word-choice analysis.
The earlier product comparison and conversion measurements remain in
[the pipeline investigation](dictation-audio-pipeline.md).

## Primary evidence

- Apple's [AVAudioEngine configuration contract](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification)
  is also present in the installed macOS 27 SDK's `AVAudioEngine.h`, lines
  1036-1060. Hardware rate/channel changes stop the engine; connections retain
  their old formats. Teardown must not run synchronously on the notification
  handler's internal queue. This notification alone is not a complete device
  topology or identity monitor.
- Apple's [Core Audio property listener contract](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:))
  is verified against `AudioHardware.h`, lines 374-423. Registrations retain
  their queue/block until removed with the matching object, address, queue and
  block. The app owns its registration lifetime and forwards events to its
  capture queue instead of rebuilding inside a HAL callback.
- [WebRTC's pinned Mac backend](https://webrtc.googlesource.com/src/+/a1070b8273aee7b7d18e80b875d253ba2c6279f3/modules/audio_device/mac/audio_device_mac.cc)
  independently handles device disappearance and stream-format changes. This
  is an implementation reference at the cited revision, not a claim that the
  old snapshot is the current backend of every Chromium product.
- [Mozilla's pinned Cubeb Rust backend](https://github.com/mozilla/cubeb-coreaudio-rs/blob/076ecf68dbf20087d2fa8e9210a1965e341f66d0/src/backend/mod.rs)
  distinguishes an explicitly selected device from a default-following device,
  observes input data-source changes and device liveness, and serializes
  reinitialization away from callbacks. Its reinitialization and destruction
  flags prevent queued recovery from reopening a destroyed stream. The old C++
  backend was not treated as evidence of current Firefox behavior.
- Apple's [Bluetooth support explanation](https://support.apple.com/en-gb/102217)
  documents a mode change when a headset microphone is used. It explains a
  transport tradeoff; it does not prove this user's near-end microphone
  distortion is inevitable or identify its cause.

These sources support handling capabilities and lifecycle events rather than
maintaining a whitelist of model names or guessing formats from Bluetooth/USB
labels. Vendor firmware, the Mac Bluetooth stack and physical microphone DSP
remain outside the app's direct control.

## Required behavior by device class

| Input class | Handling in the app | Coverage and limit |
|---|---|---|
| Built-in Mac microphone | Use the HAL-reported input channels/rate; leave hardware processing and gain unchanged | Real metadata/listener and signed graph-preparation checks on this Mac |
| Direct Bluetooth, including AirPods/BH74 | Resolve UID, observe profile-related rate/channel changes, rebuild only before nonzero audio with two retries | Deterministic lifecycle coverage; no new physical Bluetooth capture |
| USB microphone or headset | Require a live input with nonzero input channels, preserve its native graph format | Seven rates and four channel counts simulated through the real writer/loader; no physical USB capture |
| Wireless headset through USB receiver | Handle its exposed Core Audio USB capabilities; do not assume direct-Bluetooth format or mute semantics | Same USB path, vendor receiver DSP/firmware not certified |
| TRRS or interface source change | Include the input data-source value in the route snapshot and observe its property | Simulated data-source changes; no physical jack insertion |
| Multichannel interface or public aggregate/virtual input | Preserve native channels, use one fixed channel by non-DC energy before ASR | 1/2/3/8-channel path tested; not general meeting mixing, beamforming or guaranteed selection among independent noisy sources |
| Output-only, dead or zero-input-channel device | No usable input snapshot; do not construct a capture graph for it | Resolver fallback and real Core Audio metadata checks; physical transport inventory remains limited |
| Hardware-muted microphone | Keep an uninterrupted zero stream valid; never change input mute or treat silence alone as disconnection | Existing zero-stream and startup-recovery tests; physical mute synchronization not established |

AVAudioEngine's processing format is the boundary read by the recorder. The
Float32 WAV preserves that graph's samples, rate and channels; it is not a raw
copy of Bluetooth packets or a USB interface's physical 16/24-bit wire format.
No application-level codec selection, system sample-rate write, automatic input
gain, voice-processing enablement or external driver installation is added.

## Route identity and recovery

`DictationInputRoute` snapshots device ID, UID, input channel count, nominal rate
and optional input data source. A numeric ID alone is insufficient after
unplugging because Core Audio can reuse it. A chosen UID must still match the
snapshot read from that ID. Only a live device with actual input channels can
be chosen or used as fallback. The picker uses the same qualification.

An explicit microphone is bound even when it happens to equal the current
system default. Changing that default must not turn an explicit choice into
an implicit default-following connection. An absent choice falls back to a
usable system input without overwriting the saved UID; returning hardware is
resolved again. Without a usable input, preparation fails before opening a graph.

`DictationInputObserver` watches system device/default-input changes plus the
selected device's liveness, nominal rate, input stream configuration and
optional data source. Notifications cause a fresh comparison, so unrelated
private aggregate creation does not create rebuild loops. Idle changes rebuild
a prepared graph without starting its microphone. If no graph could be prepared,
a returning device triggers another preparation while dictation remains enabled.
Shutdown unregisters listeners; already queued callbacks cannot reopen capture.

Before any nonzero signal, a route or format interruption, or a failed engine
start, may discard startup silence and rebuild, at most twice. On October 25,
AirPods failed `start()` with -10868 on a graph prepared for their earlier
44.1 kHz stereo format, and after a 48 to 24 kHz HFP switch the rebuild took
2.5 s, past the controller's 3-second first-audio limit. The worker now owns
silent and failed starts, and the controller only caps the whole startup at
10 seconds from the press.
The same AirPods moved their nominal rate between 24 and 48 kHz each time the
app built its idle graph. Because the route was snapshotted before the build, every
graph looked stale, and the idle graph was rebuilt about four times a second. The
route is now read after the build. A graph built during that mode switch started
without error and never delivered a buffer, while a fresh graph delivered within
0.2 s, so a running graph with no buffer after 1 s is rebuilt from the same budget.
A cold AirPods microphone then sent 0.49-0.61 s of exact zeros (five of five fresh
starts), so Listening waits for the first nonzero sample, or a second of an
all-zero stream for a hardware-muted input. Speech in those zeros is lost: two
recorded phrases kept about 0.6 s of speech and Qwen returned empty text, and one
such hold in the app produced Chinese text. Later holds on the same graph started
in about 35 ms without zeros.

With the capture fixed, the user's own AirPods recordings of a known Russian
phrase stayed unrecognizable: Qwen returned empty, Chinese or English text, and
Whisper Turbo returned English. The recordings were continuous, at their stated
rate, with no repeated or broken buffers, and the user heard their voice "with a
lot of noise and distortion". The same phrase synthesized and band-limited to 8,
16 and 24 kHz was recognized by both models in every run. A voice-processing
capture (AirPods at 24 kHz) did not fix it: Qwen produced a wrong Russian
sentence three times out of three. The AirPods microphone signal itself limits
recognition here, as the October 23 headset reports suggested; the recordings
were deleted after analysis. After nonzero audio, a changed route fails
rather than joining microphones or accepting a partial recording. Release and
cancellation forbid another start. Drain rechecks the current route and engine
running state even if a notification has not yet arrived. These are deliberate
failures instead of successful recognition of an invalid recording; uninterrupted
hot switching during an utterance is not promised.

## Reproduced defects and verification

Before fixes, regression tests failed for a same-format active device change,
an idle device change and reuse of a numeric ID. A separate test then reproduced
failure to prepare when an input returned after absence. Another reproduced two
unsafe drain paths: a stopped engine and a route change with its notification
still pending. All now pass. Explicit-choice binding, nonzero-audio rejection,
startup-zero recovery, invalid-input fallback and cancellation/shutdown have
separate assertions through the production worker.

The worker/native writer/loader matrix covers seven rates (8, 16, 24, 44.1, 48,
96 and 192 kHz) and four channel counts (1, 2, 3 and 8), 28 combinations. It
checks native frame counts/rate/channels, complete finite conversion and file
cleanup. These are simulated capture graphs, not 28 physical microphones.

Two read-only native checks ran on the available built-in input:

- Five listener registration/watch/unwatch/stop cycles, six registrations per
  watched input, zero remaining after each stop; the system input was unchanged.
- A Developer ID signed, hardened helper with an existing microphone grant
  prepared six production graphs: three system-following and three explicitly
  bound to the same current default. All six retained 48 kHz mono; all three
  explicit AudioUnit bindings returned success. No graph was started, no PCM
  was retained and no permission prompt was requested. This proves preparation
  and binding success, not which microphone delivered recorded frames.

Disposable copies of the real sources and tests are used for mutation checks;
production files are never mutated in place. Disabling route callbacks, UID
comparison, explicit binding policy, listener shutdown, re-preparation after
absence or final drain validation must fail their corresponding assertions.
No model inference, user dictation or timing measurement is included in these
checks. The preceding 240-result ASR comparison is separate evidence for the
unchanged converter/model boundary, not a new microphone test.

A driver that reports itself alive/running while supplying stale or distorted
PCM still requires physical signal measurements. Successful preparation and
synthetic PCM cannot certify firmware DSP, RF conditions, acoustic quality,
independent channel semantics or Russian natural-speech accuracy. Only the
available built-in input was exercised natively here. Hardware mute, USB
receivers, real Bluetooth profile changes and unplug/replug remain uncertified.

Receipts, native metadata, mutation results and the final maintenance/build logs:
`~/.local/state/agent-artifacts/translate-like-me/device-compatibility-20261024T005223Z/`.
The user subsequently approved installation. The compatibility candidate was
installed and restarted at 19:45 PDT on October 23; startup input/model readiness
was verified. The full settings dictionary and all 171 dictation/translation
model files retained their values or file size/mtime. This is a local diagnostic
installation, not a published release. Installation evidence:
`~/.local/state/agent-artifacts/translate-like-me/install-device-compatibility-20261024T024430Z/`.
