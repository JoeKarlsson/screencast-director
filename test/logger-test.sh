#!/usr/bin/env bash
# Checks the input logger's event records with synthetic events (no Input Monitoring needed), and
# that DirectorCore reads what it writes. Runs in CI.
#
#   test/logger-test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/macos/.build/checks"
mkdir -p "$OUT"
rm -f "$OUT/logger-checks"
swiftc -swift-version 5 -parse-as-library -suppress-warnings -target arm64-apple-macos15.0 \
  "$ROOT"/macos/Sources/DirectorCore/*.swift "$ROOT/logger/InputEvents.swift" "$ROOT/test/LoggerChecks.swift" -o "$OUT/logger-checks"
"$OUT/logger-checks"
