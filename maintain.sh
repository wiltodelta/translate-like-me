#!/bin/bash

set -e

if command -v swiftlint >/dev/null 2>&1; then
    swiftlint lint --fix
    # `--fix` prints only what it corrected, so warnings it cannot fix would pass
    # unreported; fail on them here as CI does.
    swiftlint lint --strict --quiet
else
    echo "swiftlint not installed, skipping lint (brew install swiftlint)"
fi

swift test
swift build -c release
