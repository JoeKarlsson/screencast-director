#!/usr/bin/env bash
# Every test, in order: lint, the checks, playback, the CLI, animation renders, then
# the UI smoke test (which builds dist/, needs a GUI session, and sends key presses, so don't type
# while it runs). Run it before pushing changes to the app; CI runs everything but the smoke test.
#
#   macos/test-all.sh              everything
#   macos/test-all.sh --no-smoke   everything but the smoke test (what CI runs)
#
# A new test suite goes in this list, and CI picks it up.
set -euo pipefail
cd "$(dirname "$0")"
steps=(./lint.sh ./test.sh ./playback-test.sh ./media-test.sh ./cli-test.sh ./animate-test.sh ./smoke-test.sh)
case "${1:-}" in
  "") ;;
  --no-smoke) unset 'steps[${#steps[@]}-1]' ;;
  *) echo "usage: macos/test-all.sh [--no-smoke]" >&2; exit 2 ;;
esac
for step in "${steps[@]}"; do
  echo "== $step"
  "$step"
done
echo "all tests passed"
