#!/usr/bin/env bash
# Build a self-contained whisper-cli to bundle in the app (same approach as Followspot's
# whisper-server): static, Metal shaders embedded. Optional: without it the app uses Homebrew's.
#
#   macos/build-whisper.sh   # → macos/.whisper/whisper-cli
set -euo pipefail

cd "$(dirname "$0")"
VERSION="${WHISPER_CPP_VERSION:-v1.9.4}"
SRC=".whisper/whisper.cpp-${VERSION}"
command -v cmake >/dev/null || { echo "cmake not found: brew install cmake" >&2; exit 1; }
[[ -d "$SRC" ]] || git clone --depth 1 --branch "$VERSION" https://github.com/ggml-org/whisper.cpp "$SRC"
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF
cmake --build "$SRC/build" -j --target whisper-cli
cp "$SRC/build/bin/whisper-cli" .whisper/whisper-cli
echo "Built macos/.whisper/whisper-cli"
