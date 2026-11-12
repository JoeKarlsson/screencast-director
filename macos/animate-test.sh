#!/usr/bin/env bash
# Animation render check: adds one animation per bundled template to a synthetic project, renders
# them with `director animate` (offscreen WebKit), and fails when a template throws, a clip is missing
# or the wrong length, something pops for one frame, or its last frame is blank; then a one-second `animate-test`.
#
#   macos/animate-test.sh
#
# Needs ffmpeg and `say` (for the fixture). Runs on a temp project, so it never touches projects/.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
swift build -c release --product director >/dev/null
DIRECTOR="$PWD/.build/release/director"

TMP="$(mktemp -d -t sd-animate)"
trap 'rm -rf "$TMP"' EXIT
# Its own support folder, so themes and templates installed on this Mac don't change the result.
export SD_SUPPORT_DIR="$TMP/support"
mkdir -p "$SD_SUPPORT_DIR"
PROJECT="$TMP/fixture"
"$ROOT/test/make-fixture.sh" "$PROJECT" >/dev/null
"$DIRECTOR" plan "$PROJECT" >/dev/null

# One 3 s animation per template, with the manifest's starting data and beats squeezed into it,
# at a small size so the render is quick.
python3 - "$PROJECT/plan.json" Resources/animations/templates <<'PY'
import glob, json, os, sys
plan_path, templates = sys.argv[1], sys.argv[2]
plan = json.load(open(plan_path))
plan["output"].update(width=480, height=270)
plan["animations"] = []
paths = sorted(glob.glob(os.path.join(templates, "*.json")))
# Spread over the recording, each 3 s with a gap after it.
step = min(4, (plan["source"]["duration"] - 1) / len(paths))
if step < 3.05: sys.exit(f"FAIL: {len(paths)} templates don't fit 3 s apiece in the {plan['source']['duration']} s fixture")
for i, path in enumerate(paths):
    t = json.load(open(path))
    start = round(1 + i * step, 2)
    squeeze = 3 / t["length"]
    plan["animations"].append({
        "start": start, "end": start + 3, "template": t["name"], "data": t["data"],
        "cues": {c["key"]: round(start + c["at"] * squeeze, 3) for c in t["cues"]},
    })
json.dump(plan, open(plan_path, "w"), indent=2)
PY

"$DIRECTOR" animate "$PROJECT" | tee "$TMP/animate.log"
# Nothing in a bundled template shows for a single frame (Animation.pops).
if grep -q "pops for one frame" "$TMP/animate.log"; then echo "FAIL: a template pops for one frame (above)" >&2; exit 1; fi
# Their text reads against what's behind it (the text probe's contrast check).
if grep -q "hard to read\|nothing behind it" "$TMP/animate.log"; then echo "FAIL: a template's text is hard to read (above)" >&2; exit 1; fi
# No sticker's crayon mark runs through its own text (the mark probe).
if grep -q "crosses the text" "$TMP/animate.log"; then echo "FAIL: a template's mark crosses its text (above)" >&2; exit 1; fi
templates=$(find Resources/animations/templates -name '*.json' | wc -l | tr -d ' ')
clips=$(find "$PROJECT/.animations" -name '*.mp4' | wc -l | tr -d ' ')
[[ "$clips" == "$templates" ]] || { echo "FAIL: $templates templates but $clips clips" >&2; exit 1; }

