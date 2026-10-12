#!/usr/bin/env bash
# Lint the Swift code with SwiftLint (rules in .swiftlint.yml) and the shell scripts with ShellCheck.
# SwiftLint warnings print; errors fail.
#
#   macos/lint.sh            # needs `brew install swiftlint shellcheck`
set -euo pipefail
cd "$(dirname "$0")/.."
for tool in swiftlint shellcheck; do
  command -v $tool >/dev/null || { echo "$tool not found: brew install $tool" >&2; exit 1; }
done
shellcheck bin/sd logger/build.sh macos/*.sh test/*.sh
# SwiftLint loads SourceKit from Xcode. With only the Command Line Tools, point it there.
if [ -z "${TOOLCHAIN_DIR:-}" ] && ! xcode-select -p | grep -q Xcode.app; then
  export TOOLCHAIN_DIR=/Library/Developer/CommandLineTools
fi
swiftlint lint --quiet "$@"
