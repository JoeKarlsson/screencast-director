#!/usr/bin/env bash
# Run the Swift checks (macos/Tests/Checks.swift) against DirectorCore with plain swiftc:
# Swift Testing and XCTest need Xcode, and this has to work with the Command Line Tools.
#
#   macos/test.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/checks
# Remove the last build first: a compile error must fail the run, not rerun stale checks.
rm -f .build/checks/checks
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 Sources/DirectorCore/*.swift Tests/Checks.swift \
  -o .build/checks/checks 2>&1 | grep -v "warning:" || true
[[ -x .build/checks/checks ]] || { echo "FAIL: the checks didn't compile" >&2; exit 1; }
.build/checks/checks