for clip in "$PROJECT"/.animations/*.mp4; do
  name=$(basename "$clip")
  length=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$clip")
  python3 -c "import sys; sys.exit(0 if abs(float(sys.argv[1]) - 3) < 0.2 else 1)" "$length" \
    || { echo "FAIL: $name is ${length}s, not 3s" >&2; exit 1; }
  # The last frame has the whole build on it: it must have drawing on it, not one flat color.
  ffmpeg -v error -sseof -0.2 -i "$clip" -frames:v 1 -f rawvideo -pix_fmt gray -y "$TMP/last.gray"
  python3 - "$TMP/last.gray" "$name" <<'PY'
import sys
px = open(sys.argv[1], "rb").read()
mean = sum(px) / len(px)
spread = (sum((p - mean) ** 2 for p in px) / len(px)) ** 0.5
if spread < 10:
    sys.exit(f"FAIL: {sys.argv[2]}'s last frame is blank (spread {spread:.1f})")
print(f"ok: {sys.argv[2]} 3s, last frame drawn (spread {spread:.1f})")
PY
done
# A pack's theme (test/fixtures/themes/probe, installed with `director pack install`): its CSS paints
# the stage black and its stroke hook draws thick lines (a render later keeps a copy of it in the video).
mkdir -p "$TMP/probe-pack/Animations/themes"
cp -R "$ROOT/test/fixtures/themes/probe" "$TMP/probe-pack/Animations/themes/"
echo '{"name": "Probe"}' >"$TMP/probe-pack/pack.json"
"$DIRECTOR" pack install "$TMP/probe-pack" >/dev/null
python3 - "$PROJECT/plan.json" probe <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
plan.setdefault("look", {})["animationTheme"] = sys.argv[2]
json.dump(plan, open(sys.argv[1], "w"), indent=2)
PY
# The storyboard's index and start, whatever other templates sort before it.
read -r SB SB_START < <(python3 -c "import json,sys; a=json.load(open(sys.argv[1]))['animations']; i=[x['template'] for x in a].index('storyboard'); print(i, a[i]['start'])" "$PROJECT/plan.json")
"$DIRECTOR" animate-test "$PROJECT" "$SB" "$(python3 -c "print($SB_START + 2.8)")" "$TMP/probe.mp4" >/dev/null
ffmpeg -v error -sseof -0.1 -i "$TMP/probe.mp4" -frames:v 1 -f rawvideo -pix_fmt gray -y "$TMP/probe.gray"
python3 - "$TMP/probe.gray" <<'PY'
import sys
px = open(sys.argv[1], "rb").read()
mean = sum(px) / len(px)
lit = sum(1 for p in px if p > 120) / len(px)
if mean > 60: sys.exit(f"FAIL: the probe theme's CSS didn't paint the stage black (mean {mean:.0f})")
if lit < 0.002: sys.exit(f"FAIL: the probe theme's frame has no lines or cards drawn ({lit:.4f} lit)")
print(f"ok: a pack theme's CSS and hooks apply (mean {mean:.0f}, {lit:.3f} lit)")
PY
# A theme that isn't installed stops the render with a message saying so.
python3 - "$PROJECT/plan.json" nowhere <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
plan.setdefault("look", {})["animationTheme"] = sys.argv[2]
json.dump(plan, open(sys.argv[1], "w"), indent=2)
PY
if "$DIRECTOR" animate-test "$PROJECT" "$SB" "$(python3 -c "print($SB_START + 1)")" "$TMP/nowhere.mp4" 2>"$TMP/err"; then echo "FAIL: a missing theme rendered" >&2; exit 1; fi
grep -q "isn't installed" "$TMP/err" || { echo "FAIL: a missing theme said: $(cat "$TMP/err")" >&2; exit 1; }
echo "ok: a theme that isn't installed is named"
python3 - "$PROJECT/plan.json" probe <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
plan.setdefault("look", {})["animationTheme"] = sys.argv[2]
json.dump(plan, open(sys.argv[1], "w"), indent=2)
PY

# Two storyboard stickers parked on the same spot: the render's overlap probe names them.
python3 - "$PROJECT/plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
a = next(a for a in plan["animations"] if a["template"] == "storyboard")
a["data"] = {"title": "Overlap", "steps": [
    {"cue": "s1", "do": "show", "id": "a", "kind": "sticker", "label": "First", "x": 50, "y": 55},
    {"cue": "s2", "do": "show", "id": "b", "kind": "sticker", "label": "Second", "x": 51, "y": 56}]}
a["cues"] = {"s1": a["start"] + 0.2, "s2": a["start"] + 0.5}
json.dump(plan, open(sys.argv[1], "w"), indent=2)
PY
"$DIRECTOR" animate-test "$PROJECT" "$SB" "$(python3 -c "print($SB_START + 1.5)")" "$TMP/overlap.mp4" >"$TMP/overlap.txt" 2>&1
grep -q '^WARNING: .* overlap ' "$TMP/overlap.txt" || { echo "FAIL: two stickers on one spot weren't reported: $(cat "$TMP/overlap.txt")" >&2; exit 1; }
echo "ok: the overlap probe reports two pieces on one spot ($(grep -m1 '^WARNING:.* overlap ' "$TMP/overlap.txt" | cut -c1-120))"

# A one-second test of the first animation: a 1 s clip and a sheet of its 12 frames.
"$DIRECTOR" animate-test "$PROJECT" 0 1.5 "$TMP/test.mp4" >/dev/null
length=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/test.mp4")
python3 -c "import sys; sys.exit(0 if abs(float(sys.argv[1]) - 1) < 0.1 else 1)" "$length" \
  || { echo "FAIL: animate-test made ${length}s, not 1s" >&2; exit 1; }
[[ -s "$TMP/test.png" ]] || { echo "FAIL: animate-test wrote no contact sheet" >&2; exit 1; }
if "$DIRECTOR" animate-test "$PROJECT" 0 30 "$TMP/late.mp4" 2>"$TMP/err"; then echo "FAIL: animate-test outside the animation succeeded" >&2; exit 1; fi
grep -q "isn't in it" "$TMP/err" || { echo "FAIL: animate-test outside the animation said: $(cat "$TMP/err")" >&2; exit 1; }
echo "ok: animate-test renders 1 s and its sheet, and refuses a moment outside the animation"
# The app's live preview: animate-preview draws one frame per request at the clip's size, from the
# plan it's sent (an edit shows without saving or rendering), and answers a bad request with an error.
python3 - "$DIRECTOR" "$PROJECT" <<'PY'
import json, struct, subprocess, sys
director, project = sys.argv[1], sys.argv[2]
plan = json.load(open(project + "/plan.json"))
edited = json.loads(json.dumps(plan))
last, first = edited["animations"][-1], edited["animations"][0]
first.update(template=last["template"], data=last["data"], cues={k: v - last["start"] + first["start"] for k, v in last.get("cues", {}).items()})
helper = subprocess.Popen([director, "animate-preview", project], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def ask(request):
    helper.stdin.write(json.dumps(request) + "\n")
    helper.stdin.flush()
    reply = json.loads(helper.stdout.readline())
    if "png" not in reply: return reply
    png = open(reply["png"], "rb").read()
    return dict(reply, size=struct.unpack(">II", png[16:24]), png=png)
saved, sent, bad = ask({"index": 0, "t": 2.5}), ask({"index": 0, "t": 2.5, "plan": edited}), ask({"index": 99, "t": 0})
helper.stdin.close()
helper.wait()
if "error" in saved or "error" in sent: sys.exit(f"FAIL: animate-preview didn't draw: {saved.get('error')} {sent.get('error')}")
if saved["size"] != (480, 270): sys.exit(f"FAIL: animate-preview drew {saved['size']}, not the clip's 480x270")
if saved["png"] == sent["png"]: sys.exit("FAIL: animate-preview ignored the plan it was sent")
if "no animation #99" not in bad.get("error", ""): sys.exit(f"FAIL: animate-preview answered a bad index with {bad}")
print("ok: animate-preview draws a frame at the clip's size from the plan it's sent, and reports a bad index")
# Its text pieces come back with each frame, and the animation's layout moves one by shares of the clip's width.
note = next(i for i, a in enumerate(plan["animations"]) if a["template"] == "note")
plan["animations"][note]["sticker"] = {"x": 0.5, "y": 0.5, "w": 0.4}
helper = subprocess.Popen([director, "animate-preview", project], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
before = ask({"index": note, "t": 2.5, "plan": plan})
plan["animations"][note]["layout"] = {"small": {"x": 0.1}}
after = ask({"index": note, "t": 2.5, "plan": plan})
helper.stdin.close()
helper.wait()
pieces = before.get("pieces", {})
if not {"big", "small"} <= set(pieces): sys.exit(f"FAIL: the Sticker Note's pieces weren't listed: {before.get('error') or sorted(pieces)}")
shift = after["pieces"]["small"][0] - pieces["small"][0]
if abs(shift - 0.1) > 0.01: sys.exit(f"FAIL: a layout x of 0.1 moved the note's small line by {shift:.3f} of the clip")
print("ok: animate-preview lists an animation's text pieces, and its layout moves them")
# A piece the animation's camera has pushed in on reports that zoom, and a drag saved the way the app
# saves it (the pointer's move divided by the zoom) lands the piece exactly where the pointer went.
helper = subprocess.Popen([director, "animate-preview", project], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
zoomed = None
for i, a in enumerate(plan["animations"]):
    for t in (1.0, 2.0, 2.9):
        for name, p in ask({"index": i, "t": t, "plan": plan}).get("pieces", {}).items():
            if zoomed is None or p[4] > zoomed[3]: zoomed = (i, t, name, p[4], p[0])
if zoomed is None or zoomed[3] < 1.02: sys.exit(f"FAIL: no template's camera zooms in on its text, so the zoom can't be checked ({zoomed})")
i, t, name, zoom, left = zoomed
dragged = json.loads(json.dumps(plan))
# A drag the clip's whole width, so the camera's few percent are pixels apart, not rounding.
dragged["animations"][i]["layout"] = {name: {"x": 1 / zoom}}
moved = ask({"index": i, "t": t, "plan": dragged})["pieces"][name][0] - left
helper.stdin.close()
helper.wait()
if abs(moved - 1) > (zoom - 1) / 3: sys.exit(f"FAIL: a drag of the clip's width moved {plan['animations'][i]['template']}'s {name} by {moved:.3f} of it under a {zoom:.2f}x camera")
print(f"ok: a dragged piece lands under the pointer with the camera pushed in ({plan['animations'][i]['template']} {name}, {zoom:.2f}x)")
PY
# Versions: the second animation kept as an alternate of the first, both rendered, then swapped in.
python3 - "$PROJECT/plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
a, b = plan["animations"][0], plan["animations"][1]
shift = a["start"] - b["start"]
a["alternates"] = [{"template": b["template"], "data": b["data"], "cues": {k: round(v + shift, 3) for k, v in b["cues"].items()}, "note": "second"}]
json.dump(plan, open(sys.argv[1], "w"), indent=2)
PY
"$DIRECTOR" validate "$PROJECT" >"$TMP/validate.txt" 2>&1 || { echo "FAIL: a plan with an alternate doesn't validate: $(cat "$TMP/validate.txt")" >&2; exit 1; }
"$DIRECTOR" animate-variants "$PROJECT" 0 >/dev/null
for k in 0 1; do
  [[ -s "$PROJECT/.checks/animation-0-v$k.mp4" ]] || { echo "FAIL: animate-variants didn't render v$k" >&2; exit 1; }
done
[[ -s "$PROJECT/.checks/animation-0-variants.png" ]] || { echo "FAIL: animate-variants wrote no sheet" >&2; exit 1; }
first=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['animations'][0]['template'])" "$PROJECT/plan.json")
"$DIRECTOR" animate-choose "$PROJECT" 0 0 >/dev/null
python3 - "$PROJECT/plan.json" "$first" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))["animations"][0]
if a.get("note") != "second" or a["alternates"][0]["template"] != sys.argv[2]:
    sys.exit(f"FAIL: animate-choose didn't swap in the alternate and keep the first: {a.get('note')}, {a['alternates']}")
PY
echo "ok: animate-variants renders each version and a sheet; animate-choose swaps one in and keeps the other"
# An overlay floats over the video: where it draws the frame changes, and elsewhere (the corners) the
# video shows through untouched. One kept stretch, hub over 1-4 s, compared at 2.5 s with and without it.
python3 - "$PROJECT/plan.json" Resources/animations/templates/hub.json <<'PY'
import json, sys
plan, t = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
plan["segments"] = [{"start": 0, "end": 6, "speed": 1}]
plan["animations"] = [{"start": 1, "end": 4, "template": "hub", "data": t["data"], "overlay": True,
                       "cues": {c["key"]: round(1 + c["at"] * 3 / t["length"], 3) for c in t["cues"]}},
                      {"start": 1, "end": 4, "template": "chart", "overlay": True, "cues": {"chart": 1.2, "callout": 3.5},
                       "data": {"title": "Bars", "values": [5, 9], "labels": ["Bare", "Words"]}},
                      {"start": 1, "end": 4, "template": "storyboard", "overlay": True, "cues": {"s1": 1.2},
                       "data": {"title": "", "steps": [{"cue": "s1", "do": "show", "id": "e", "kind": "sticker", "label": "Edge", "x": 99, "y": 50}]}},
                      {"start": 1, "end": 4, "template": "note", "sticker": {"x": 0.25, "y": 0.25, "w": 0.4},
                       "data": {"big": "3-4", "text": "years", "small": "and holding"}}]
plan.pop("look", None)
json.dump(plan, open(sys.argv[1], "w"), indent=2)
PY
"$DIRECTOR" validate "$PROJECT" >/dev/null || { echo "FAIL: a plan with an overlay doesn't validate" >&2; exit 1; }
frame=$((3 * $(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['output']['fps'])" "$PROJECT/plan.json") / 2 + 30))
"$DIRECTOR" still "$PROJECT" "$frame" "$TMP/over.png" >/dev/null 2>"$TMP/over.log"
# Overlay headings get the paper behind them; a chart's labels are bare text, straight on the video.
grep -q 'text "Bare" sits straight on the video' "$TMP/over.log" \
  || { echo "FAIL: no warning about the overlay's bare label: $(cat "$TMP/over.log")" >&2; exit 1; }
# A note sticker's clip is the sticker's width (0.4 of 480) and the card's own height, no empty paper.
note=$(find "$PROJECT/.animations" -name "note-*.mp4" | head -1)
size=$(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0 "$note")
python3 -c "import sys; w, h = map(int, sys.argv[1].split(',')); sys.exit(0 if w == 192 and 40 < h < 192 else 1)" "$size" \
  || { echo "FAIL: the note sticker's clip is $size, not 192 wide and cut to its card" >&2; exit 1; }
# Overlays aren't framed by a camera: a sticker at the edge is cut off; the hub's pieces all fit.
grep -q 'sticker "Edge" runs off the edge' "$TMP/over.log" || { echo "FAIL: no warning about a sticker off the edge: $(cat "$TMP/over.log")" >&2; exit 1; }
if grep -q '(hub).*runs off the edge' "$TMP/over.log"; then echo "FAIL: the hub overlay's pieces called off the edge: $(cat "$TMP/over.log")" >&2; exit 1; fi
if grep -q 'text "One plugin for all of them"' "$TMP/over.log"; then echo "FAIL: the overlay's heading has no backing: $(cat "$TMP/over.log")" >&2; exit 1; fi
ls "$PROJECT"/.animations/hub-*.mov >/dev/null || { echo "FAIL: the overlay didn't render to a .mov" >&2; exit 1; }
python3 - "$PROJECT/plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
plan["animations"] = []
json.dump(plan, open(sys.argv[1], "w"), indent=2)
PY
"$DIRECTOR" still "$PROJECT" "$frame" "$TMP/under.png" >/dev/null 2>&1
for f in over under; do ffmpeg -v error -i "$TMP/$f.png" -f rawvideo -pix_fmt rgb24 -y "$TMP/$f.rgb"; done
size=$(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0 "$TMP/over.png")
python3 - "$TMP/over.rgb" "$TMP/under.rgb" "$size" <<'PY'
import sys
over, under = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read()
w, h = map(int, sys.argv[3].split(","))
def px(buf, x, y): i = (y * w + x) * 3; return buf[i:i + 3]
corners = [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)]
for x, y in corners:
    d = max(abs(a - b) for a, b in zip(px(over, x, y), px(under, x, y)))
    if d > 6: sys.exit(f"FAIL: the overlay covers the video at ({x},{y}): {tuple(px(over, x, y))} vs {tuple(px(under, x, y))}")
changed = sum(1 for i in range(0, len(over), 3) if max(abs(over[i + k] - under[i + k]) for k in range(3)) > 30) / (w * h)
if changed < 0.02: sys.exit(f"FAIL: the overlay drew almost nothing ({changed:.1%} of the frame changed)")
print(f"ok: the overlay draws over {changed:.0%} of the frame and the video shows through at the corners")
PY
# A sticker's crayon mark never runs through its text: the note lays its lines out clear of the mark
# (a squiggle under a long word, with a line under that, crossed it), in a theme that sets note text in capitals too, and the
# mark probe names a mark that does cross text, here a video's own template that strikes its line out.
mkdir -p "$PROJECT/animations/templates"
cat > "$PROJECT/animations/templates/crossed.js" <<'JS'
TEMPLATES.crossed = function () {
  const card = document.createElement("div");
  card.id = "sticker"; card.className = "note";
  card.innerHTML = '<div class="line"><span class="big marked">Big</span></div><div class="small">struck out</div>';
  document.body.appendChild(card);
  const small = card.querySelector(".small"), svg = document.createElementNS(NS, "svg"), p = document.createElementNS(NS, "path");
  const y = small.offsetTop + small.offsetHeight / 2;
  svg.setAttribute("class", "mark"); svg.setAttribute("width", card.offsetWidth); svg.setAttribute("height", card.offsetHeight);
  p.setAttribute("d", `M0,${y} L${card.offsetWidth},${y}`); p.setAttribute("stroke-width", 6);
  svg.appendChild(p); card.appendChild(svg);
  return () => {};
};
JS
echo '{"name": "crossed", "title": "Crossed", "summary": "A mark through its text.", "length": 2, "fields": [], "cues": [], "data": {}}' \
  > "$PROJECT/animations/templates/crossed.json"
python3 - "$PROJECT/plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
plan["look"] = {"animationTheme": "probe"}
sticker = {"x": 0.5, "y": 0.3, "w": 0.6}
def note(start, data): return {"start": start, "end": start + 1, "template": "note", "sticker": sticker, "cues": {"mark": start + 0.2}, "data": data}
plan["animations"] = [
    {"start": 1, "end": 2, "template": "crossed", "sticker": sticker, "data": {}, "cues": {}},
    note(2.5, {"big": "self-hosted", "small": "my models, my permissions", "mark": "underline"}),
    note(4, {"big": "13", "text": "sec later", "small": "and it answered", "mark": "oval"}),
    note(5.5, {"big": "9000", "text": "power", "small": "and rising", "mark": "burst"}),
]
json.dump(plan, open(sys.argv[1], "w"), indent=2)
PY
"$DIRECTOR" animate "$PROJECT" > "$TMP/marks.log" 2>&1 || { cat "$TMP/marks.log" >&2; echo "FAIL: the mark stickers didn't render" >&2; exit 1; }
[[ -f "$PROJECT/animations/themes/probe/theme.js" ]] || { echo "FAIL: the video didn't keep a copy of its theme when it rendered" >&2; exit 1; }
echo "ok: the video keeps a copy of its theme in animations/themes/"
grep -q 'the mark on "Big" crosses the text "struck out"' "$TMP/marks.log" \
  || { echo "FAIL: a mark through a sticker's text wasn't reported: $(cat "$TMP/marks.log")" >&2; exit 1; }
if grep -q '(note).*crosses the text' "$TMP/marks.log"; then echo "FAIL: a note's mark crosses its text: $(cat "$TMP/marks.log")" >&2; exit 1; fi
# A template can come with a video someone sent, so its page reads only the app's animation folder:
# a logo from logos.json loads (through sd-asset://), a local file elsewhere doesn't.
ffmpeg -v error -f lavfi -i color=red:s=64x64 -frames:v 1 -y "$TMP/outside-red.png"
mkdir -p "$PROJECT/animations/logos" "$PROJECT/animations/templates"
cp "$TMP/outside-red.png" "$PROJECT/animations/logos/red.png"
echo '{"red": "red.png"}' >"$PROJECT/animations/logos/logos.json"
cat >"$PROJECT/animations/templates/probe.js" <<JS
"use strict";
TEMPLATES.probe = function () {
  for (const [left, src] of [[0, LOGOS.red], [50, "file://$TMP/outside-red.png"]]) {
    const img = new Image();
    img.style.cssText = \`position:fixed;z-index:99;top:0;left:\${left}vw;width:50vw;height:100vh\`;
    img.src = src;
    document.body.appendChild(img);
  }
  return () => {};
};
JS
# A heredoc inside < <(...) breaks under macOS /bin/bash 3.2 (CI), so go through a file.
python3 - "$PROJECT/plan.json" >"$TMP/probe-index.txt" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
plan["animations"].append({"start": 1, "end": 3, "template": "probe", "data": {}, "cues": {}})
json.dump(plan, open(sys.argv[1], "w"), indent=2)
print(len(plan["animations"]) - 1, 1)
PY
read -r PROBE PROBE_START <"$TMP/probe-index.txt"
"$DIRECTOR" animate-test "$PROJECT" "$PROBE" "$(python3 -c "print($PROBE_START + 0.5)")" "$TMP/probe.mp4" >"$TMP/probe.txt" 2>&1 \
  || { cat "$TMP/probe.txt" >&2; echo "FAIL: the probe template didn't render" >&2; exit 1; }
ffmpeg -v error -i "$TMP/probe.mp4" -frames:v 1 -f rawvideo -pix_fmt rgb24 -y "$TMP/probe.rgb"
python3 - "$TMP/probe.rgb" "$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$TMP/probe.mp4")" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w, h = map(int, sys.argv[2].split(","))
def red(x):
    i = ((h // 2) * w + x) * 3
    r, g, b = data[i:i + 3]
    return r > 180 and g < 80 and b < 80
if not red(w // 4): sys.exit("FAIL: a logo from logos.json didn't load in the animation page")
if red(3 * w // 4): sys.exit("FAIL: the animation page loaded a local file outside the app's animation folder")
print("ok: the animation page loads its logos and no other local file")
PY
echo "animation checks passed"
