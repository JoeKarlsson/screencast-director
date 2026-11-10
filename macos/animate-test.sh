#!/usr/bin/env bash
# Animation render check: adds one animation per bundled template to a synthetic project, renders
# them with `director animate` (offscreen WebKit), and fails when a template throws, a clip is missing
# or the wrong length, or its last frame is blank; then a one-second `animate-test`.
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
for i, path in enumerate(sorted(glob.glob(os.path.join(templates, "*.json")))):
    t = json.load(open(path))
    start = 1 + i * 4
    squeeze = 3 / t["length"]
    plan["animations"].append({
        "start": start, "end": start + 3, "template": t["name"], "data": t["data"],
        "cues": {c["key"]: round(start + c["at"] * squeeze, 3) for c in t["cues"]},
    })
json.dump(plan, open(plan_path, "w"), indent=2)
PY

"$DIRECTOR" animate "$PROJECT"
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
# The zine theme draws its lines with p5.brush on a WebGL canvas: they must show, and the stage must
# stay black (p5.brush clears to transparent white, which once turned the whole stage white).
python3 - "$PROJECT/plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
plan.setdefault("look", {})["animationTheme"] = "zine"
json.dump(plan, open(sys.argv[1], "w"), indent=2)
PY
"$DIRECTOR" animate-test "$PROJECT" 2 11.8 "$TMP/zine.mp4" >/dev/null
ffmpeg -v error -sseof -0.1 -i "$TMP/zine.mp4" -frames:v 1 -f rawvideo -pix_fmt gray -y "$TMP/zine.gray"
python3 - "$TMP/zine.gray" <<'PY'
import sys
px = open(sys.argv[1], "rb").read()
mean = sum(px) / len(px)
lit = sum(1 for p in px if p > 120) / len(px)
if mean > 60: sys.exit(f"FAIL: the zine stage isn't black (mean {mean:.0f})")
if lit < 0.002: sys.exit(f"FAIL: the zine frame has no lines or cards drawn ({lit:.4f} lit)")
print(f"ok: zine lines drawn in p5.brush on a black stage (mean {mean:.0f}, {lit:.3f} lit)")
PY

# A one-second test of the first animation: a 1 s clip and a sheet of its 12 frames.
"$DIRECTOR" animate-test "$PROJECT" 0 1.5 "$TMP/test.mp4" >/dev/null
length=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$TMP/test.mp4")
python3 -c "import sys; sys.exit(0 if abs(float(sys.argv[1]) - 1) < 0.1 else 1)" "$length" \
  || { echo "FAIL: animate-test made ${length}s, not 1s" >&2; exit 1; }
[[ -s "$TMP/test.png" ]] || { echo "FAIL: animate-test wrote no contact sheet" >&2; exit 1; }
if "$DIRECTOR" animate-test "$PROJECT" 0 30 "$TMP/late.mp4" 2>"$TMP/err"; then echo "FAIL: animate-test outside the animation succeeded" >&2; exit 1; fi
grep -q "isn't in it" "$TMP/err" || { echo "FAIL: animate-test outside the animation said: $(cat "$TMP/err")" >&2; exit 1; }
echo "ok: animate-test renders 1 s and its sheet, and refuses a moment outside the animation"
echo "animation checks passed"
