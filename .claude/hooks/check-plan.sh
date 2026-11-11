#!/usr/bin/env bash
# PostToolUse hook: after Claude edits a recording's plan.json, run `director validate` on it and hand
# any problems back (exit 2 puts stderr in front of Claude), so a typo'd key or an overlap is fixed
# in the same turn instead of silently doing nothing. A valid plan then gets `review --retention`'s
# notes (structure for the video's length) as context, which don't block.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
file=$(python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("tool_input", {}).get("file_path", ""))')
[[ "$(basename "$file")" == plan.json ]] || exit 0
dir=$(dirname "$file")
# Only a recording's plan (it sits next to source.json), not some other plan.json.
[[ -f "$dir/source.json" ]] || exit 0
if ! out=$("$ROOT/bin/director" validate "$dir" 2>&1); then
  printf 'director validate found problems in %s:\n%s\nFix them (or say why one should stay).\n' "$file" "$out" >&2
  exit 2
fi
# bin/director just rebuilt the binary for validate; calling it straight skips a second build check (6-60 s).
if ! notes=$("$ROOT/macos/.build/release/director" review "$dir" --retention 2>&1); then
  printf 'director review --retention failed on %s:\n%s\n' "$file" "$notes" >&2
  exit 1
fi
[[ -n "$notes" ]] || exit 0
NOTES="$notes" python3 -I -c 'import json, os; print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext":
  os.environ["NOTES"] + "\nThese are judgment calls, not errors: fix the ones this edit caused, and mention the rest to the user (or run /retention-pass)."}}))'
