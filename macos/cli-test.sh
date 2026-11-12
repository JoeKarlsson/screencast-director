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

# --- secrets on screen: a scan, then a finding the edit shows until --blur covers it
check "secrets finds none on the fixture" grep -q "no secrets on screen" <<<"$("$DIRECTOR" secrets "$P")"
cp "$P/plan.json" "$TMP/before-secrets.json"
echo '{"scanned":[{"start":0,"end":1000}],"findings":[{"kind":"api key","masked":"sk-p… (32)","start":3,"end":5,"x":0.1,"y":0.1,"w":0.3,"h":0.05},
  {"kind":"email","masked":"jo… (15)","start":3,"end":5,"x":0.1,"y":0.5,"w":0.2,"h":0.03}]}' >"$P/secrets.json"
check "describe warns about each unblurred secret" grep -q "WARNING: secret #1 (email" <<<"$("$DIRECTOR" describe "$P")"
expect_error "the Claude box can't mark a secret safe to show" "only the user" env SD_ONLY_PROJECT="$P" "$DIRECTOR" secrets "$P" --allow email
check "--allow email allows every email" grep -q "every email may show" <<<"$("$DIRECTOR" secrets "$P" --allow email)"
check "secrets --blur adds a blur for the key only" grep -q "added 1 blur$" <<<"$("$DIRECTOR" secrets "$P" --blur)"
check "then describe doesn't warn" bash -c "! '$DIRECTOR' describe '$P' | grep -q 'WARNING: secret'"
expect_error "--allow a secret that isn't there fails" "no secret #3" "$DIRECTOR" secrets "$P" --allow 3
expect_error "--allow an unknown kind lists the kinds" "a kind: api key" "$DIRECTOR" secrets "$P" --allow emails
python3 -c "import json,sys; s=json.load(open(sys.argv[1])); s['scanned']=[{'start':0,'end':2}]; json.dump(s,open(sys.argv[1],'w'))" "$P/secrets.json"
check "describe warns about a kept stretch the scan didn't read" grep -q "wasn't read for secrets" <<<"$("$DIRECTOR" describe "$P")"
echo 'not json' >"$P/secrets.json"
check "an unreadable secrets.json is a warning, not silence" grep -q "secrets.json can't be read" <<<"$("$DIRECTOR" describe "$P")"
cp "$TMP/before-secrets.json" "$P/plan.json"
rm "$P/secrets.json"

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

# --- asks: rewind to the plan saved when a Claude box ask started (written here as the app would)
ask_id=$(uuidgen)
mkdir -p "$P/.history/asks"
cp "$P/plan.json" "$P/.history/asks/$ask_id.json"
printf '[{"id":"%s","instruction":"cut a second","reply":"done"}]' "$ask_id" >"$P/.history/asks.json"
"$DIRECTOR" cut "$P" 1 2 >/dev/null
check "asks lists the ask" grep -q "^1  cut a second" <<<"$("$DIRECTOR" asks "$P")"
check "asks rewind names the ask" grep -q "rewound to before ask 1: cut a second" <<<"$("$DIRECTOR" asks "$P" rewind 1)"
check "the plan is back to before the ask ($(output_seconds))" near "$before" "$(output_seconds)" 0.01
check "asks marks it rewound" grep -q "^1 (rewound)" <<<"$("$DIRECTOR" asks "$P")"
expect_error "rewinding a missing ask says so" "there's no ask 2" "$DIRECTOR" asks "$P" rewind 2

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

