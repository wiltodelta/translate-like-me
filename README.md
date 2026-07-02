# Translate Like Me

A tiny macOS menu bar app that translates the selected text by global hotkey, with
an optional custom writing style applied after translation.

It supports two providers (Anthropic / OpenAI), each in two modes:

- **Subscription** — runs the official CLI (`claude` or `codex`), which uses your
  existing Claude Pro/Max or ChatGPT plan. No API key, no per-token billing.
- **API key** — calls the provider's HTTP API directly.

## How it works

- Detects the language automatically between the two languages you pick in the
  panel (no need to choose a direction).
- A global, configurable shortcut (default **⌥⌘R**) translates the current
  selection and replaces it in place.
- If the selection can't be replaced in place (read-only text, e.g. a Slack
  message you're reading rather than composing), the translation opens in a
  small popup near the cursor with a **Copy** button instead.
- A custom writing style from Settings is applied to the translation.

### Provider × auth matrix

| Provider | Subscription | API key |
|----------|--------------|---------|
| Anthropic (Claude) | `claude -p` (Pro/Max) | `POST /v1/messages` |
| OpenAI | `codex exec` (ChatGPT plan) | `POST /v1/chat/completions` |

Using the **official CLIs** with a subscription is an intended, supported way to run
Claude / Codex programmatically. (Extracting a subscription OAuth token and using it
in your own API client is *not* allowed — this app never does that; it only invokes
the official binary as a subprocess.)

The model is always resolved live, not pinned in the app: the CLI path uses the
`sonnet` alias (Claude) or your account's default (Codex); the API-key path picks
the newest matching model from the provider's live `/models` list.

## Build

```bash
./build.sh
open "Translate Like Me.app"
```

## First run

1. Launch the app. A small icon appears in the menu bar (no Dock icon). Settings
   opens automatically on first launch so you can pick a provider before using it.
2. Grant **Accessibility** in **System Settings ▸ Privacy & Security ▸ Accessibility**.
   It is required to read the selection (synthesized ⌘C) and to paste replacements
   (⌘V).

> `build.sh` signs the app with a stable local identity (see the comment at the top
> of the script) so the Accessibility grant survives rebuilds. If that identity is
> missing it falls back to ad-hoc signing, and macOS will ask for Accessibility
> again after every rebuild.

## Settings

- **Keyboard shortcut** — click the shortcut field and press a new combo to change
  it (must include a modifier).
- **Your writing style** — free text applied to the translation. You can paste a
  full voice guide or a short distilled version.
- **Translation engine** — provider (Claude/ChatGPT) and how to connect
  (subscription or API key).
- **API key** — stored per provider; shown only in API-key mode.
- **Launch at login** — toggle to start the app automatically.

Languages are picked on the main panel (click the menu bar icon), not in Settings.

## Notes

- The original clipboard is preserved: it's restored shortly after a successful
  paste, or immediately when the popup fallback is shown instead.
- Subscription (CLI) calls add a few seconds of latency per translation (CLI start
  + one model turn). API-key mode is faster.
- For the `codex` CLI, run `codex login` once (ChatGPT account) before using
  subscription mode.
- The system prompt explicitly tells the model to treat the selection as inert
  text to transform, never as a question or request directed at it — without this,
  models occasionally "answer" question- or request-shaped input instead of
  translating it. This is a known, recurring failure mode for small/fast models
  rather than a fully solved problem; if you see it, it's worth reporting which
  input triggered it.
