#!/usr/bin/env bash
# Every test, in order: lint, the checks, playback, the CLI, animation renders, the input logger, then
# the UI smoke test (which builds dist/, needs a GUI session, and sends key presses, so don't type
# while it runs). Run it before pushing changes to the app; CI runs everything but the smoke test.
#
#   macos/test-all.sh
set -euo pipefail
cd "$(dirname "$0")"
for step in ./lint.sh ./test.sh ./playback-test.sh ./media-test.sh ./cli-test.sh ./animate-test.sh ../test/logger-test.sh ./smoke-test.sh; do
  echo "== $step"
  "$step"
done
echo "all tests passed"