# --- packs: export a profile, remove it, install it back; themes
"$DIRECTOR" pack export "$TMP/Snappy.sdpack" --profile "Snappy look" >/dev/null
check "pack export writes a .sdpack" test -s "$TMP/Snappy.sdpack"
expect_error "pack export needs a profile" "at least one profile" "$DIRECTOR" pack export "$TMP/none.sdpack"
rm -rf "$SD_SUPPORT_DIR/Profiles/Snappy look"
check "pack install puts the profile back" grep -q "installed Snappy 1.0: 1 new" <<<"$("$DIRECTOR" pack install "$TMP/Snappy.sdpack")"
check "pack list shows it" grep -q "^Snappy" <<<"$("$DIRECTOR" pack list)"
check "the installed profile is listed" grep -q "Snappy look" <<<"$("$DIRECTOR" profiles)"
echo '{"name": "Snappy look", "style": {"background": ["#000000"], "padding": 0, "radius": 1, "transition": 0.8}, "look": {}}' >"$SD_SUPPORT_DIR/Profiles/Snappy look/profile.json"
expect_error "installing over a changed file asks for --replace" "--replace" "$DIRECTOR" pack install "$TMP/Snappy.sdpack"
"$DIRECTOR" pack install "$TMP/Snappy.sdpack" --replace >/dev/null
check "pack remove takes it away" grep -q "removed Snappy" <<<"$("$DIRECTOR" pack remove Snappy)"
check "and it's gone" test ! -e "$SD_SUPPORT_DIR/Profiles/Snappy look/profile.json"
expect_error "removing a pack that isn't installed says so" "no pack named" "$DIRECTOR" pack remove Snappy
"$DIRECTOR" pack install "$TMP/Snappy.sdpack" >/dev/null
check "themes lists paper and terminal" grep -q "^terminal" <<<"$("$DIRECTOR" themes)"
plan_py "plan.setdefault('look', {})['animationTheme'] = 'nowhere'; json.dump(plan, open('$P/plan.json', 'w'))"
expect_error "validate names a theme that isn't installed" "isn't installed" "$DIRECTOR" validate "$P"
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

# --- validate
check "validate passes the draft" grep -q "is valid" <<<"$("$DIRECTOR" validate "$P")"
plan_py "plan['zooms'].append({'start': 2, 'end': 4, 'x': 1.5, 'y': 0.5, 'scale': 2}); json.dump(plan, open('$P/plan.json', 'w'))"
expect_error "validate names a zoom off the screen by its path" "zooms[" "$DIRECTOR" validate "$P"
plan_py "plan['segments'][0]['speed'] = 'fast'; json.dump(plan, open('$P/plan.json', 'w'))"
expect_error "validate shows where plan.json stops loading" "segments[0].speed: expected a number" "$DIRECTOR" validate "$P"
cp "$TMP/draft.json" "$P/plan.json"
plan_py "plan['captionz'] = {'enabled': True}; json.dump(plan, open('$P/plan.json', 'w'))"
expect_error "validate names a misspelled key" "captionz isn't a field here" "$DIRECTOR" validate "$P"
cp "$TMP/draft.json" "$P/plan.json"

# --- the recorder's status (the app writes it; here a stand-in file)
check "status with no recording yet is idle" grep -q '"state" : "idle"' <<<"$("$DIRECTOR" status)"
mkdir -p "$SD_SUPPORT_DIR"
printf '{"state": "ready", "project": "%s", "pid": %s, "updated": "2026-11-04T12:00:00Z"}' "$P" "$$" >"$SD_SUPPORT_DIR/recording.json"
out=$("$DIRECTOR" status --wait ready --timeout 5)
check "status --wait returns once the recording is ready ($out)" grep -q "\"project\" : \"$P\"" <<<"$out"
expect_error "status --wait gives up after the timeout" "timed out" "$DIRECTOR" status --wait recording --timeout 1
printf '{"state": "recording", "pid": 99999999, "updated": "2026-11-04T12:00:00Z"}' >"$SD_SUPPORT_DIR/recording.json"
expect_error "status --wait notices the app quit mid-recording" "quit" "$DIRECTOR" status --wait ready --timeout 5
expect_error "status --wait refuses an unknown state" "--wait takes" "$DIRECTOR" status --wait finished
rm "$SD_SUPPORT_DIR/recording.json"

# --- SD_ONLY_PROJECT (the app's Claude box): commands stay in the project being edited
expect_error "a locked run refuses another folder" "may only work on" env SD_ONLY_PROJECT="$P" "$DIRECTOR" profile "$P/.." Personal
check "a locked run works on its own project" env SD_ONLY_PROJECT="$P" "$DIRECTOR" validate "$P"
# The Claude box runs segment edits as `cut . <start> <end>` from inside the project.
cp "$P/plan.json" "$TMP/locked.json"
locked_cut() { (cd "$P" && SD_ONLY_PROJECT="$P" "$DIRECTOR" cut . 1 1.5 >/dev/null); }
check "a locked run cuts its own project as ." locked_cut
check "the cut from inside the project landed" plan_py "sys.exit(0 if not any(s['start'] <= 1.2 < s['end'] for s in plan['segments']) else 1)"
cp "$TMP/locked.json" "$P/plan.json"

