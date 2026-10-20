# Fresh-install verification

Run `python3 scripts/check-fresh-install.py` from the repository. It builds the
test bundle, discovers `FreshInstallTests` through SwiftPM and runs each method
in a new XCTest process. Full Xcode and the team's Developer ID Application
identity are required. `--skip-build` reuses the compiled tests after a build.
Normal `swift test` skips this suite to avoid using a configured developer Mac
as evidence about a clean installation.

## Isolation and coverage

The runner copies Apple's XCTest host into a disposable bundle with a unique
identifier, relocates its framework paths and signs it. `CFFIXED_USER_HOME`
redirects Foundation's home and model paths, while every scenario has a separate
preferences domain. A home override alone did not isolate `UserDefaults` in a
native probe: the preferences daemon still persisted a synthetic key outside
the temporary home. The unique domain is therefore required, checked from inside
the test and deleted after each process. `defaults delete` can leave an empty
plist; after the host exits, the runner checks that file is empty and removes
only its own uniquely named file.

The child inherits an explicit environment without credentials or harness
wrappers. Its seatbelt profile denies network access, the real home and installed
tools under `/opt/homebrew` and `/usr/local`. The compiled `.build` tree is the
only read exception inside the real home. A synthetic file in the real home must
be unreadable. A parent HTTP fixture is first confirmed reachable, then must be
unreachable from the child. No real account, microphone or general clipboard is
used. Temporary hosts, homes, canaries, servers and preferences are cleaned up.

| Scenario | Actual boundary exercised | Limit |
|---|---|---|
| Empty settings and missing tools | Launch migrations, settings defaults, all configured engine probes and translation errors through real binary discovery | No GUI onboarding or physical keys |
| Signed-out tools | Real subprocess/status handling with synthetic CLI executables in the temporary home | No vendor authentication |
| Working tools | All configured engine probes and translation subprocess paths, including Codex output-file handling | Synthetic `Hola` output, no real model/service |
| Empty model cache | Real `DictationEngine` preparation with downloads disabled | No first download or Core ML compilation |
| Denied microphone, retry and release | Real controller and Option gesture with injected microphone/recognizer effects | No TCC prompt, device, global monitor or ASR inference |
| Cancellation versus empty recognition | Real controller and gesture distinguish zero recognition calls from one empty recognition call; both hide through the injected effect and leave no error or text | Does not render the indicator or establish which path the new Mac takes |

All six scenarios passed on October 19, 2026. This does not reproduce or resolve
the reported new-Mac failure. The user subsequently confirmed that translation
works and that Listening disappears after release without a visible Recognizing
stage or inserted text. This rules out a persistently visible recording, but
does not distinguish cancellation from a quickly completed empty result. The
user also confirms that the microphone meter responds to speech. This verifies
input activity, not the contents of the finalized WAV or speech-detector acceptance. The
controller silently completes an empty transcript; silence and the speech
detector can both skip Whisper before a Recognizing frame is drawn. Whether
either path happens on the new Mac is unverified.

The user subsequently identified Punto Switcher as the cause on the affected
Mac and confirmed that completely quitting Punto Switcher restored dictation.
The successful change was closing the app, rather than changing a shortcut or
disabling only automatic switching. Punto's shortcut configuration and the
keyboard-event sequence were not supplied. Record this as a user-reported
compatibility conflict with a working shutdown workaround, not a measured
missing-permission or ASR failure. The current hold
monitor cancels on intervening key events and disqualifying modifier changes,
so keyboard-event interference is a plausible mechanism. No event trace yet
establishes which cancellation or release path Punto triggers. The existing
repeated-Option-event fix has not been verified against Punto Switcher.

For compatibility verification, compare Punto enabled and disabled on the same
Mac, app build, target editor and dictation binding. Record which Punto feature
or shortcut changes the outcome before modifying cancellation rules. Preserve
cancellation for actual typing and Option combinations. Do not treat passing
synthetic Option tests as proof of compatibility with the third-party app.

Before the repeat-event assertions were added, the six-scenario suite also passed
against a disposable `git archive v3.6.0`, with only this runner and its test class
added. The published v3.6.0 ZIP matched
GitHub's asset SHA-256, passed strict deep signature verification and contained
the microphone entitlement and purpose string. The release app was inspected,
not launched under the working user's identity. Isolated copies of the runner
with the network deny or real-home file deny removed failed their corresponding
boundary assertions. These checks establish isolation and prerequisite handling,
not working global key delivery or speech recognition on another Mac.
After the cancellation/empty-result case passed on the release sources,
changing the real controller's cancellation path to call `stop()` in that
disposable copy failed the new assertions. The check distinguishes the two
internal paths even though both complete with no visible result. The copy was
removed after the check.

## Permission checks

The app requests microphone access through `AVCaptureDevice.requestAccess(for:
.audio)` when dictation is enabled, and Accessibility through
`AXIsProcessTrustedWithOptions` at launch or the menu action. The menu's Allowed
status reads `AXIsProcessTrusted()` in the running app. The user confirmed
Allowed in the new Mac's app menu on October 19, 2026. Together with the
responsive microphone meter, this leaves no identified missing permission;
it does not identify the cancellation or recognition path.

There is no Apple Speech recognizer in this implementation: WhisperKit handles
local inference. The current `NSEvent` global keyboard monitor requires
Accessibility. Apple's [Developer Technical Support explanation](https://developer.apple.com/forums/thread/707680)
distinguishes it from a `CGEventTap` requiring Input Monitoring. No separate
Input Monitoring request is missing from this event-monitor implementation.
First-grant behavior after returning from System Settings still needs a native
check; reinstalling monitors by restarting the app is a controlled check of that
transition, not proof of the reported cause.

## Native check still required

