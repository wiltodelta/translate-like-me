# CLI translation latency

October 22, 2026. claude 2.1.308, codex-cli 0.163.0, grok 1.0.67, one short
Russian sentence, the app's own flags, on a ChatGPT, Claude and Grok
subscription.

Each CLI writes its answer well before the process exits:

| CLI | Answer to exit | How the answer is read |
|---|---|---|
| claude | 0.52-0.68 s (4 runs) | `--output-format stream-json --verbose`, the `result` event |
| codex | 0.83-0.86 s (2 runs) | `exec --json`, the last `agent_message` once `turn.completed` arrives |
| grok | 1.04-1.06 s (2 runs) | `--output-format streaming-json`, `text` events up to `end` |

`ProcessRunner.run(answered:)` returns as soon as the stream holds a complete
answer; the child then exits on its own, or the translation deadline kills its
process group. Failures still wait for the exit status, and `runStream` hands
`FailureDetail` the text the plain output carried: claude's `result` text, and
codex's `error` events as the `ERROR:` lines plain mode wrote to stderr (grok
already repeats its error on stderr).

Through `Translator.translate`, claude alternating with its previous text-mode
invocation: 4 of 4 pairs faster, 1.9-3.6 s against 2.5-4.7 s, identical
translations. codex and grok answered correctly through the new path (two runs
each, 3.8-4.6 s and 4.9-5.3 s); their gain is the measured exit lag, not a
paired comparison. No CLI process outlived its run. The predicate parses only
the last complete line until it is the final event; reading each stream in raw
chunks showed that event ending a read before exit (claude 0.80 s, codex 1.06 s,
grok 0.72 s early, one run each).

Ruled out for claude: `--bare` reads only `ANTHROPIC_API_KEY`, not the
subscription; `--safe-mode` and `--disable-slash-commands` left the same 13,030
context tokens and no faster start. A process started before the text arrives
gains nothing: claude does its ~1.1 s of setup after reading stdin, and gives up
after 3 s without input. Starting each CLI binary alone (`--version`) takes about 25 ms.
