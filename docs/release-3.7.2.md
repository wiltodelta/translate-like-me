# Release 3.7.2

The user explicitly authorized publication on October 19, 2026 after the
unattended software checks and disclosure of the remaining acoustic limits.
[Release notes](release-notes-3.7.2.md) describe the shipped changes and limits.
The user does not need to perform the earlier timed reading procedure.

## Scope

The release includes the interface localization and Antigravity CLI support
already merged into main, plus the session's dictation changes since v3.6.0:
voice-processed recording and maximum fixed media ducking, native-format WAV
capture and interruption handling, trailing `[BLANK_AUDIO]` cleanup, duplicate
held-Option handling, and metadata diagnostics. It also includes the isolated
fresh-install runner, diagnostic collector and corresponding tests and docs.
It does not claim compatibility with a running Punto Switcher. The reported
workaround and remaining event-trace check are recorded in
[fresh-install verification](fresh-install-testing.md).

## Acceptance

Before the unattended harness was added, the full project gate exited 0 on
October 19, 2026: SwiftLint passed, 154 tests
passed, eight were skipped, and the arm64 release-configuration development
bundle built. The skips are six isolated fresh-install scenarios (run separately
as documented) and two opt-in integration checks. Strict deep signature
verification passed, with Developer ID, hardened runtime, audio-input
entitlement, minimum macOS 15 and SDK 27. The local log and exit-code file are
`.build/diagnostics/full-audio-validation/maintain.log` and `maintain.exit`.
This gate does not provide CI-toolchain or acoustic acceptance evidence.
The unattended harness and its negative controls have separate verified results
in [unattended testing](unattended-dictation-testing.md#software-path). Its
follow-up full gate is logged under `.build/dictation-audio-check/maintain.log`.

Acoustic measurements and their limitations live in
[dictation verification](dictation.md#maximum-ducking-release-validation-october-19-2026).
Enabled processing flags and unchanged system volume do not establish that movie
dialogue is excluded or that the user's own speech remains intelligible.
Independent foreground speech during playback and audible restoration after
release and cancellation remain open checks. The user authorized publication
with those limits disclosed, rather than representing software-only checks as
acoustic acceptance. Future [unattended verification](unattended-dictation-testing.md)
can use a prerecorded independent source instead of a live reader. Compare on
the same build and device pair with a usable untreated playback control.

## CI compatibility

The first v3.7.0 tag did not publish a release. Both its main and tag workflows
failed during test compilation because the CI SDK's `AVAudioEngine` is not
Sendable. Capturing the engine in a notification closure and then crossing into
`MainActor.assumeIsolated` failed the compiler's region-isolation check. The
callback now reads the recorder's current engine inside the main actor, guarded
by capture identity, instead of capturing the engine across that boundary.
The v3.7.1 follow-up compiled the app, then failed on the same kind of capture
in the offline rendering test. The test now creates, renders and stops its
engine within one detached task, returning only sample values. The stateless
graph helper is nonisolated and never accesses recorder state. Neither engine
nor format crosses the task boundary. The existing remote tags are retained;
publication proceeds with v3.7.2 only after main passes CI.

## Publication

The user has authorized committing the reviewed changes, pushing the release,
notarization and publication through the tag workflow. Version 3.7.2 comes from
an annotated v3.7.2 tag, not an Info.plist edit. The development identity remains
separate from the installed app. The workflow, published assets, Sparkle feed
and Homebrew cask are the sources of truth for publication status; verification
steps live in [build and release](build-and-release.md#release-process).

## Antigravity model-picker report

The report, reproduced cache-to-picker failure, fix and verification limits
are recorded in [release 3.7.3](release-3.7.3.md#antigravity-model-picker-report).