Use a separate standard macOS user or a disposable macOS VM for real first-run
permissions and global input. Creating the account or VM needs the operator's
approval. Do not reset the working user's TCC, defaults, accounts or model cache.
Record the exact app version, installation source, macOS version and hardware;
compare the installed release with the candidate build separately.

1. Start with no CLI sign-ins or downloaded speech model. Confirm that onboarding
   and settings show missing prerequisites rather than readiness.
2. Grant Accessibility, quit and reopen the test copy, and confirm its menu reads
   Allowed. Install and sign in to one translation CLI, then run its real engine
   check and translate a synthetic selection in TextEdit.
3. Enable dictation, grant microphone access and let the model finish downloading.
   In TextEdit, hold and release the configured Option key, checking Listening,
   Recognizing and inserted text. Repeat after relaunch.
4. Try denied permissions, unavailable network, interrupted downloads and retry
   without touching the working account. Distinguish absent key events from
   cancellation, capture failure, model preparation and insertion failure.

The candidate records metadata at notice level for shortcut registration,
Accessibility trust, global-monitor installation, dictation press/release/cancel,
recognition stages and translations ignored while busy. Additional metadata
distinguishes input/reload/registered-shortcut cancellation from empty or silent
audio, speech-detector rejection and entering Whisper decoding. It records no audio or
transcript. A non-nil global monitor proves installation, not event delivery.
For a session with both builds, filter by pid as well as subsystem:

```bash
/usr/bin/log stream --level info --predicate 'subsystem == "com.wiltodelta.translatelikeme" AND processIdentifier == <pid>'
```

These events are also available to `log show` at notice level. A release predating
the diagnostics will not have them. Retain only the metadata needed to locate
the missing stage, never dictated text or a full CLI transcript.

## Collect a report on the affected Mac

After reproducing the failure, run the collector within five minutes, leaving
the app running:

```bash
bash scripts/collect-dictation-diagnostics.sh > "$HOME/Desktop/tlm-dictation.txt"
```

It reads the running bundle's version, executable hash, macOS version and
architecture, then requests only that process's `dictation` and `hotkey` log
categories. It does not change settings or permissions, launch or stop apps,
or access the microphone or clipboard. No Python, Xcode or administrator access
is required. If multiple copies are running, supply the intended numeric PID
as its one argument. An old release's missing stage events are an instrumentation
limit, not evidence that a key event or recognition did not occur.

A diagnostic build based on the published v3.6.0 sources was prepared
separately from the candidate fixes. It adds only metadata in
`DictationController`, `DictationEngine` and `HotKeyManager`, preserving the
released recorder, Option gesture, transcript cleanup and delivery. This is
intended to identify the affected Mac's path before changing those mechanisms.
Its production bundle identity can reuse that Mac's existing settings and
model cache; do not launch it under the working user's identity on this Mac.
Distribution requires a separately approved notarization submission. It is not
a published release or an automatic update.

The source comparison does not isolate the compiler or SDK. The published
v3.6.0 ZIP was downloaded again and matched its asset hash; its executable
matched the installed copy and carries SDK 26.5. The local toolchain is Swift
6.4 with SDK 27. If the failure disappears in the local diagnostic copy, do not
attribute that to a code fix or logging. A baseline built with the same local
toolchain is required before attributing that difference.

The collector passed a read-only check against the installed v3.6.0 app and
rejected malformed, extra and nonexistent process selections. That live
release returned insertion metadata but no new stage events, confirming the
instrumentation limit. The temporary diagnostic worktree must use fresh build
outputs: a copied Clang module cache retained the original checkout path and
failed compilation. Dependency sources and downloaded artifacts can be reused.

The retained local package is in
`.build/diagnostics/new-mac-v3.6.0-logging/`. It includes the logging-only source
patch, build metadata and logs, the signed app, collection scripts and the ZIP.
The full maintenance gate exited 0: 142 tests passed, two integration tests
were skipped, and strict deep signature verification passed on both the app
and the ZIP extraction. The production-identity bundle has a timestamped
Developer ID signature and microphone entitlement. It was not launched. The
disposable worktree was removed after preserving these artifacts. Apple
notarization awaits explicit approval; no release was published. The original
full-relaunch question was followed by the user's Punto Switcher attribution,
rather than a standalone relaunch result. The user then confirmed that fully
quitting Punto restored dictation. Compatibility with Punto running remains
unverified; implementing it needs an affected-Mac keyboard-event trace or
equivalent reproducer before changing hold cancellation rules.

## Release assessment after the Punto report

The full current candidate's tests were rebuilt and rerun: 154 passed, eight
were skipped, and none failed. Six skips belong to the separately run isolated
suite and two to opt-in integration checks. The log is
`.build/diagnostics/current-candidate-rebuilt-tests.log`. An initial
`swift test --skip-build` could not load the old test bundle because its build
directory lacked Sparkle.framework. A normal `swift test` restored the framework
and passed without source changes. These counts describe the full candidate,
not the separate logging-only diagnostic build's 142 passing tests.

The user subsequently chose sound verification followed by preparation of the
full candidate, including voice processing and maximum media ducking. The
[3.7.2 release](release-3.7.2.md) includes trailing `[BLANK_AUDIO]`
cleanup, repeated-Option handling, metadata diagnostics and verification tools
alongside the recorder changes. The latest
[acoustic verification](dictation.md#maximum-ducking-release-validation-october-19-2026)
does not establish suppression effectiveness or audible restoration: its
untreated speech controls were empty and five of six recovery-tone pairs
failed the signal-to-noise guard. Natural speech during playback and usable
acoustic controls remain open checks. The user subsequently authorized the
full release with these limits disclosed; the authorization and scope are
recorded in the release document. Punto compatibility is not fixed; quitting
Punto is the user-confirmed workaround.
