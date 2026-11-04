#!/usr/bin/env bash
# CLI check: runs the `director` commands and `bin/sd` against a synthetic project in a temp folder
# and checks what they did (plan.json edits, rendered files' size and length), plus that bad input
# fails with a message. Skips what needs a network or credentials (upload), Whisper (analyze with
# audio) and a face on camera (frame-camera, sync-camera beyond their error paths).
#
#   macos/cli-test.sh
#
# Needs ffmpeg and `say` (for the fixture). Never touches projects/.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
swift build -c release --product director >/dev/null
DIRECTOR="$PWD/.build/release/director"

TMP="$(mktemp -d -t sd-cli)"
# Scratch app settings and support folder (profiles, My Templates), so the real app's are untouched.
export SD_DEFAULTS_DOMAIN="sd-cli-test-$$" SD_SUPPORT_DIR="$TMP/support"
trap 'rm -rf "$TMP"; defaults delete "$SD_DEFAULTS_DOMAIN" >/dev/null 2>&1 || true' EXIT
P="$TMP/fixture"
"$ROOT/test/make-fixture.sh" "$P" >/dev/null

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
ok() { echo "ok: $*"; }
check() { # check <description> <command...>: passes when the command succeeds
  local what=$1; shift
  if "$@"; then ok "$what"; else fail "$what"; fi
}
# Runs a command that must fail, and checks its stderr mentions <text>.
expect_error() { # expect_error <description> <text> <command...>
  local what=$1 text=$2; shift 2
  local err
  if err=$("$@" 2>&1 >/dev/null); then fail "$what: exited 0"; return; fi
  if grep -qF -- "$text" <<<"$err"; then ok "$what"; else fail "$what: no \"$text\" in: $err"; fi
}
# Python one-liner over the plan: `plan` is plan.json, `argv` the extra arguments.
plan_py() { python3 -c "import json, sys; plan = json.load(open('$P/plan.json')); argv = sys.argv[1:]; $1" "${@:2}"; }
duration() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
stream_duration() { ffprobe -v error -select_streams "$2:0" -show_entries stream=duration -of csv=p=0 "$1"; }
near() { python3 -c "import sys; sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) <= float(sys.argv[3]) else 1)" "$@"; }
dims() { ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$1"; }
output_seconds() { plan_py "
segs = plan['segments']
print(sum((s['end'] - s['start']) / s['speed'] for s in segs))"; }

# The fixture's narration as a transcript, so captions, describe and pause trimming have words.
python3 - "$P/transcript.json" <<'PY'
import json, sys
lines = [(0.3, "Welcome. Today I will show you how this works."), (10.2, "Now I click the blue box and press a keyboard shortcut."),
         (17.2, "And that is the whole demo. Thanks for watching.")]
segments = []
for start, text in lines:
    words = text.split()
    words_out = [{"word": " " + w, "start": round(start + i * 0.3, 2), "end": round(start + i * 0.3 + 0.25, 2)} for i, w in enumerate(words)]
    segments.append({"text": text, "words": words_out})
json.dump({"segments": segments}, open(sys.argv[1], "w"))
PY

# --- usage and bad input
expect_error "no arguments prints usage" "usage:" "$DIRECTOR"
expect_error "unknown command prints usage" "usage:" "$DIRECTOR" frobnicate "$P"
expect_error "a missing project fails" "source.json" "$DIRECTOR" describe "$TMP/nope"
expect_error "describe before a plan fails" "plan.json" "$DIRECTOR" describe "$P"

# --- plan
out=$("$DIRECTOR" plan "$P")
check "plan writes plan.json ($out)" test -f "$P/plan.json"
check "the draft keeps speech, cuts the silence and speeds up typing" plan_py "
segs = plan['segments']
at = lambda t: next((s for s in segs if s['start'] <= t < s['end']), None)
sys.exit(0 if at(1)['speed'] == 1 and at(5.5) is None and at(8.5)['speed'] == 3 and at(18)['speed'] == 1 else 1)"
check "the draft zooms on the typing" plan_py "sys.exit(0 if any(z['start'] <= 8.5 < z['end'] for z in plan['zooms']) else 1)"
expect_error "plan won't overwrite edits without --force" "--force" "$DIRECTOR" plan "$P"
"$DIRECTOR" plan "$P" --force >/dev/null
check "plan --force rewrites it" test -f "$P/plan.json"
# Small output so the renders below are quick.
plan_py "plan['output'].update(width=480, height=270); json.dump(plan, open('$P/plan.json', 'w'), indent=2)"
cp "$P/plan.json" "$TMP/draft.json"

# --- describe and review
desc=$("$DIRECTOR" describe "$P")
check "describe shows the transcript" grep -q "keyboard shortcut" <<<"$desc"
check "describe lists the cut" grep -qi "cut" <<<"$desc"
review=$("$DIRECTOR" review "$P")
check "review reports on the zoom" grep -qi "zoom" <<<"$review"

# --- cut and restore (source seconds), with a history snapshot each time
before=$(output_seconds)
"$DIRECTOR" cut "$P" 1 2 >/dev/null
after=$(output_seconds)
check "cut 1-2 s takes a second off ($before -> $after)" near "$before" "$(python3 -c "print($after + 1)")" 0.01
check "cut leaves nothing playing at 1.5 s" plan_py "sys.exit(0 if not any(s['start'] <= 1.5 < s['end'] for s in plan['segments']) else 1)"
check "writing the plan saves the old one to .history/" test -n "$(ls -A "$P/.history" 2>/dev/null)"
"$DIRECTOR" restore "$P" 1 2 >/dev/null
check "restore puts it back ($(output_seconds))" near "$before" "$(output_seconds)" 0.01
expect_error "cut with end before start prints usage" "usage:" "$DIRECTOR" cut "$P" 5 2
expect_error "cut with a non-number prints usage" "usage:" "$DIRECTOR" cut "$P" a 2

# --- pauses (measures loudness from the audio track)
"$DIRECTOR" pauses "$P" tight >/dev/null
check "pauses tight is saved in the plan" plan_py "sys.exit(0 if plan.get('pauses') == 'tight' else 1)"
check "pauses tight still cuts the silence" plan_py "sys.exit(0 if not any(s['start'] <= 5.5 < s['end'] for s in plan['segments']) else 1)"
check "the loudness it measured is cached" test -f "$P/loudness.json"
expect_error "an unknown pause level prints usage" "usage:" "$DIRECTOR" pauses "$P" loose
cp "$TMP/draft.json" "$P/plan.json"

# --- profile
mkdir -p "$TMP/profile"
python3 - "$TMP/profile/profile.json" "$P/plan.json" <<'PY'
import json, sys
style = json.load(open(sys.argv[2]))["style"]
style["motion"] = "snappy"
json.dump({"name": "Test look", "style": style, "look": {"intro": {"enabled": True, "title": "{title}", "subtitle": "CLI test"}}}, open(sys.argv[1], "w"))
PY
out=$("$DIRECTOR" profile "$P" "$TMP/profile")
check "profile reports its name ($out)" grep -q "Test look" <<<"$out"
check "profile sets the style and fills the intro title" plan_py "
sys.exit(0 if plan['style']['motion'] == 'snappy' and plan['intro']['title'] == 'fixture' and plan['intro']['subtitle'] == 'CLI test' else 1)"
expect_error "a folder with no profile.json fails" "profile.json" "$DIRECTOR" profile "$P" "$TMP/nope"

# --- saved profiles, by name
check "profiles lists the seeded Personal profile as the default" grep -q "^\* Personal" <<<"$("$DIRECTOR" profiles)"
"$DIRECTOR" profile-save "$P" "Snappy look" >/dev/null
check "profile-save writes the profile" test -f "$SD_SUPPORT_DIR/Profiles/Snappy look/profile.json"
check "profiles lists the saved one" grep -q "Snappy look" <<<"$("$DIRECTOR" profiles)"
cp "$TMP/draft.json" "$P/plan.json"
"$DIRECTOR" profile "$P" "Snappy look" >/dev/null
check "profile by name applies the saved style" plan_py "sys.exit(0 if plan['style']['motion'] == 'snappy' else 1)"
expect_error "an unknown profile name lists the saved ones" "Snappy look" "$DIRECTOR" profile "$P" "Nope"
expect_error "profile-save refuses a name with a slash" "can't be a profile name" "$DIRECTOR" profile-save "$P" "a/b"
cp "$TMP/draft.json" "$P/plan.json"

# --- the app's settings
check "settings lists the app's settings" grep -q "^pauseLevel = normal" <<<"$("$DIRECTOR" settings)"
"$DIRECTOR" settings set pauseLevel tight >/dev/null
check "settings set then get" test "$("$DIRECTOR" settings get pauseLevel)" = "tight"
check "settings are saved where the app reads them" test "$(defaults read "$SD_DEFAULTS_DOMAIN" pauseLevel)" = "tight"
expect_error "settings refuses a value the app wouldn't take" "gentle, normal, tight" "$DIRECTOR" settings set pauseLevel loose
expect_error "settings refuses an unknown key" "no setting named" "$DIRECTOR" settings get volume
expect_error "settings refuses a default profile that isn't saved" "no profile named" "$DIRECTOR" settings set defaultProfile Nope
"$DIRECTOR" settings set polishVoice true >/dev/null
"$DIRECTOR" settings set defaultProfile "Snappy look" >/dev/null

# --- draft: the app's first draft, with those settings
expect_error "draft won't overwrite edits without --force" "--force" "$DIRECTOR" draft "$P"
out=$("$DIRECTOR" draft "$P" --force)
check "draft names the profile it used ($out)" grep -q "profile Snappy look" <<<"$out"
check "draft applies the default profile, pause level and voice polish" plan_py "
a = plan.get('audio') or {}
sys.exit(0 if plan['style']['motion'] == 'snappy' and plan['pauses'] == 'tight' and a.get('normalize') and a.get('warm') else 1)"
check "draft still cuts the silence" plan_py "sys.exit(0 if not any(s['start'] <= 5.5 < s['end'] for s in plan['segments']) else 1)"
cp "$TMP/draft.json" "$P/plan.json"

# --- animation templates and project files
out=$("$DIRECTOR" template "$P" freeze storyboard)
check "template freeze copies it into the video ($out)" test -f "$P/animations/templates/storyboard.js"
check "a second freeze leaves it alone" grep -q "already" <<<"$("$DIRECTOR" template "$P" freeze storyboard)"
echo "// edited" >>"$P/animations/templates/storyboard.js"
"$DIRECTOR" template "$P" save storyboard >/dev/null
check "template save puts the video's copy in My Templates" grep -q "// edited" "$SD_SUPPORT_DIR/Animations/templates/storyboard.js"
rm -rf "$SD_SUPPORT_DIR/Animations"
"$DIRECTOR" template "$P" update storyboard >/dev/null
check "template update replaces the video's copy with the library's" sh -c "! grep -q '// edited' '$P/animations/templates/storyboard.js'"
expect_error "template freeze of an unknown one lists the others" "hub" "$DIRECTOR" template "$P" freeze nope
printf 'not a lut\n' >"$TMP/bad.cube"
expect_error "add refuses a LUT that doesn't load" "cube" "$DIRECTOR" add "$P" lut "$TMP/bad.cube"
cp "$P/screen.mp4" "$TMP/clip.mp4"
out=$("$DIRECTOR" add "$P" broll "$TMP/clip.mp4")
check "add copies a file and prints the path for the plan ($out)" test "$out" = "broll/clip.mp4" -a -f "$P/broll/clip.mp4"
expect_error "add of a missing file fails" "no such file" "$DIRECTOR" add "$P" music "$TMP/nope.m4a"
expect_error "add of an unknown kind prints usage" "usage:" "$DIRECTOR" add "$P" video "$TMP/bad.cube"

# --- render, still, gif, debug
"$DIRECTOR" render "$P" "$TMP/out.mp4" >/dev/null 2>&1
want=$(output_seconds)
check "render writes the video at the plan's size ($(dims "$TMP/out.mp4"))" test "$(dims "$TMP/out.mp4")" = "480x270"
check "the video is as long as the plan ($(stream_duration "$TMP/out.mp4" v) vs $want s)" near "$(stream_duration "$TMP/out.mp4" v)" "$want" 0.02
# AAC pads its last packets, by a varying amount, so the sound can run a little past the picture.
check "the sound runs the length of the video ($(stream_duration "$TMP/out.mp4" a) s)" near "$(stream_duration "$TMP/out.mp4" a)" "$want" 0.2
scan=$("$DIRECTOR" scan "$TMP/out.mp4")
check "scan finds no short shots in the render ($scan)" test "$scan" = "No shots under a second."
dbg=$("$DIRECTOR" debug "$P")
check "debug prints the composition's tracks" grep -q "asset duration" <<<"$dbg"

"$DIRECTOR" still "$P" 30 "$P/.checks/f30.png" >/dev/null
check "still writes a frame inside the project ($(dims "$P/.checks/f30.png"))" test "$(dims "$P/.checks/f30.png")" = "480x270"
"$DIRECTOR" still "$P" 30 "$TMP/vertical.png" --preset vertical >/dev/null
check "still --preset vertical makes a 9:16 frame ($(dims "$TMP/vertical.png"))" test "$(dims "$TMP/vertical.png")" = "1080x1920"
check "the preset doesn't change the saved plan" plan_py "sys.exit(0 if plan['output']['width'] == 480 else 1)"
expect_error "still refuses to write outside the project and temp" "refusing" "$DIRECTOR" still "$P" 30 "$HOME/sd-cli-test.png"
ln -s "$TMP/elsewhere.png" "$P/.checks/link.png"
expect_error "still refuses to write through a symlink" "symlink" "$DIRECTOR" still "$P" 30 "$P/.checks/link.png"
expect_error "still without a frame number prints usage" "usage:" "$DIRECTOR" still "$P" x "$TMP/f.png"
expect_error "an unknown preset prints usage" "usage:" "$DIRECTOR" still "$P" 30 "$TMP/f.png" --preset huge

"$DIRECTOR" gif "$P" "$TMP/clip.gif" --from 0 --to 2 --width 240 --fps 10 >/dev/null
check "gif is the width asked for ($(dims "$TMP/clip.gif"))" test "$(dims "$TMP/clip.gif")" = "240x135"
frames=$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$TMP/clip.gif")
check "gif has 2 s at 10 fps ($frames frames)" near "$frames" 20 1

# --- publish (no camera: thumbnails come from the middle of the edit)
pub=$("$DIRECTOR" publish "$P" --title "CLI test")
check "publish writes captions" grep -q -- "-->" "$P/publish/captions.srt"
check "the captions carry the narration" grep -q "keyboard" "$P/publish/captions.srt"
check "publish writes a timed transcript" grep -q "^\[0:0" "$P/publish/transcript.txt"
check "publish writes a thumbnail ($(grep -c thumbnail <<<"$pub"))" test -f "$P/publish/thumbnail-1.png"

# --- screentext and analyze without audio (no Whisper needed: transcription is skipped)
"$DIRECTOR" screentext "$P" >/dev/null
check "screentext reads a sample for each click" python3 -c "
import json, sys; sys.exit(0 if len(json.load(open('$P/screentext.json'))) == 2 else 1)"
mkdir -p "$TMP/silent"
ffmpeg -v error -i "$P/screen.mp4" -an -c:v copy "$TMP/silent/screen.mp4"
cp "$P/source.json" "$P/events.jsonl" "$TMP/silent/"
"$DIRECTOR" analyze "$TMP/silent" >/dev/null
check "analyze without audio writes an empty transcript" python3 -c "
import json, sys; sys.exit(0 if json.load(open('$TMP/silent/transcript.json'))['segments'] == [] else 1)"
check "analyze measures motion through the whole video" python3 -c "
import json, sys; m = json.load(open('$TMP/silent/motion.json')); sys.exit(0 if len(m) > 150 and m[-1][0] > 19 else 1)"
check "analyze sees the box moving at 14-17 s and the still screen at 5 s" python3 -c "
import json, sys; m = dict((round(t, 1), v) for t, v in json.load(open('$TMP/silent/motion.json')))
sys.exit(0 if m[15.0] > m[5.0] else 1)"

# --- camera commands without a camera fail clearly
expect_error "sync-camera without a camera says so" "no camera" "$DIRECTOR" sync-camera "$P"
expect_error "frame-camera without a camera fails" "no face" "$DIRECTOR" frame-camera "$P"

# --- join
cp -R "$P" "$TMP/take2"
"$DIRECTOR" join "$TMP/joined" "$P" "$TMP/take2" >/dev/null
check "join makes one 40 s video ($(duration "$TMP/joined/screen.mp4"))" near "$(duration "$TMP/joined/screen.mp4")" 40 0.2
check "join records where the second take starts" python3 -c "
import json, sys; s = json.load(open('$TMP/joined/source.json')); sys.exit(0 if abs(s['joins'][0] - 20) < 0.2 else 1)"
check "join writes a draft plan with both takes' speech" python3 -c "
import json, sys; segs = json.load(open('$TMP/joined/plan.json'))['segments']
sys.exit(0 if any(s['start'] <= 1 < s['end'] for s in segs) and any(s['start'] <= 21 < s['end'] for s in segs) else 1)"
expect_error "join won't overwrite a folder" "exists" "$DIRECTOR" join "$TMP/joined" "$P" "$TMP/take2"
expect_error "join needs two takes" "usage:" "$DIRECTOR" join "$TMP/joined2" "$P"

# --- upload without credentials fails with what it needs
expect_error "upload without S3 settings names them" "S3_ENDPOINT" env -u S3_ENDPOINT "$DIRECTOR" upload "$TMP/clip.gif"

# --- bin/sd (help, import, and the commands it hands to director)
SD="$ROOT/bin/sd"
export SD_PROJECTS="$TMP/sd" SD_DIRECTOR="$DIRECTOR"
mkdir -p "$SD_PROJECTS"
check "sd with no command prints help" grep -q "sd import" <<<"$("$SD")"
"$SD" import demo "$P/screen.mp4" >/dev/null
check "sd import writes source.json from the video" python3 -c "
import json, sys; s = json.load(open('$SD_PROJECTS/demo/source.json'))
sys.exit(0 if s['video'] == 'screen.mp4' and s['width'] == 1920 and abs(s['duration'] - 20) < 0.1 and 'captureStart' not in s else 1)"
expect_error "sd import won't overwrite a project" "already exists" "$SD" import demo "$P/screen.mp4"
expect_error "sd import of a missing file fails" "no such file" "$SD" import other "$TMP/nope.mp4"
"$SD" import cam "$P/screen.mp4" --camera "$P/screen.mp4" --camera-offset 0.25 >/dev/null
check "sd import --camera records the camera and its offset" python3 -c "
import json, sys; c = json.load(open('$SD_PROJECTS/cam/source.json'))['camera']
sys.exit(0 if c['video'] == 'camera.mp4' and c['offset'] == 0.25 else 1)"
cp "$P/transcript.json" "$SD_PROJECTS/demo/"
"$SD" plan demo >/dev/null
check "sd plan writes a draft" test -f "$SD_PROJECTS/demo/plan.json"
python3 -c "
import json; p = json.load(open('$SD_PROJECTS/demo/plan.json')); p['sentinel'] = 1; json.dump(p, open('$SD_PROJECTS/demo/plan.json', 'w'))"
"$SD" plan demo --force >/dev/null
check "sd passes further arguments to director (--force redrafts the plan)" python3 -c "
import json, sys; sys.exit(0 if 'sentinel' not in json.load(open('$SD_PROJECTS/demo/plan.json')) else 1)"
check "sd describe passes through to director" grep -q "keyboard shortcut" <<<"$("$SD" describe demo)"
expect_error "sd on a missing project says so" "no project" "$SD" describe missing
expect_error "sd without a project name says so" "missing project name" "$SD" plan
expect_error "sd import rejects an unknown option" "unknown option --loud" "$SD" import other "$P/screen.mp4" --loud
expect_error "sd plan on an unanalyzed recording says to analyze first" "sd analyze" "$SD" plan cam
check "a refused plan writes nothing" test ! -e "$SD_PROJECTS/cam/plan.json"

# --- a recording's input events, placed on the video's clock by source.json's captureStart (the
# host time of the first frame, which the app's recorder writes).
mkdir "$TMP/recorded"
cp "$P/screen.mp4" "$TMP/recorded/"
python3 -c "
import json; s = json.load(open('$P/source.json')); s['video'] = 'screen.mp4'; s['captureStart'] = 51234.5678
json.dump(s, open('$TMP/recorded/source.json', 'w'))"
printf '%s\n' '{"type":"meta","clock":"uptime_raw","t":51234.5}' '{"type":"click","t":51241.5678,"x":0.75,"y":0.29}' >"$TMP/recorded/events.jsonl"
"$DIRECTOR" plan "$TMP/recorded" >/dev/null
check "a click on the host clock lands 7 s into the recording" grep -q "0:07.0" <<<"$("$DIRECTOR" describe "$TMP/recorded")"

[[ "$failures" == 0 ]] || { echo "$failures CLI check(s) failed" >&2; exit 1; }
echo "CLI checks passed"
