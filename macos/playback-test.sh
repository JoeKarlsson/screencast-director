#!/usr/bin/env bash
# Headless playback check: plays a composition built from a synthetic recording through
# AVPlayerItemVideoOutput and fails on missing or black frames. Needs no screen, ffmpeg or fixtures.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/checks
swiftc -swift-version 5 -parse-as-library -suppress-warnings -target arm64-apple-macos15.0 Sources/DirectorCore/*.swift Tests/Playback.swift \
  -o .build/checks/playback
.build/checks/playback
