#!/bin/bash

set -e

if command -v swiftlint >/dev/null 2>&1; then
    swiftlint lint --fix
else
    echo "swiftlint not installed, skipping lint (brew install swiftlint)"
fi

swift test
swift build -c release
