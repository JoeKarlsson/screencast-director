#!/usr/bin/env python3
"""Draws the app's built-in hand-drawn marks (oval, burst, coil, rays, underline, asterisk) as SVG
paths and writes them into macos/Sources/DirectorCore/MarksBuiltIn.swift. Edit this and rerun; never
the Swift file. A theme's marks.json replaces any of them by name.

    macos/make-marks.py            # writes the Swift file
    macos/make-marks.py --svg out  # also a preview sheet, out.svg
"""
import math, random, sys
from pathlib import Path

def smooth(pts):
    """A polyline as quadratic curves through the midpoints, like a pen that doesn't stop at corners."""
    f = lambda p: f"{p[0]:.1f},{p[1]:.1f}"
    d = f"M{f(pts[0])}"
    for i in range(1, len(pts) - 1):
        mid = ((pts[i][0] + pts[i + 1][0]) / 2, (pts[i][1] + pts[i + 1][1]) / 2)
        d += f" Q{f(pts[i])} {f(mid)}"
    return d + f" L{f(pts[-1])}"

def wobble(rng, n, amp):
    """Low-frequency noise: a few random sine waves summed, so the hand drifts rather than jitters."""
    waves = [(rng.uniform(0.6, 2.2), rng.uniform(0, 2 * math.pi), rng.uniform(.4, 1)) for _ in range(3)]
    total = sum(w[2] for w in waves)
    return [amp * sum(a * math.sin(2 * math.pi * k * i / n + ph) for k, ph, a in waves) / total for i in range(n + 1)]

def oval(rng):
    # One loop round a word with the end running past the start, tilted a little, wider on one side.
    n, cx, cy, rx, ry = 64, 200, 82, 182, 64
    start, sweep, tilt = math.radians(200), math.radians(392), math.radians(-4)
    dr = wobble(rng, n, 11)
    pts = []
    for i in range(n + 1):
        a = start + sweep * i / n
        k = 1 + dr[i] / 100 + 0.05 * (i / n)  # the second lap swings a little wider
        x, y = rx * k * math.cos(a), ry * k * math.sin(a)
        pts.append((cx + x * math.cos(tilt) - y * math.sin(tilt), cy + x * math.sin(tilt) + y * math.cos(tilt)))
    return "0 0 400 160", smooth(pts)

def burst(rng):
    # Short strokes flaring out from a gap in the middle, uneven in angle and length.
    strokes, cx, cy = [], 100, 100
    count = 13
    for i in range(count):
        a = 2 * math.pi * i / count + rng.uniform(-.12, .12)
        r0, r1 = rng.uniform(26, 36), rng.uniform(72, 94)
        bend = rng.uniform(-.06, .06)
        pts = []
        for j in range(5):
            r = r0 + (r1 - r0) * j / 4
            b = a + bend * math.sin(math.pi * j / 4)
            pts.append((cx + r * math.cos(b), cy + r * math.sin(b)))
        strokes.append(smooth(pts))
    return "0 0 200 200", " ".join(strokes)

def coil(rng):
    # A run of loose loops, like a phone cord: a prolate cycloid, its loops drifting in size.
    n, loops = 240, 6
    dr = wobble(rng, n, 10)
    pts = []
    for i in range(n + 1):
        t = i / n
        th = 2 * math.pi * loops * t
        a, b = 21, 58 + dr[i]
        x = 70 + (a * th - b * math.sin(th)) * 760 / (a * 2 * math.pi * loops)
        y = 150 - b * math.cos(th) * 0.95 + 18 * math.sin(math.pi * t * 1.3)
        pts.append((x, y))
    return "0 0 900 300", smooth(pts)

def rays(rng):
    # Three emphasis ticks fanning up and out.
    strokes = []
    for (x0, y0, x1, y1) in [(30, 88, 10, 46), (78, 76, 82, 14), (114, 92, 150, 56)]:
        pts = [(x0 + (x1 - x0) * j / 4 + rng.uniform(-1.5, 1.5), y0 + (y1 - y0) * j / 4 + rng.uniform(-1.5, 1.5)) for j in range(5)]
        strokes.append(smooth(pts))
    return "0 0 160 120", " ".join(strokes)

