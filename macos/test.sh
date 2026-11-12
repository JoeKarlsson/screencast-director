#!/usr/bin/env bash
# Run the Swift checks (macos/Tests/Checks*.swift) against DirectorCore with plain swiftc:
# Swift Testing and XCTest need Xcode, and this has to work with the Command Line Tools.
#
#   macos/test.sh
set -euo pipefail
cd "$(dirname "$0")"
# Its own support folder, so profiles, packs and themes installed on this Mac don't change the result.
SD_SUPPORT_DIR="$(mktemp -d -t sd-checks)"
export SD_SUPPORT_DIR
trap 'rm -rf "$SD_SUPPORT_DIR"' EXIT
./run-checks.sh checks Tests/Checks*.swift