# --- animation templates and project files
out=$("$DIRECTOR" template "$P" freeze storyboard)
check "template freeze copies it into the video ($out)" test -f "$P/animations/templates/storyboard.js"
check "a second freeze leaves it alone" grep -q "already" <<<"$("$DIRECTOR" template "$P" freeze storyboard)"
echo "// edited" >>"$P/animations/templates/storyboard.js"
"$DIRECTOR" template "$P" save storyboard >/dev/null
check "template save puts the video's copy in My Templates" grep -q "// edited" "$SD_SUPPORT_DIR/Animations/templates/storyboard.js"
rm -rf "$SD_SUPPORT_DIR/Animations"
echo "// keep" >"$TMP/keep.js"
expect_error "template update refuses a name that's a path" "template name" "$DIRECTOR" template "$P" update "../../../../../../../../../..$TMP/keep"
check "a refused template update deletes nothing" test -f "$TMP/keep.js"
"$DIRECTOR" template "$P" update storyboard >/dev/null
check "template update replaces the video's copy with the library's" sh -c "! grep -q '// edited' '$P/animations/templates/storyboard.js'"
expect_error "template freeze of an unknown one lists the others" "hub" "$DIRECTOR" template "$P" freeze nope
check "lottie list shows the built-in overlays" grep -q "circle.json .*plays once  \[builtIn\]" <<<"$("$DIRECTOR" lottie "$P" list)"
cp Resources/animations/lottie/check.json "$TMP/tick.json"
"$DIRECTOR" lottie "$P" add "$TMP/tick.json" >/dev/null
check "lottie add copies it into the video" grep -q "^tick.json .*\[video\]" <<<"$("$DIRECTOR" lottie "$P" list)"
printf '{"op": 30}\n' >"$TMP/not-lottie.json"
expect_error "lottie add refuses a file that isn't a Lottie" "isn't a Lottie" "$DIRECTOR" lottie "$P" add "$TMP/not-lottie.json"
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
# What this guards against: sound cut short of the picture, or a mix left running past it. AAC pads
# its last packets by a varying amount (0.02-0.26 s seen), which only ever adds time, so the sound
# must reach the end and stop within a second of it; the exact padding isn't checked.
sound_spans_video() {
  python3 -c "import sys; a, v = map(float, sys.argv[1:]); sys.exit(0 if v - 0.02 <= a <= v + 1 else 1)" "$(stream_duration "$TMP/out.mp4" a)" "$want"
}
check "the sound runs the length of the video ($(stream_duration "$TMP/out.mp4" a) s for $want s)" sound_spans_video
scan=$("$DIRECTOR" scan "$TMP/out.mp4")
check "scan finds no short shots in the render ($scan)" test "$scan" = "No shots under a second."
made=$("$DIRECTOR" provenance "$TMP/out.mp4")
check "provenance names what made the render ($made)" grep -q "made by Screencast Director" <<<"$made"
cp "$TMP/out.mp4" "$P/stamped.mp4"
check "beside its plan.json, it says what changed since: nothing" grep -q "changed since: same" <<<"$("$DIRECTOR" provenance "$P/stamped.mp4")"
rm "$P/stamped.mp4"
check "provenance --plan prints the plan it rendered" bash -c "'$DIRECTOR' provenance '$TMP/out.mp4' --plan | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)[\"output\"][\"width\"] == 480 else 1)'"
expect_error "a video without a stamp says so" "no Screencast Director stamp" "$DIRECTOR" provenance "$P/screen.mp4"
dbg=$("$DIRECTOR" debug "$P")
check "debug prints the composition's tracks" grep -q "asset duration" <<<"$dbg"

