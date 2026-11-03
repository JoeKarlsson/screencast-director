#!/usr/bin/env bash
# Compiles a check program against DirectorCore with plain swiftc and runs it. Swift Testing and
# XCTest need Xcode, and this has to work with the Command Line Tools. test.sh, playback-test.sh and
# media-test.sh call it; a compile error fails the run (set -e) rather than rerunning an old build.
#
#   macos/run-checks.sh <name> <check files...>
set -euo pipefail
cd "$(dirname "$0")"
name=$1
shift
mkdir -p .build/checks
swiftc -swift-version 5 -parse-as-library -suppress-warnings -target arm64-apple-macos15.0 \
  Sources/DirectorCore/*.swift "$@" -o ".build/checks/$name"
".build/checks/$name"