def underline(rng):
    # A quick stroke rising a little to the right, then a short second pass under its end.
    n = 30
    dy = wobble(rng, n, 3)
    first = [(8 + 584 * i / n, 48 - 30 * (i / n) ** 1.6 + dy[i]) for i in range(n + 1)]
    second = [(400 + 170 * i / 8, 46 - 14 * i / 8 + rng.uniform(-1, 1)) for i in range(9)]
    return "0 0 600 60", smooth(first) + " " + smooth(second)

def asterisk(rng):
    strokes = []
    for k in range(3):
        a = math.radians(90 + 60 * k + rng.uniform(-6, 6))
        r = rng.uniform(38, 44)
        pts = [(50 + r * math.cos(a) * s + rng.uniform(-1.2, 1.2), 50 + r * math.sin(a) * s + rng.uniform(-1.2, 1.2)) for s in (-1, -.5, 0, .5, 1)]
        strokes.append(smooth(pts))
    return "0 0 100 100", " ".join(strokes)

def fit(vb, d, margin=0.04):
    """Scales a drawing about its box's center so every point (curve controls too) sits inside the
    box with a margin: a mark is laid out by its box, so nothing may spill out of it."""
    import re
    w, h = map(float, vb.split()[2:])
    nums = [float(n) for n in re.findall(r"-?[\d.]+", d)]
    xs, ys = nums[0::2], nums[1::2]
    k = min(1, (w / 2 - w * margin) / max(abs(x - w / 2) for x in xs), (h / 2 - h * margin) / max(abs(y - h / 2) for y in ys))
    if k >= 1:
        return vb, d
    it = iter(nums)
    pts = [(w / 2 + (x - w / 2) * k, h / 2 + (y - h / 2) * k) for x, y in zip(it, it)]
    out, i = [], 0
    for tok in re.split(r"(-?[\d.]+,-?[\d.]+)", d):
        if re.fullmatch(r"-?[\d.]+,-?[\d.]+", tok):
            out.append(f"{pts[i][0]:.1f},{pts[i][1]:.1f}"); i += 1
        else:
            out.append(tok)
    return vb, "".join(out)

MARKS = {"oval": oval, "burst": burst, "coil": coil, "rays": rays, "underline": underline, "asterisk": asterisk}

def main():
    root = Path(__file__).resolve().parent
    marks = {name: fit(*make(random.Random(f"mark-{name}"))) for name, make in MARKS.items()}
    body = "\n".join(f'    "{n}": Mark(viewBox: "{vb}", path: "{p}"),' for n, (vb, p) in marks.items())
    out = root / "Sources/DirectorCore/MarksBuiltIn.swift"
    out.write_text(
        "// Generated by macos/make-marks.py: edit that and rerun, not this file.\n// swiftlint:disable line_length\n\n"
        "extension MarkSet {\n  /// The app's own marks, drawn for it (no theme's).\n"
        f"  static let builtInMarks: [String: Mark] = [\n{body}\n  ]\n}}\n")
    print(f"wrote {out}")
    if "--svg" in sys.argv:
        dest = Path(sys.argv[sys.argv.index("--svg") + 1])
        cells = []
        for k, (n, (vb, p)) in enumerate(marks.items()):
            w, h = map(float, vb.split()[2:])
            s = min(280 / w, 180 / h)
            cells.append(f'<g transform="translate({20 + (k % 3) * 320},{20 + (k // 3) * 240}) scale({s})"><rect width="{w}" height="{h}" fill="none" stroke="#ddd" stroke-width="{1/s}"/>'
                         f'<path d="{p}" fill="none" stroke="#E0A800" stroke-width="{7/s}" stroke-linecap="round" stroke-linejoin="round"/></g>'
                         f'<text x="{20 + (k % 3) * 320}" y="{230 + (k // 3) * 240}" font-family="Helvetica" font-size="16">{n}</text>')
        dest.with_suffix(".svg").write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="1320" height="500" style="background:#fff">{"".join(cells)}</svg>')

if __name__ == "__main__":
    main()
