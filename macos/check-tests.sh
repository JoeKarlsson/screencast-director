#!/usr/bin/env bash
# Fails when a feat: or fix: commit changes the engine, app or sd (macos/Sources, the animation
# templates, bin/) without adding or changing a test (macos/Tests, a macos/*-test.sh script, test/), unless
# its message has a "No test: <why>" line. CI runs it on every push and pull request.
#
#   macos/check-tests.sh <base>..<head>   # check every commit in a range
#   macos/check-tests.sh <commit>         # check one commit
set -euo pipefail
range="${1:?usage: macos/check-tests.sh <base>..<head> | <commit>}"
if [[ "$range" == *..* ]]; then
  commits=$(git rev-list --no-merges --reverse "$range")
else
  commits=$(git rev-parse "$range")
fi

missing=0
for c in $commits; do
  subject=$(git log -1 --format=%s "$c")
  [[ "$subject" =~ ^(feat|fix)(\(.+\))?!?: ]] || continue
  files=$(git diff-tree --no-commit-id --name-only -r "$c")
  grep -qE '^(macos/(Sources/|Resources/animations/)|bin/)' <<<"$files" || continue
  grep -qE '^(macos/Tests/|macos/[a-z-]+-test\.sh$|test/)' <<<"$files" && continue
  git log -1 --format=%B "$c" | grep -qE '^No test: .+' && continue
  echo "FAIL: ${c:0:7} $subject"
  echo "      changes macos/ code without a test; add one, or say why in a \"No test: <why>\" line"
  missing=$((missing + 1))
done
[[ "$missing" == 0 ]] || { echo "$missing commit(s) without tests" >&2; exit 1; }
echo "every feat/fix commit has a test"
