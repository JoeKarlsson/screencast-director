#!/usr/bin/env bash
# UI smoke test: builds dist/Screencast Director.app, launches that copy on a synthetic project in a
# temp folder, and drives it through System Events: the editor opens, pressing a timeline bar
# selects it, the inspector shows the clip, S changes its speed in plan.json, ⌘Z undoes it, and the
# Audio tab's sound picker adds a library sound.
#
#   macos/smoke-test.sh             # build, then test
#   macos/smoke-test.sh --no-build  # test the existing dist build
#
# Safe to run next to your installed copy: it never touches /Applications or your projects folder
# (-projectsFolder points the test instance at the temp folder), finds its own window by PID
# (both copies have the same process name), and stops only the PID it started.
# Needs: a logged-in GUI session, Accessibility permission for your terminal, ffmpeg (for the
# fixture). It sends two key presses, so don't type while it runs.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP="$ROOT/dist/Screencast Director.app"

[[ "${1:-}" == "--no-build" ]] || ./build.sh

TMP="$(mktemp -d -t sd-smoke)"
PROJECT="$TMP/fixture"
PID=""
cleanup() {
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

"$ROOT/test/make-fixture.sh" "$PROJECT" >/dev/null
AXPRESS="$TMP/axpress"
swiftc -suppress-warnings Tests/AXPress.swift -o "$AXPRESS"
"$APP/Contents/MacOS/director" plan "$PROJECT" >/dev/null
# The fixture's plan ends with a 1x clip at 10.5-13.1 s; the test changes its speed and undoes it.
segments() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["segments"], sort_keys=True))' "$PROJECT/plan.json"; }
last_speed() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["segments"][-1]["speed"])' "$PROJECT/plan.json"; }
original="$(segments)"
[[ "$(last_speed)" == 1 ]] || fail "fixture plan changed: expected the last clip at 1x"

"$APP/Contents/MacOS/ScreencastDirector" -projectsFolder "$TMP" -openProject "$PROJECT" >"$TMP/app.log" 2>&1 &
PID=$!
echo "launched test instance, PID $PID"

# Runs AppleScript against the test instance's process. $1 is the body, inside
# `tell process`; EDITOR, TIMELINE and INSPECTOR are spelled out in it.
ax() {
  osascript - "$PID" <<OSA
on run argv
  set pid to (item 1 of argv) as integer
  with timeout of 30 seconds
    tell application "System Events"
      tell (first process whose unix id is pid)
        $1
      end tell
    end tell
  end timeout
end run
OSA
}
EDITOR='group 2 of splitter group 1 of group 1 of window 1'
TIMELINE="scroll area 1 of group 1 of splitter group 1 of $EDITOR"
INSPECTOR="scroll area 1 of group 2 of splitter group 1 of $EDITOR"

