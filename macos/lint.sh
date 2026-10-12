#!/usr/bin/env bash
# Lint the Swift code with SwiftLint (rules in .swiftlint.yml). Warnings print; errors fail.
#
#   macos/lint.sh            # needs `brew install swiftlint`
set -euo pipefail
cd "$(dirname "$0")/.."
command -v swiftlint >/dev/null || { echo "swiftlint not found: brew install swiftlint" >&2; exit 1; }
# SwiftLint loads SourceKit from Xcode. With only the Command Line Tools, point it there.
if [ -z "${TOOLCHAIN_DIR:-}" ] && ! xcode-select -p | grep -q Xcode.app; then
  export TOOLCHAIN_DIR=/Library/Developer/CommandLineTools
fi
swiftlint lint --quiet "$@"
