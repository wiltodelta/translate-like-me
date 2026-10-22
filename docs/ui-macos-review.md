# macOS UI review

## Scope and approved changes

The October 21, 2026 review used clean origin/main dd82c97 on macOS 27.0.1
(26A434), SDK 27, with synthetic app data. Native Settings, onboarding, menus
and renderer fixtures were inspected in both appearances and all ten shipped
languages. Voice technologies, microphone use, real translation, clipboard
mutation and model downloads were excluded by agreement.

The user approved UX-001, UX-003, UX-005, UX-006 and UX-007. UX-004 is a
separate investigation, with no status menu redesign approved.

| ID | Change |
| --- | --- |
| UX-001 | Shared RemoveButton presents RemovalConfirmation before deleting a pair/preset, shortcut and writing style. Cancel preserves the record; confirmed removal runs after the sheet closes. |
| UX-003 | StyleEditor gives its text area the localized pair/preset title as its accessible name. |
| UX-005 | Failed onboarding model preparation has an explicit failure label and warning symbol; error words use primary text. |
| UX-006 | Usage shows assigned shortcuts, or offers setup in General/Dictation when a shortcut is absent. Missing languages link to General. |
| UX-007 | Popup, recording, Done and onboarding primary actions use the system selection backing through primaryActionTint, with black or white text selected by PrimaryActionColors for the resolved accent. |

The non-key result panel and opaque semantic backing remain deliberate product
choices. They preserve insertion focus and protect body-text contrast.

## Native menu investigation, UX-004

The baseline status menu uses standard NSMenuItem title/subtitle rendering,
without app-defined foreground colors. In the sampled Clear/Dark/white-backdrop
state, enabled title contrast was 2.68:1 and subtitle contrast was 1.98:1. A
minimal native AppKit control also failed, at 3.65:1 and 2.47:1 respectively.
This establishes a platform contribution, not a complete attribution of the
difference between the two examples. Disabled native rows and section headers
were excluded from the finding.

The installed SDK 27 NSMenuItem.h exposes attributedTitle but only a plain
String subtitle. It has no attributedSubtitle or subtitle foreground-color
property. Customizing the title alone therefore does not address both measured
failures. NSMenuItem.view could replace the system renderer, but it would add
responsibility for highlight, sizing, accessibility, keyboard behavior and
menu appearance. Forcing a menu appearance would violate this family's system
appearance rule. No workaround has been established as sufficient.

Keep UX-004 open. Before adopting custom menu rendering, prototype and measure
idle and highlighted enabled rows over the backdrop sweep in both appearances,
including contrast/transparency preferences. Preserve native commands and AX
semantics. A custom menu is a product decision, not part of the five approved
fixes.

Sources: Apple HIG [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts),
[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons),
[Menus](https://developer.apple.com/design/human-interface-guidelines/menus),
[NSMenuItem](https://developer.apple.com/documentation/appkit/nsmenuitem),
SDK 27 AppKit/NSMenuItem.h, and the shared macOS family rules.

## Verification

Candidate verification uses the signed development bundle and synthetic data.
The confirmation uses a sheet with normal bordered buttons: native alert
button tint ignored the content tint, and its destructive text measured below
the contrast target. Deletion runs in onDismiss so the presenting row remains
valid until the sheet has closed. PrimaryActionText also follows appearsActive,
using primary text on the system gray backing of an inactive control.

The signed candidate was reviewed in 118 final frames: 76 Settings/onboarding,
40 production-popup renderer states and two inactive Settings states. Native
checks completed in both appearances, covering all ten shipped languages for
confirmation, editor naming and onboarding feedback/instructions; en/ru/de
also have editor/recorder captures. Popup states cover en/ru/de and all eight
system accents in both appearances. Accent overrides were launch arguments,
not global preference changes.

All 618 sampled app-content static text regions and 208 sampled text actions
passed 4.5:1. The lowest action sample was 4.91:1, white on the dark red accent;
blue actions measured 5.37:1 light and 6.27:1 dark. Measurements exclude disabled
Continue, dimmed content behind sheets, native title-bar text and combined
native toolbar icon/label rectangles. Those regions do not establish a
text-only contrast sample for the changed controls. Inactive recorder text
uses semantic primary text against the system gray backing.

The geometry pass covered 118 frames and found six overflow candidates, all
long-popup scroll content. Visual review confirmed the scroll/fade behavior;
no clipped action or overlapping control was found. Precision candidates
reflect semantic grouping, native optical offsets and existing 24/28 pt
secondary/primary button sizing; none was confirmed as a visual defect.

PrimaryActionColorsTests checks bright/dark colors and grayscale values around
the foreground transition. A copied-source mutation forcing all text white
failed both tests with 32 assertions; the unmodified copy passed both. The
native verification also checks cancellation, confirmed pair/preset removal,
editor AX names, assigned/unassigned shortcuts and Settings destinations.

VoiceOver, Voice Control, Switch Control, actual microphone/recognition,
translation, model download and clipboard delivery remain untested. Popup and
onboarding fixtures establish rendering and routing, not backend readiness.
The system appearance and live accessibility flags were restored exactly;
the dev preferences matched their original export after restoration.

Full gate results: `bash maintain.sh` passed with 270 XCTest tests, 16 skipped
and zero failures, followed by the signed assembled bundle. No commit, push,
tag or release was performed. UX-004 remains open as the separate menu
investigation above. Detailed reproducible evidence is retained in the local
UI audit artifact folder outside the repository.