# Key presses go to the frontmost app, so bring the test instance forward and check it got there.
front() {
  for _ in 1 2 3; do
    [[ "$(ax 'set frontmost to true
        delay 0.4
        return frontmost')" == true ]] && return 0
  done
  fail "couldn't bring the test instance to the front"
}

# 1. The editor appears with the project's timeline.
bars=0
for _ in $(seq 1 60); do
  bars="$(ax "if (count of windows) = 0 then return 0
      try
        return count of buttons of $TIMELINE
      on error
        return 0
      end try" 2>/dev/null || echo 0)"
  [[ "$bars" -ge 4 ]] && break
  sleep 0.5
done
[[ "$bars" -ge 4 ]] || fail "editor didn't show the timeline (found $bars bars)"
echo "ok: editor open, $bars timeline bars"

# 2. Pressing the 10.5-13.1 s clip selects it and the inspector shows it. Bars have no AX labels and
# their order shifts as rows are added, so press each until the inspector shows that clip.
inspector=""
for i in $(seq 1 "$bars"); do
  inspector="$(ax "perform action \"AXPress\" of button $i of $TIMELINE
      delay 0.6
      set AppleScript's text item delimiters to \" / \"
      return (value of static texts of $INSPECTOR) as text")"
  [[ "$inspector" == Clip* && "$inspector" == *"0:10.5–"* ]] && break
done
[[ "$inspector" == Clip* && "$inspector" == *"0:10.5–"* ]] || fail "inspector doesn't show the clip: $inspector"
echo "ok: inspector shows: $inspector"
[[ "$(segments)" == "$original" ]] || fail "selecting a clip changed plan.json"

# 3. S changes the selected clip's speed, and it's saved.
front
ax 'key code 1' >/dev/null # S
for _ in $(seq 1 20); do [[ "$(last_speed)" != 1 ]] && break; sleep 0.2; done
speed="$(last_speed)"
[[ "$speed" != 1 ]] || fail "S didn't change the clip's speed in plan.json"
echo "ok: S set the clip to ${speed}x in plan.json"

# 4. ⌘Z undoes it.
front
ax 'key code 6 using command down' >/dev/null # ⌘Z
for _ in $(seq 1 20); do [[ "$(segments)" == "$original" ]] && break; sleep 0.2; done
[[ "$(segments)" == "$original" ]] || fail "⌘Z didn't restore plan.json (last clip at $(last_speed)x)"
echo "ok: ⌘Z restored the original plan"

# 5. The Audio tab's sound picker adds a library sound: plan.json names it and the project gets a copy.
# SwiftUI buttons here have no AX title, so they're found by their help text.
# Buttons are found through the test instance's PID (Tests/AXPress.swift): AppleScript's
# `entire contents` references name the process, so they'd reach the installed copy when it's running.
press_help() { "$AXPRESS" "$PID" help "$1"; }
[[ "$(press_help "Audio")" == pressed ]] || fail "no Audio tab in the inspector"
sleep 1
[[ "$(press_help "Pick a sound effect to add at the playhead")" == pressed ]] || fail "no Add Sound Effect button in the Audio tab"
sleep 1
[[ "$(press_help "Add pop at the playhead")" == pressed ]] || fail "the sound picker didn't list pop"
sounds() { python3 -c 'import json,sys; print(" ".join(e["file"] for e in json.load(open(sys.argv[1])).get("sfx") or []))' "$PROJECT/plan.json"; }
for _ in $(seq 1 20); do [[ "$(sounds)" == *sfx/pop.m4a* ]] && break; sleep 0.2; done
[[ "$(sounds)" == *sfx/pop.m4a* ]] || fail "adding pop didn't reach plan.json (sfx: $(sounds))"
[[ -s "$PROJECT/sfx/pop.m4a" ]] || fail "adding pop didn't copy it into the project's sfx folder"
echo "ok: the sound picker added pop to plan.json and copied it into the project"

# 6. The sound shows on the Sound FX row: pressing its chip selects it, the inspector's volume slider
# sets its level, ⌫ removes it, and ⌘Z brings it back.
chip="$("$AXPRESS" "$PID" description "Sound effect pop*")"
[[ "$chip" == pressed ]] || fail "no pop chip on the Sound FX row"
sleep 1
gain() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])).get("sfx") or []; print(s[0].get("gainDB", 0) if s else "none")' "$PROJECT/plan.json"; }
before_gain="$(gain)"
ax "perform action \"AXIncrement\" of slider 1 of $INSPECTOR" >/dev/null || fail "no volume slider for the selected sound"
for _ in $(seq 1 20); do [[ "$(gain)" != "$before_gain" ]] && break; sleep 0.2; done
[[ "$(gain)" != "$before_gain" ]] || fail "the volume slider didn't change the sound's level (gainDB $(gain))"
echo "ok: the volume slider set the sound to $(gain) dB"
front
ax 'key code 51' >/dev/null # ⌫
for _ in $(seq 1 20); do [[ -z "$(sounds)" ]] && break; sleep 0.2; done
[[ -z "$(sounds)" ]] || fail "⌫ didn't remove the selected sound (sfx: $(sounds))"
echo "ok: ⌫ removed the sound"
front
ax 'key code 6 using command down' >/dev/null # ⌘Z
for _ in $(seq 1 20); do [[ "$(sounds)" == *sfx/pop.m4a* ]] && break; sleep 0.2; done
[[ "$(sounds)" == *sfx/pop.m4a* ]] || fail "⌘Z didn't bring the sound back"
echo "ok: ⌘Z brought the sound back"

# 7. Quit: stop the test instance by PID only.
kill "$PID"
for _ in $(seq 1 50); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
kill -0 "$PID" 2>/dev/null && fail "test instance didn't quit"
PID=""
echo "ok: test instance quit"
echo "smoke test passed"
