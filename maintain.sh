#!/bin/bash
# Shared by translate-like-me, watch-me-sleep and rota: change every copy together
# (claude-config docs/macos-apps.md, "Shared files").
# The canonical gate: lint with fixes, tests, then the release bundle.

set -e
cd "$(dirname "$0")"

command -v swiftlint >/dev/null 2>&1 ||
    { echo "error: swiftlint is not installed (brew install swiftlint)" >&2; exit 1; }
swiftlint lint --fix
# `--fix` prints only what it corrected; fail on what it could not fix, as CI does.
swiftlint lint --strict --quiet

swift test
# The bundle, not a bare `swift build -c release`: assembly, actool, Sparkle
# embedding, signing and the SDK stamp check would otherwise run only in CI.
./build.sh
