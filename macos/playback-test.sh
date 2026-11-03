#!/usr/bin/env bash
# Headless playback check: plays a composition built from a synthetic recording through
# AVPlayerItemVideoOutput and fails on missing or black frames. Needs no screen, ffmpeg or fixtures.
set -euo pipefail
cd "$(dirname "$0")"
./run-checks.sh playback Tests/Playback.swift
