# First-run recommendations

## Current implementation

The app now hosts the three agreed onboarding screens, using `OnboardingFlow`
and `OnboardingView`. The earlier standalone files in `docs/prototypes/` are
historical design references, not the implementation or runtime verification.

1. Preparation shows the evidenced language pair and selected local models,
   including download sizes. Download Models starts real preparation. Speech
   assets are verified and loaded without microphone permission, then unloaded.
   The translation download reuses `LocalModelDownloads` and pinned snapshot
   verification, including existing files, then the existing `EngineProbe`
   performs a synthetic translation. An explicitly chosen CLI is checked too,
   without replacing it. Continue requires both operations to succeed.
2. Permissions explains microphone and Accessibility separately. Continue invokes
   the macOS microphone request. Known denial opens System Settings instead.
   Accessibility has its own action and is refreshed on return. Both grants
   are needed before enabling/preparing dictation and advancing to usage. The configured
   microphone must resolve to an available input; the saved choice is preserved.
3. Usage explains the assigned dictation/translation shortcuts, Copy fallback and
   the menu-bar route to Settings. An unassigned shortcut shows setup guidance
   and opens the appropriate Settings pane; missing languages have their own
   setup route. Only the final usage action marks setup complete.

Closing or pausing cancels pending work, drains it before retry, and keeps partial
files. It never writes completion. Reopening rechecks/reuses cached assets;
no claim is made that preparation never needs the network. Model changes in
Settings invalidate readiness. Revoked permissions block completion.

Downloads are explicit: large downloads are disclosed before starting. This is
one-time setup, not a claim that the app works before the required downloads
and macOS consent. Rewrite does not appear in onboarding.

## Recommendation policy

| Mac memory | Translation | Dictation |
|---|---|---|
| 8-16 GiB | Gemma 4 E2B | Whisper Turbo |
| Above 16 GiB | TranslateGemma 12B | Qwen3-ASR |

These are Victor's explicit choices, accepting E2B's measured quality limitations.
[Translation evidence](local-translation.md) covers 15 synthetic en/ru/de cases,
three runs each: E2B mishandled direction and corrected details. Hardware alone
establishes neither speech quality nor language coverage. Existing runtime
memory/storage checks stay authoritative. An unsupported Mac, failed load or
insufficient disk blocks preparation with an error rather than completing setup.

`FirstRunRecommendations.apply` runs before migrations, once for a fresh profile.
It seeds the local provider, memory-based model choices, one language pair from
macOS preferred languages/enabled keyboard sources and a neutral Improve Text
preset on Option-Command-J. Region or assumed English are never evidence. A
single language leaves the second side empty; none creates no pair. This case
shows an explicit General settings route rather than inventing a language.

Existing settings, including empty collections, false flags, styles, shortcuts,
model selections and explicit providers remain authoritative. The marker prevents
reseeding after edits. Argument-domain fixtures are excluded. Model names remain
original in every language. Removed Whisper Small/Large v3 preferences resolve
to Turbo without deleting old downloads. Settings order is General, Dictation,
Translation, Rewrite; stable saved pane IDs remain intact.

## Verification and isolation

`OnboardingFlowTests` exercises the actual transition seam with injected model
and permission effects: mandatory preparation, failed translation/retry, pause,
sequential consent, denial, revoked access and model-change invalidation.
`FreshInstallTests` also runs the real completion/defaults seam inside the signed,
sandboxed fresh-install host, replacing model and OS effects with synthetic ones.
Normal tests and visual fixtures never download models or request privacy grants.
The isolated host passed all eight scenarios. The mandatory-model transition was
mutation-tested: removing its readiness guard failed nine assertions. Pause tests
also distinguish canceling translation from leaving unrelated Settings work alone.
The final gate log is `/tmp/tlm-sc-trapped-boson-wired-final-maintain.log`, with
its actual exit code in the adjacent `.rc` file; skipped opt-in tests are not
claimed as live verification.

Native rendering uses the shipping views and development-only `onboardingPreview`
with stages preparation, downloading, failed, permissions, accessibility,
permissions-ready and usage.
These exercise layout and controls, not real downloads or OS consent. All new
interface text requires nine translations. The standalone preview audit's earlier
contrast findings do not establish the new runtime's rendering.

Native verification on 2026-10-21 used synthetic Russian and German fixtures,
seven states in both appearances (28 inspected frames) at 560 x 650 pt content.
The full native button path passed in both languages/appearances. Geometry
confirmed 36 pt brand insets and all labeled buttons inside the content bounds.
Artifacts remain under `.build/diagnostics/first-run/wired-final-{ru,de}/`.
After scoping the primary-button tint, 11 further Russian state captures and
geometry records passed in `wired-verified-ru/`. Three follow-up runs stopped
on lost focus; the inactive Accessibility frame has no passing geometry record
and is not counted. These partial runs do not establish a full final native pass.

The final palette's measured secondary-text contrast is 4.95:1 light / 6.07:1
dark; primary-button text is 5.37:1 / 6.27:1; Pause is 13.14:1 / 10.05:1.
`wired-verified-ru/contrast.json` uses the shared profile-aware reader and the
same calibrated sRGB capture pipeline as `pane-order/calibration.json`.
The dark root tint had made secondary buttons unreadable, so the stronger tint
is restricted to primary actions. System appearance and dev defaults were
restored after each run; no microphone, global hotkey or provider CLI was used.

The worktree and branch are retained for continuation:
`sc-trapped-boson-99dd`, `feat/first-run-recommendations`. The originating checkout
was read-only. Its unrelated probes/uncommitted files were never copied. Remote
main changes were integrated from commits. No installed app, account or personal
privacy grant is changed by the implementation or synthetic verification.

## Remaining verification and product limits

- Real multi-gigabyte downloads, model cold starts and real OS grant/revocation
  need an explicitly authorized native first-run exercise on a clean profile.
- Comparative recognition quality across languages is not established by the
  existing compute measurements. Qwen advertises fewer languages than Whisper;
  the selected model's actual supported languages still govern recognition.
- A missing language pair prevents translation instructions from claiming a
  working shortcut; choosing languages remains necessary when evidence is absent.
- Large downloads remain a prerequisite under the user's explicit decision,
  rather than an optional tutorial or CLI-based shortcut around setup.