"$DIRECTOR" still "$P" 30 "$P/.checks/f30.png" >/dev/null
check "still writes a frame inside the project ($(dims "$P/.checks/f30.png"))" test "$(dims "$P/.checks/f30.png")" = "480x270"
"$DIRECTOR" still "$P" 30 "$TMP/vertical.png" --preset vertical >/dev/null
check "still --preset vertical makes a 9:16 frame ($(dims "$TMP/vertical.png"))" test "$(dims "$TMP/vertical.png")" = "1080x1920"
check "the preset doesn't change the saved plan" plan_py "sys.exit(0 if plan['output']['width'] == 480 else 1)"
expect_error "still refuses to write outside the project and temp" "refusing" "$DIRECTOR" still "$P" 30 "$HOME/sd-cli-test.png"
expect_error "still never overwrites the recording" "refusing" "$DIRECTOR" still "$P" 30 "$P/screen.mp4"
expect_error "in the project, stills go in .checks/" "refusing" "$DIRECTOR" still "$P" 30 "$P/frame.png"
ln -s "$TMP/elsewhere.png" "$P/.checks/link.png"
expect_error "still refuses to write through a symlink" "symlink" "$DIRECTOR" still "$P" 30 "$P/.checks/link.png"
expect_error "still without a frame number prints usage" "usage:" "$DIRECTOR" still "$P" x "$TMP/f.png"
expect_error "an unknown preset prints usage" "usage:" "$DIRECTOR" still "$P" 30 "$TMP/f.png" --preset huge
sheet=$("$DIRECTOR" contact-sheet "$P" "$P/.checks/sheet.png" 2>/dev/null)
check "contact-sheet writes one labeled sheet for a short edit ($sheet, $(dims "$P/.checks/sheet.png"))" test "$sheet" = "$P/.checks/sheet.png" -a -s "$P/.checks/sheet.png"
expect_error "contact-sheet refuses to write outside the project and temp" "refusing" "$DIRECTOR" contact-sheet "$P" "$HOME/sd-cli-sheet.png"

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

# capture: a site's logo into the video's logos (named for animations) and a screenshot into broll/.
mkdir -p "$TMP/site"
cat > "$TMP/site/index.html" <<'HTML'
<!doctype html><html><head><title>Acme</title><meta name="theme-color" content="#ff3366"></head>
<body><header><a href="/" style="color: rgb(255, 0, 0)"><svg class="site-logo" width="120" height="40">
<rect width="120" height="40" rx="8" fill="currentColor"/></svg></a></header><h1>Hello</h1></body></html>
HTML
"$DIRECTOR" capture "$P" "file://$TMP/site/index.html" --name "Acme Co" >"$TMP/capture.txt" 2>&1 || fail "capture: $(cat "$TMP/capture.txt")"
check "capture names the logo for animations" grep -q '"Acme Co" : "acme-co.svg"' "$P/animations/logos/logos.json"
check "capture keeps the logo's color once it stands alone" grep -q 'color: rgb(255, 0, 0)' "$P/animations/logos/acme-co.svg"
check "capture screenshots the page into broll/" test -s "$P/broll/acme-co-site.png"
check "capture prints the theme color" grep -q "theme color: #ff3366" "$TMP/capture.txt"
check "capture doesn't call a red logo white" test "$(grep -c "drawn in white" "$TMP/capture.txt")" = 0
sed -i '' 's/rgb(255, 0, 0)/rgb(255, 255, 255)/' "$TMP/site/index.html"
"$DIRECTOR" capture "$P" "file://$TMP/site/index.html" --name "Acme White" >"$TMP/capture-white.txt" 2>&1 || fail "capture: $(cat "$TMP/capture-white.txt")"
check "capture warns about a white logo" grep -q "drawn in white" "$TMP/capture-white.txt"
expect_error "capture refuses a non-web URL" "usage" "$DIRECTOR" capture "$P" "ftp://example.com"
# A page can't name a local file elsewhere as its logo and have it copied into the project.
mkdir -p "$TMP/site2"
"$DIRECTOR" still "$P" 30 "$TMP/secret.png" >/dev/null
printf '<!doctype html><html><head><link rel="icon" sizes="512x512" href="file://%s/secret.png"></head><body><h1>Hi</h1></body></html>' "$TMP" >"$TMP/site2/index.html"
"$DIRECTOR" capture "$P" "file://$TMP/site2/index.html" --name "Peek" >"$TMP/capture-peek.txt" 2>&1 || fail "capture: $(cat "$TMP/capture-peek.txt")"
check "capture skips a logo that's a local file outside the page's folder" test ! -e "$P/animations/logos/peek.png"
# A project someone sent may ship its logos folder as a symlink: capture writes nothing through it.
mkdir -p "$TMP/elsewhere-logos" && mv "$P/animations/logos" "$TMP/logos-saved" && ln -s "$TMP/elsewhere-logos" "$P/animations/logos"
expect_error "capture refuses a symlinked logos folder" "symlink" "$DIRECTOR" capture "$P" "file://$TMP/site/index.html" --name "Acme Co"
check "nothing lands in the symlink's target" test -z "$(ls -A "$TMP/elsewhere-logos")"
rm "$P/animations/logos" && mv "$TMP/logos-saved" "$P/animations/logos"

[[ "$failures" == 0 ]] || { echo "$failures CLI check(s) failed" >&2; exit 1; }
echo "CLI checks passed"
