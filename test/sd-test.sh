#!/usr/bin/env bash
# Checks bin/sd on a temp projects folder: help, import (with a camera and offset) and its errors,
# plan and describe through the director, and the parts of record that need no devices (reading the
# first frame's time from ffmpeg's log, the camera offset, source.json). Runs in CI.
#
#   test/sd-test.sh
# Needs ffmpeg and `say` (for the fixture).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SD="$ROOT/bin/sd"
swift build -c release --package-path "$ROOT/macos" --product director >/dev/null
TMP="$(mktemp -d -t sd-cli)"
trap 'rm -rf "$TMP"' EXIT
export SD_PROJECTS="$TMP/projects" SD_DIRECTOR="$ROOT/macos/.build/release/director"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() { echo "ok: $*"; }
json() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {}, {"d": d}))' "$1" "$2"; }

[[ "$("$SD")" == *"sd import <name> <video>"* ]] || fail "sd with no command doesn't print its usage"
ok "usage"

"$ROOT/test/make-fixture.sh" "$TMP/fixture" >/dev/null
video="$TMP/fixture/screen.mp4"

# import: the recording and a camera are copied in, and source.json describes them.
"$SD" import demo "$video" --camera "$video" --camera-offset 0.25 >/dev/null
src="$SD_PROJECTS/demo/source.json"
[[ -s "$SD_PROJECTS/demo/screen.mp4" && -s "$SD_PROJECTS/demo/camera.mp4" ]] || fail "import didn't copy the screen and camera"
[[ "$(json "$src" '(d["video"], d["width"], d["height"], round(d["duration"]), d["camera"])')" == \
  "('screen.mp4', 1920, 1080, 20, {'video': 'camera.mp4', 'offset': 0.25})" ]] || fail "import wrote a wrong source.json: $(cat "$src")"
[[ "$(json "$src" '"captureStart" in d')" == False ]] || fail "an import has no capture start"
ok "import copies the files and writes source.json"

# Its errors: an existing project, a missing file, an unknown option.
err=$("$SD" import demo "$video" 2>&1) && fail "importing over a project worked"
[[ "$err" == *"already exists"* ]] || fail "importing over a project: $err"
err=$("$SD" import other "$TMP/nope.mp4" 2>&1) && fail "importing a missing file worked"
[[ "$err" == *"no such file"* ]] || fail "importing a missing file: $err"
err=$("$SD" import other "$video" --loud 2>&1) && fail "an unknown option worked"
[[ "$err" == *"unknown option --loud"* ]] || fail "an unknown option: $err"
[[ ! -e "$SD_PROJECTS/other" ]] || fail "a failed import left a project behind"
ok "import refuses an existing project, a missing file and an unknown option"

# plan refuses a project that hasn't been analyzed (its draft would cut everything), then plans and
# describes it once there's a transcript (what sd analyze writes; Whisper isn't on CI).
err=$("$SD" plan demo 2>&1) && fail "planning an unanalyzed project worked"
[[ "$err" == *"sd analyze"* && ! -e "$SD_PROJECTS/demo/plan.json" ]] || fail "planning an unanalyzed project: $err"
cat >"$SD_PROJECTS/demo/transcript.json" <<'JSON'
{ "segments": [
  { "words": [ { "word": "Welcome", "start": 0.4, "end": 0.9 }, { "word": "today", "start": 1.0, "end": 1.5 } ] },
  { "words": [ { "word": "Now", "start": 10.3, "end": 10.6 }, { "word": "click", "start": 10.7, "end": 11.1 } ] }
] }
JSON
"$SD" plan demo >/dev/null
[[ "$(json "$SD_PROJECTS/demo/plan.json" 'len(d["segments"]) > 0')" == True ]] || fail "plan wrote no segments: $(head -c 600 "$SD_PROJECTS/demo/plan.json")"
described=$("$SD" describe demo)
[[ "$described" == *"## Layout"* ]] || fail "describe didn't print the timeline: ${described:0:300}"
err=$("$SD" plan missing 2>&1) && fail "planning a missing project worked"
[[ "$err" == *"no project at"* ]] || fail "planning a missing project: $err"
ok "plan and describe run on the imported project"

# What record does after ffmpeg stops, without devices: the first frame's host time from the log,
# the camera's offset, and a source.json the director loads.
# shellcheck source=bin/sd
source "$SD"
cat >"$TMP/ffmpeg.log" <<'LOG'
Input #0, avfoundation, from 'Capture screen 0:default':
  Duration: N/A, start: 51234.567800, bitrate: N/A
  Stream #0:0: Video: rawvideo (UYVY / 0x59565955), uyvy422, 3024x1964, 1000k tbr, 1000k tbn, start 51234.567800
  Stream #0:1: Audio: pcm_f32le, 48000 Hz, mono, flt, 1536 kb/s, start 51234.601000
LOG
[[ "$(capture_start "$TMP/ffmpeg.log")" == 51234.567800 ]] || fail "capture_start read $(capture_start "$TMP/ffmpeg.log")"
[[ "$(camera_offset 51234.5678 51234.3118)" == 0.256 && "$(camera_offset 100 100.064)" == -0.064 ]] \
  || fail "camera_offset: $(camera_offset 51234.5678 51234.3118), $(camera_offset 100 100.064)"
mkdir "$TMP/recorded"
cp "$video" "$TMP/recorded/screen.mp4"
write_source "$TMP/recorded" screen.mp4 51234.5678 camera.mp4 0.256
[[ "$(json "$TMP/recorded/source.json" '(d["captureStart"], d["camera"]["offset"])')" == "(51234.5678, 0.256)" ]] \
  || fail "write_source: $(cat "$TMP/recorded/source.json")"
# Input events on the same host clock: a click 7 s into the recording.
printf '%s\n' '{"type":"meta","clock":"uptime_raw","t":51234.5}' '{"type":"click","t":51241.5678,"x":0.75,"y":0.29}' >"$TMP/recorded/events.jsonl"
"$SD_DIRECTOR" plan "$TMP/recorded" >/dev/null || fail "the director couldn't plan from a recorded source.json"
described=$("$SD_DIRECTOR" describe "$TMP/recorded")
[[ "$described" == *"0:07.0"* ]] || fail "the click at 7 s didn't line up with the recording: ${described:0:400}"
ok "record's capture start, camera offset and source.json"
echo "sd checks passed"
