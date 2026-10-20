Translate Like Me 3.7.0

- Use the interface in Russian, German, French, Spanish, Japanese, Simplified Chinese, Brazilian Portuguese, Italian or Korean, following your macOS language.
- Translate and Rewrite with Antigravity CLI, alongside Claude Code, Codex and Grok Build. Engine names now match their command-line tools.
- Dictation uses macOS voice processing, with echo cancellation and noise suppression. Other audio is temporarily ducked while you hold the dictation key.
- Remove trailing `[BLANK_AUDIO]` annotations from dictation results, including repeated annotations after long sentences.
- Ignore duplicate modifier events for the held Option key, while preserving cancellation when you type or use another shortcut.
- Add metadata diagnostics and isolated installation checks to help distinguish keyboard cancellation, capture and recognition failures. Audio and dictated text are never included in these diagnostics.

Known compatibility issue: the user-reported conflict with Punto Switcher is not fixed. Completely quitting Punto Switcher restored dictation on the affected Mac.

Audio processing depends on the devices and playback level. Complete physical voice-preservation and audible-restoration validation remains open.
