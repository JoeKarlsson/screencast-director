#!/usr/bin/env bash
# Run the Swift checks (macos/Tests/Checks*.swift) against DirectorCore with plain swiftc:
# Swift Testing and XCTest need Xcode, and this has to work with the Command Line Tools.
#
#   macos/test.sh
set -euo pipefail
cd "$(dirname "$0")"
./run-checks.sh checks Tests/Checks*.swift
