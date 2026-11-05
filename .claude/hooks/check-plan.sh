#!/usr/bin/env bash
# PostToolUse hook: after Claude edits a recording's plan.json, run `director validate` on it and hand
# any problems back (exit 2 puts stderr in front of Claude), so a typo'd key or an overlap is fixed
# in the same turn instead of silently doing nothing.
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
