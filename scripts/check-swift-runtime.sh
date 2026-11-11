#!/bin/bash
# Refuse a bundle that relies on Swift libraries from the build toolchain.
set -euo pipefail

APP="${1:?Usage: check-swift-runtime.sh APP}"
FRAMEWORKS="$APP/Contents/Frameworks"
REQUIRED="$(xcrun swift-stdlib-tool --print --scan-folder "$APP/Contents/MacOS" \
    --scan-folder "$FRAMEWORKS" --platform macosx)"
while IFS= read -r LIBRARY; do
    [[ -n "$LIBRARY" ]] || continue
    BUNDLED="$FRAMEWORKS/${LIBRARY##*/}"
    if [[ ! -f "$BUNDLED" ]]; then
        echo "error: missing Swift runtime library: $BUNDLED" >&2
        exit 1
    fi
    codesign --verify --strict "$BUNDLED"
done <<< "$REQUIRED"
