#!/bin/bash
# Build MLX's native Metal kernels with its pinned upstream CMake recipe.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v cmake >/dev/null || { echo 'error: cmake is required (brew install cmake)' >&2; exit 1; }
CHECKOUT="$PWD/.build/checkouts/mlx-swift"
REVISION="$(git -C "$CHECKOUT" rev-parse HEAD)"
SDK="$(xcrun --show-sdk-version)"
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
METAL_BUILD="$PWD/.build/mlx-metal/$REVISION-sdk$SDK-min$MIN_MACOS"
cmake -S "$CHECKOUT/Source/Cmlx/mlx" -B "$METAL_BUILD" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    -DCMAKE_OSX_SYSROOT="$(xcrun --show-sdk-path)" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DMLX_BUILD_TESTS=OFF -DMLX_BUILD_EXAMPLES=OFF -DMLX_BUILD_CPU=OFF \
    -DMLX_BUILD_GGUF=OFF -DMLX_METAL_JIT=ON \
    -DFETCHCONTENT_SOURCE_DIR_FMT="$CHECKOUT/Source/Cmlx/fmt" \
    -DFETCHCONTENT_SOURCE_DIR_JSON="$CHECKOUT/Source/Cmlx/json"
cmake --build "$METAL_BUILD" --target mlx-metallib --parallel 4
# The caller supplies the exact SwiftPM output directory, not a guessed path.
cp "$METAL_BUILD/mlx/backend/metal/kernels/mlx.metallib" "$1/mlx.metallib"
