#!/usr/bin/env bash
# Headless media pipeline checks (Tests/Media.swift): motion, audio extraction and loudness, analyze()
# and screen text (Vision OCR), joining takes, GIF export, publishing and the export queue on synthetic
# recordings; faces and lip sync on test/fixtures/talking-head.mp4; whisper-cli's JSON into transcript.json
# from test/fixtures/whisper-cli.json. Needs ffmpeg; no screen, whisper or model.
#
#   macos/media-test.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/checks
swiftc -swift-version 5 -parse-as-library -suppress-warnings -target arm64-apple-macos15.0 Sources/DirectorCore/*.swift Tests/Media.swift \
  -o .build/checks/media
.build/checks/media
