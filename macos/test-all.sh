#!/usr/bin/env bash
# Every test, in order: lint, the checks, playback, the CLI, animation renders. The UI smoke test
# runs only with --smoke: it brings its own copy of the app to the front and clicks its title bar,
# which takes over whatever Joe is doing, so run it only when he says the Mac is free.
#
#   macos/test-all.sh            everything but the smoke test (what CI runs)
#   macos/test-all.sh --smoke    and then the smoke test
#
# A new test suite goes in this list, and CI picks it up.
set -euo pipefail
cd "$(dirname "$0")"
steps=(./lint.sh ./test.sh ./playback-test.sh ./media-test.sh ./cli-test.sh ./animate-test.sh)
case "${1:-}" in
  "" | --no-smoke) ;;
  --smoke) steps+=(./smoke-test.sh) ;;
  *) echo "usage: macos/test-all.sh [--smoke]" >&2; exit 2 ;;
esac
for step in "${steps[@]}"; do
  echo "== $step"
  "$step"
done
echo "all tests passed"
