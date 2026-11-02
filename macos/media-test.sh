#!/usr/bin/env bash
# Headless media pipeline checks (Tests/Media.swift): motion, audio extraction and loudness, analyze()
# and screen text (Vision OCR), joining takes, GIF export and publishing, on synthetic recordings.
# Needs ffmpeg (to mux the test audio); no screen, whisper or fixtures.
#
#   macos/media-test.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/checks
swiftc -swift-version 5 -parse-as-library -suppress-warnings -target arm64-apple-macos15.0 Sources/DirectorCore/*.swift Tests/Media.swift \
  -o .build/checks/media
.build/checks/media
