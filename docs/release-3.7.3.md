# Release 3.7.3

The user requested publication on October 19, 2026 after disclosure that native
settings verification and a physical microphone-startup benchmark remained
blocked by another session's shared Rota notice. Publication is authorized with
those limits; software tests do not establish native or acoustic acceptance.
[Release notes](release-notes-3.7.3.md) describe the user-visible changes.

## Scope

- Update open model pickers when any engine readiness probe records a catalog,
  including status-menu and onboarding probes. Preserve the selected provider
  when an older probe completes.
- Start the recorder before querying the destination editor through
  Accessibility or building the dictation indicator. Preserve hold-only
  microphone use, existing voice processing and teardown.

## Antigravity model-picker report

After installing 3.7.2, the user reported that Model contained only Default for
Antigravity on this Mac, with no effort list. On October 19,
2026, the local agy 1.4.2 returned its catalog successfully both from the project
directory and from the temporary directory used by `ProcessRunner`. An opt-in
temporary XCTest through the real `EngineStatus.check` and
`HarnessModels.catalog` path passed: five model groups with their accepted
efforts. The installed app's saved catalog also contained the model rows.
The local probe log is `.build/antigravity-live-probe.log`; the temporary test
was removed after the run.

The regression was then reproduced through the actual readiness/subprocess path
with a synthetic CLI: `EngineStatus` populated the persisted model cache while
an already-created `SettingsStore` retained an empty catalog. Its own initial
probe was not a subscription to later status-menu or onboarding checks. The
regression asserted that the cache was populated before checking the open
store, and failed for both its model and effort lists before the fix.

`EngineStatus` now publishes `.harnessModelsChanged` on the main actor after
recording models. Each store subscribes for its lifetime, reloads the selected
provider and ignores another provider's late result. The model-pick tests
cover updates after initial creation and provider switching. They
inject catalog refresh so unit tests never launch a user's real CLI. Logs:
`.build/antigravity-late-catalog-before.log` and
`.build/antigravity-late-catalog-after.log`.
Removing the provider guard caused the late-response assertion to fail against
two isolated catalogs; the original source was restored byte-for-byte.
Its log is `.build/antigravity-provider-guard-mutation.log`. The combined full
gate then exited 0: 168 tests passed, nine were skipped, and the signed arm64
development bundle built. The log is `.build/antigravity-startup-maintain.log`.

During release preparation the native settings UI remained unverified because
another session owned the shared Rota notice. This software check does not establish what the fixed
development build renders; the installed app was left untouched during local checks. Effort
remains hidden on Default until an explicit model is selected, as documented
in [model selection](user-guide.md#model-selection).

## Dictation startup

`testMicrophoneStartsBeforeReadingTheInsertionTarget` failed before the ordering
change and passed after it; it asserts both recorder startup and actual target
inspection. This removes editor lookup as a dependency before capture starts.
It does not establish a millisecond improvement, hardware readiness or complete
first-word preservation. The user explicitly chose microphone use only while
holding the key; no continuous capture or pre-press buffer was introduced.
The [startup investigation](dictation-startup-latency.md) records remaining
startup stages, Apple API references and the measurement matrix.

## Release checks

The full local software gate for both fixes exited 0, with 168 tests passed,
nine opt-in/isolated tests skipped, and a signed arm64 development bundle built.
Strict deep signature verification passed with the Developer ID Application
identity and hardened runtime. Logs are `.build/antigravity-startup-maintain.log`
and `.build/antigravity-startup-maintain.exit`.

Release preparation runs the complete gate again under `.build/release-3.7.3/`,
pushes the candidate commit and waits for the entire main CI run on its exact
SHA before creating the annotated `v3.7.3` tag. Failed preparation keeps this
version. The tag workflow signs, notarizes and publishes the bundle, Sparkle
feed and Homebrew cask update. The live GitHub release, downloaded signature,
appcast signature and cask checksum are the publication sources of truth, as
specified in [build and release](build-and-release.md#release-process).
