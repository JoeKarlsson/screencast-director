#!/usr/bin/env bash
# PostToolUse hook on Bash: after a `git push`, remind Claude that the work isn't done until CI
# passes. CI's compiler has rejected code that built locally (seven red runs in a row went unnoticed
# on 2026-11-04), so a passing local test-all isn't the last word.
set -uo pipefail
command=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))')
[[ "$command" =~ (^|[[:space:]\;\&\|])git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|-[^[:space:]]+))*[[:space:]]+push([[:space:]]|$) ]] || exit 0
[[ "$command" == *--dry-run* ]] && exit 0
python3 -I -c 'import json; print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext":
  "You pushed. CI runs test-all.sh --no-smoke on it: find the run with `gh run list -L 3 --json databaseId,headSha,status`, wait with "
  "`gh run watch <id> --exit-status` (in the background), and fix a failure before calling the work done."}}))'
