# Translate Like Me

A tiny macOS menu-bar app that translates the current selection with a global
hotkey and rewrites it in your own writing style. Select text in any app, press
the shortcut, and the selection is replaced in place with the translation.

It detects the direction automatically between the two languages you choose, so
there is nothing to switch: type in one, get the other.

## Features

- **Translate in place**: replaces the selected text directly, in any app.
- **Automatic direction**: detects which of your two languages you wrote in and
  translates to the other.
- **Your writing style**: an optional style description is applied to every
  translation so the result sounds like you.
- **Bring your own engine**: Claude or ChatGPT, each via your existing
  subscription (official CLI) or your own API key.
- **Always the latest model**: resolved live, never pinned in the app.
- **Menu-bar only**: no Dock icon, no window in the way. Left-click for the
  panel, right-click for a quick menu.
- **Update checks**: checks GitHub Releases on launch and from Settings.

## Requirements

- macOS 13 or later.
- For subscription mode: the provider's official CLI installed and signed in
  (`claude` for Claude, `codex` for ChatGPT). For API-key mode: an API key.

## Install

### From a release

1. Download the latest `.zip` from the
   [Releases](https://github.com/wiltodelta/translate-like-me/releases) page.
2. Unzip it and move **Translate Like Me.app** to `/Applications`.
3. Launch it. Because the build is self-signed for personal use (not notarized),
   macOS may warn on first launch. Right-click the app and choose **Open** to
   confirm once.

### From source

```bash
git clone https://github.com/wiltodelta/translate-like-me.git
cd translate-like-me
./build.sh
open "Translate Like Me.app"
```

`build.sh` signs the app with a stable local identity (see the comment at the top
of the script) so the Accessibility grant survives rebuilds. If that identity is
missing it falls back to ad-hoc signing, and macOS asks for Accessibility again
after every rebuild.

## First run

1. A small icon appears in the menu bar (there is no Dock icon). Settings opens
   automatically on first launch so you can pick a provider and languages.
2. Grant **Accessibility** in **System Settings ▸ Privacy & Security ▸
   Accessibility**. It is required to read the selection (synthesized ⌘C) and to
   paste the replacement (⌘V).

## Usage

- Select text in any app, then press the shortcut (default **⌥⌘F**) to replace it
  with the translation.
- **Left-click** the menu-bar icon to open the panel (languages, shortcut, status).
- **Right-click** the icon for a quick menu (Settings, Quit).
- The icon shows a busy glyph while a translation is running.
- If the selection can't be replaced in place (a read-only field, e.g. a message
  you are reading rather than writing), the translation is put on the clipboard
  and shown in a small popup near the cursor, so it is never lost.
- If something goes wrong (no text selected, or the translation fails), that same
  popup shows the message instead.

## Settings

- **Keyboard shortcut**: click the field and press a new combo to change it (must
  include a modifier).
- **Your writing style**: free text applied to the translation. Paste a full
  voice guide or a short distilled version. Leave empty for a plain translation.
- **Translation engine**: provider (Claude / ChatGPT) and how to connect
  (subscription or API key).
- **API key**: stored per provider; shown only in API-key mode.
- **Launch at login**: start the app automatically when you log in.
- **Updates**: current version and a "Check for updates…" button.

Languages are picked on the main panel (left-click the icon), not in Settings.

## Providers and connection modes

Two providers, each in two modes:

| Provider           | Subscription            | API key                     |
|--------------------|-------------------------|-----------------------------|
| Anthropic (Claude) | `claude -p` (Pro/Max)   | `POST /v1/messages`         |
| OpenAI (ChatGPT)   | `codex exec` (ChatGPT)  | `POST /v1/chat/completions` |

**Subscription** runs the provider's official CLI as a subprocess, using the plan
you are already signed in to. No API key and no per-token billing beyond your
plan. For `codex`, run `codex login` once (ChatGPT account) before using it.

Using the official CLIs with a subscription is an intended, supported way to run
Claude / Codex programmatically. Extracting a subscription OAuth token and using
it in your own API client is not allowed; this app never does that. It only
invokes the official binary as a subprocess.

**API key** calls the provider's HTTP API directly with your own key (you pay the
provider per use). Keys are stored per provider and only used for that provider.

### Model selection

The model is always resolved live, not pinned in the app:

- Subscription: the `sonnet` alias (Claude) or your account's default (Codex).
- API key: the newest matching model from the provider's live `/models` list.

## Updates

The app checks GitHub Releases a few seconds after launch and offers to open the
download page when a newer version is tagged. You can also check on demand from
Settings ▸ Updates. It is a check-and-notify updater, not a silent in-place
installer: you download the new build and replace the app yourself.

## Notes

- The original clipboard is preserved: it is restored shortly after a successful
  paste. When the selection can't be replaced (a read-only field), the translation
  is left on the clipboard instead so you can paste it yourself.
- Subscription (CLI) calls add a few seconds of latency per translation (CLI
  startup plus one model turn). API-key mode is faster.
- The system prompt tells the model to treat the selection as inert text to
  transform, never as a question or request directed at it. Without this, small
  fast models occasionally "answer" question-shaped input instead of translating
  it. It is a known, recurring failure mode rather than a fully solved problem; if
  you see it, note which input triggered it.

## Building and releasing

Build a bundle:

```bash
./build.sh
```

Cut a release (self-signed, for personal use):

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist` (for example
   `1.0` to `1.1`). This is the single source of the app version.
2. Build and package:
   ```bash
   ./build.sh
   ditto -c -k --sequesterRsrc --keepParent "Translate Like Me.app" "Translate Like Me.zip"
   ```
3. Create the release, matching the tag to the version:
   ```bash
   gh release create v1.1 "Translate Like Me.zip" \
     --title "Translate Like Me 1.1" --target main --notes "What changed"
   ```

The tag must match the version (`v1.1` ↔ `1.1`), and the `.zip` must be attached,
or the in-app updater has nothing to offer.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for the
full text.
