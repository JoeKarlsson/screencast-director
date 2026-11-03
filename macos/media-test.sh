#!/usr/bin/env bash
# Headless media pipeline checks (Tests/Media.swift): motion, audio extraction and loudness, analyze()
# and screen text (Vision OCR), joining takes, GIF export, publishing and the export queue on synthetic
# recordings; faces and lip sync on test/fixtures/talking-head.mp4; whisper-cli's JSON into transcript.json
# from test/fixtures/whisper-cli.json. Needs ffmpeg; no screen, whisper or model.
#
#   macos/media-test.sh
set -euo pipefail
cd "$(dirname "$0")"
./run-checks.sh media Tests/Media.swift
