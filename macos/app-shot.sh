#!/usr/bin/env bash
# Screenshot the editor on a recording, so an agent can see a UI change. Launches the dist/ build on
# a copy of the project in a temp folder (your recording and your installed copy are never touched,
# the same way smoke-test.sh runs), waits for its window, brings it forward and captures just
# that window.
#
#   macos/app-shot.sh <project-dir> <out.png> [--no-build] [--wait <seconds>] [-- <app arguments>]
#
#   macos/app-shot.sh ../projects/fixture /tmp/editor.png
#   macos/app-shot.sh ~/Movies/"Screencast Director"/Demo /tmp/e.png --no-build -- -showPublish YES
#
# Arguments after -- go to the app (defaults like `-ai.provider claudeCode`). --wait (default 4)
# gives the preview time to draw its first frame. Needs a logged-in GUI session, plus Accessibility
# and Screen Recording permission for your terminal.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$here/.." && pwd)"
APP="$ROOT/dist/Screencast Director.app"

[[ $# -ge 2 ]] || { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
project="$(cd "$1" && pwd)"
out="$2"
shift 2
build=1 wait=4 app_args=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --no-build) build=0; shift ;;
    --wait) wait=$2; shift 2 ;;
    --) shift; app_args=("$@"); break ;;
    *) echo "app-shot: unknown option $1" >&2; exit 2 ;;
  esac
done
[[ -f "$project/source.json" ]] || { echo "app-shot: no recording at $project (no source.json)" >&2; exit 1; }
[[ "$out" == /* ]] || out="$PWD/$out"

[[ $build == 0 ]] || "$here/build.sh" >/dev/null
[[ -x "$APP/Contents/MacOS/ScreencastDirector" ]] || { echo "app-shot: no build at $APP (run without --no-build)" >&2; exit 1; }

TMP="$(mktemp -d -t sd-shot)"
PID=""
cleanup() {
  [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

copy="$TMP/$(basename "$project")"
# A clone on APFS, so a long recording copies instantly.
cp -c -R "$project" "$copy" 2>/dev/null || cp -R "$project" "$copy"
swiftc -suppress-warnings "$here/Tests/AXPress.swift" -o "$TMP/axpress"

"$APP/Contents/MacOS/ScreencastDirector" -projectsFolder "$TMP" -openProject "$copy" -ApplePersistenceIgnoreState YES \
  -"NSWindow Frame main" "120 60 1400 860 0 0 1512 982" ${app_args[@]+"${app_args[@]}"} >"$TMP/app.log" 2>&1 &
PID=$!

window=""
for _ in $(seq 1 60); do
  window="$("$TMP/axpress" "$PID" window-id 2>/dev/null)" && break
  kill -0 "$PID" 2>/dev/null || { echo "app-shot: the app exited:" >&2; cat "$TMP/app.log" >&2; exit 1; }
  sleep 0.5
done
[[ -n "$window" ]] || { echo "app-shot: no window after 30 s" >&2; exit 1; }

# A window on another Space captures with a black player, so bring it forward first.
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null
sleep "$wait"
window="$("$TMP/axpress" "$PID" window-id)"
screencapture -x -o -l "$window" "$out"
[[ -s "$out" ]] || { echo "app-shot: screencapture wrote nothing (Screen Recording permission?)" >&2; exit 1; }
echo "$out"
