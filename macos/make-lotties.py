#!/usr/bin/env python3
"""Writes the Lottie overlays built into the app (Resources/animations/lottie/), all drawn here from
code: hand-drawn marks (circle, underline, arrows, box, check, cross, burst), pop-ins (heart, star,
!, ?), confetti and loops (sparkle, click, spinner, pulse). Hot pink with a black shadow or rim so
they read over a busy screen; the lottie template's `color` swaps the pink for a profile's accent.

Each file carries `meta.d` (what it's for, shown by `director lottie list` and the app's picker) and,
when it plays once and holds its last frame, a top-level `"loop": false` the template reads.

    python3 macos/make-lotties.py
"""
import json
import math
import os
import random

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Resources/animations/lottie")
FPS = 30
PINK = [1, 0.31, 0.85, 1]
INK = [0.07, 0.07, 0.07, 1]
YELLOW = [1, 0.84, 0.2, 1]
CYAN = [0.25, 0.8, 1, 1]
WHITE = [1, 1, 1, 1]
SHADOW = (5, 6)

# Eases for a keyframe's outgoing segment, as CSS cubic-bezier (x1, y1, x2, y2).
EASE_OUT = (0.16, 1, 0.3, 1)
EASE_IN_OUT = (0.45, 0, 0.25, 1)
OVERSHOOT = (0.34, 1.56, 0.64, 1)
LINEAR = (0, 0, 1, 1)
# The site's draw-in curves (joekarlsson.com motion.css): a one-stroke scribble, and each stroke of a mark.
PEN = (0.45, 0.55, 0.3, 1)
STROKE = (0.3, 0.6, 0.4, 1)


def r(v):
    return round(v, 1)


def static(k):
    return {"a": 0, "k": k}


def keys(*frames):
    """An animated property from (frame, value, ease) tuples; a value is a number or a list."""
    out = []
    for i, (t, v, *ease) in enumerate(frames):
        k = {"t": t, "s": v if isinstance(v, list) else [v]}
        if i < len(frames) - 1:
            x1, y1, x2, y2 = ease[0] if ease else EASE_OUT
            k["o"] = {"x": [x1], "y": [y1]}
            k["i"] = {"x": [x2], "y": [y2]}
        out.append(k)
    return {"a": 1, "k": out}


def path(points, closed=False, smooth=True):
    """A bezier path through points, smoothed Catmull-Rom style unless `smooth` is off (corners)."""
    n = len(points)
    ins, outs = [], []
    for i in range(n):
        if not smooth:
            ins.append([0, 0]); outs.append([0, 0]); continue
        prev = points[(i - 1) % n] if closed or i > 0 else points[i]
        nxt = points[(i + 1) % n] if closed or i < n - 1 else points[i]
        tx, ty = (nxt[0] - prev[0]) / 6, (nxt[1] - prev[1]) / 6
        ins.append([r(-tx), r(-ty)]); outs.append([r(tx), r(ty)])
    return {"ty": "sh", "ks": static({"i": ins, "o": outs, "v": [[r(x), r(y)] for x, y in points], "c": closed})}


def ellipse(cx, cy, w, h=None):
    return {"ty": "el", "p": static([cx, cy]), "s": static([w, h or w])}


def stroke(color, width, opacity=100):
    return {"ty": "st", "c": static(color), "o": static(opacity), "w": static(width), "lc": 2, "lj": 2, "ml": 4}


def fill(color):
    return {"ty": "fl", "c": static(color), "o": static(100), "r": 1}


def trim(end, start=None):
    return {"ty": "tm", "s": start or static(0), "e": end, "o": static(0), "m": 1}


def group(items, p=(0, 0)):
    tr = {"ty": "tr", "p": static(list(p)), "a": static([0, 0]), "s": static([100, 100]), "r": static(0), "o": static(100)}
    return {"ty": "gr", "it": items + [tr]}


def strokes(paths, color, width):
    """Each (path, draw) stroked in `color` over an offset black copy; `draw` trims it on (None: drawn)."""
    def one(shape, draw, c, p=(0, 0)):
        return group([shape] + ([trim(draw)] if draw else []) + [stroke(c, width)], p)
    # Earlier shapes draw on top, so every colored stroke comes before every shadow.
    return [one(s, d, color) for s, d in paths] + [one(s, d, INK, SHADOW) for s, d in paths]


def outlined(shapes, color, outline=12):
    """Filled shapes with a black rim (the stroke under the fill shows outside it)."""
    return [group(shapes + [fill(color), stroke(INK, outline)])]


def layer(name, shapes, op, w, h, ks=None, ind=1):
    base = {"o": static(100), "r": static(0), "p": static([w / 2, h / 2, 0]), "a": static([w / 2, h / 2, 0]),
            "s": static([100, 100, 100])}
    base.update(ks or {})
    return {"ddd": 0, "ind": ind, "ty": 4, "nm": name, "sr": 1, "ks": base, "ao": 0, "shapes": shapes,
            "ip": 0, "op": op, "st": 0, "bm": 0}


def write(name, w, h, op, layers, about, loop=True):
    doc = {"v": "5.7.4", "fr": FPS, "ip": 0, "op": op, "w": w, "h": h, "nm": name, "ddd": 0, "assets": [],
           "meta": {"g": "Screencast Director make-lotties.py", "d": about}, "layers": layers}
    if not loop:
        doc["loop"] = False
    with open(os.path.join(OUT, f"{name}.json"), "w") as f:
        json.dump(doc, f, separators=(",", ":"))


def pop(at=0):
    """Scale keyframes that spring on from nothing with an overshoot."""
    return keys((at, [0, 0, 100], OVERSHOOT), (at + 7, [112, 112, 100], EASE_IN_OUT), (at + 12, [100, 100, 100]))


def draw(start, frames, ease=PEN):
    """A trim end that draws a stroke on from `start` over `frames`, in the site's pen curve."""
    return keys((start, 0, ease), (start + frames, 100))


def rotated(points, deg, cx, cy):
    a = math.radians(deg)
    return [(cx + (x - cx) * math.cos(a) - (y - cy) * math.sin(a), cy + (x - cx) * math.sin(a) + (y - cy) * math.cos(a))
            for x, y in points]


# MARK: Hand-drawn marks (play once, then hold)

def circle():
    rng = random.Random(3)
    w, h, pts = 520, 340, []
    for k in range(29):  # a bit more than one turn, so the ends overlap like a pen loop
        a = math.radians(200 + k * 14.5)
        rx, ry = 225 + rng.uniform(-6, 6) - k * 0.6, 135 + rng.uniform(-5, 5) - k * 0.4
        pts.append((w / 2 + rx * math.cos(a), h / 2 + ry * math.sin(a)))
    shapes = strokes([(path(pts), draw(0, 27))], PINK, 14)
    write("circle", w, h, 45, [layer("circle", shapes, 45, w, h)], "A hand-drawn oval that draws itself around something", loop=False)


def underline():
    w, h = 620, 120
    pts = [(30, 70), (140, 62), (260, 66), (380, 58), (500, 60), (585, 46)]
    shapes = strokes([(path(pts), draw(0, 15))], PINK, 16)
    write("underline", w, h, 30, [layer("underline", shapes, 30, w, h)], "A quick hand-drawn swoosh under a word", loop=False)


def box():
    rng = random.Random(7)
    w, h = 600, 360
    corners = [(40, 46), (560, 38), (566, 318), (34, 324), (44, 40), (300, 34)]
    pts = []
    for (x0, y0), (x1, y1) in zip(corners, corners[1:]):
        for k in range(4):
            f = k / 4
            pts.append((x0 + (x1 - x0) * f + rng.uniform(-3, 3), y0 + (y1 - y0) * f + rng.uniform(-3, 3)))
    pts.append(corners[-1])
    shapes = strokes([(path(pts), draw(0, 33))], PINK, 12)
    write("box", w, h, 45, [layer("box", shapes, 45, w, h)], "A hand-drawn rectangle that draws itself around part of the screen", loop=False)


def arrow(name, deg):
    w = h = 400
    tip = (350, 206)
    shaft = rotated([(50, 260), (130, 215), (230, 200), (330, 205), tip], deg, 200, 200)
    head = rotated([(300, 160), tip, (304, 252)], deg, 200, 200)
    shapes = strokes([(path(shaft), draw(0, 12, STROKE)), (path(head, smooth=False), draw(12, 9, STROKE))], PINK, 16)
    write(name, w, h, 30, [layer(name, shapes, 30, w, h)], f"A hand-drawn arrow that draws itself, pointing {name.split('-')[1]}", loop=False)


def check():
    w = h = 400
    shapes = strokes([(path([(90, 215), (170, 295), (320, 105)], smooth=False), draw(0, 12))], PINK, 36)
    ks = {"s": keys((11, [100, 100, 100], EASE_OUT), (15, [114, 114, 100], EASE_IN_OUT), (21, [100, 100, 100]))}
    write("check", w, h, 30, [layer("check", shapes, 30, w, h, ks)], "A checkmark that draws itself and pops", loop=False)


def cross():
    w = h = 400
    shapes = strokes([(path([(105, 105), (295, 295)], smooth=False), draw(0, 9, STROKE)),
                      (path([(295, 105), (105, 295)], smooth=False), draw(9, 9, STROKE))], PINK, 36)
    ks = {"r": keys((17, -6, OVERSHOOT), (25, 0))}
    write("cross", w, h, 36, [layer("cross", shapes, 36, w, h, ks)], "An X that slashes itself on, for a wrong answer", loop=False)


def burst():
    w = h = 420
    shapes = []
    for k in range(10):
        a = math.radians(k * 36 - 90)
        r0, r1 = 92, (150 if k % 2 else 180)
        line = [(w / 2 + r0 * math.cos(a), h / 2 + r0 * math.sin(a)), (w / 2 + r1 * math.cos(a), h / 2 + r1 * math.sin(a))]
        shapes.append(group([path(line, smooth=False), trim(draw(k * 2, 8, STROKE)),
                             stroke(PINK, 13)]))
    write("burst", w, h, 36, [layer("burst", shapes, 36, w, h)],
          "Emphasis rays drawn around a point one after another (the middle stays clear), a ta-da", loop=False)


# MARK: Pop-ins (spring on, then hold)

def pop_layer(name, shapes, w, h, wiggle=True):
    ks = {"s": pop()}
    if wiggle:
        ks["r"] = keys((0, -14, EASE_OUT), (10, 7, EASE_IN_OUT), (18, -3, EASE_IN_OUT), (26, 0))
    return layer(name, shapes, 36, w, h, ks)


def heart():
    w = h = 400
    pts = [(200, 330), (95, 235), (62, 150), (110, 85), (170, 90), (200, 130), (230, 90), (290, 85), (338, 150), (305, 235)]
    write("heart", w, h, 36, [pop_layer("heart", outlined([path(pts, closed=True)], PINK, 14), w, h)], "A heart that springs on", loop=False)


def star():
    w = h = 400
    pts = []
    for k in range(10):
        a = math.radians(-90 + k * 36)
        rad = 165 if k % 2 == 0 else 72
        pts.append((200 + rad * math.cos(a), 205 + rad * math.sin(a)))
    ks = {"s": pop(), "r": keys((0, -50, EASE_OUT), (18, 0))}
    write("star", w, h, 36, [layer("star", outlined([path(pts, closed=True, smooth=False)], PINK, 14), 36, w, h, ks)],
          "A star that spins and springs on", loop=False)


def exclaim():
    w, h = 240, 400
    bar = path([(85, 40), (155, 40), (138, 255), (102, 255)], closed=True, smooth=False)
    write("exclaim", w, h, 36, [pop_layer("exclaim", outlined([bar, ellipse(120, 325, 72)], PINK, 14), w, h)],
          "An exclamation mark that springs on and wobbles", loop=False)


def question():
    w, h = 300, 400
    curve = path([(72, 120), (100, 62), (160, 45), (222, 78), (228, 140), (180, 185), (150, 225), (150, 260)])
    shapes = [group([curve, stroke(PINK, 40)]), group([ellipse(150, 330, 56), fill(PINK)]),
              group([curve, stroke(INK, 62)]), group([ellipse(150, 330, 78), fill(INK)])]
    write("question", w, h, 36, [pop_layer("question", shapes, w, h)], "A question mark that springs on and wobbles", loop=False)


# MARK: Confetti (plays once)

def confetti():
    rng = random.Random(11)
    w = h = 600
    op, layers = 60, []
    for i in range(36):
        a = math.radians(rng.uniform(-150, -30))
        speed = rng.uniform(600, 950)  # px/s
        vx, vy = speed * math.cos(a), speed * math.sin(a)
        x0, y0, g = w / 2, h * 0.62, 900
        pos = []
        for f in range(0, op + 1, 6):
            t = f / FPS
            drag = 1 - 0.35 * t
            pos.append((f, [r(x0 + vx * t * drag), r(y0 + vy * t * drag + 0.5 * g * t * t), 0], LINEAR))
        shape = ellipse(0, 0, 20) if i % 3 == 0 else {"ty": "rc", "p": static([0, 0]), "s": static([30, 15]), "r": static(3)}
        spin = rng.choice([-1, 1]) * rng.uniform(360, 900)
        ks = {"a": static([0, 0, 0]), "p": keys(*pos), "r": keys((0, 0, LINEAR), (op, spin)),
              "o": keys((0, 100, LINEAR), (op - 14, 100, LINEAR), (op, 0)),
              "s": keys((0, [0, 0, 100], EASE_OUT), (4, [100, 100, 100]))}
        layers.append(layer(f"bit{i}", [group([shape, fill([PINK, YELLOW, CYAN, WHITE][i % 4]), stroke(INK, 3)])], op, w, h, ks, ind=i + 1))
    write("confetti", w, h, op, layers, "A burst of confetti that flies up and falls away", loop=False)


# MARK: Loops

def sparkle():
    w = h = 400
    layers = []
    for i, (cx, cy, size, start) in enumerate([(150, 175, 190, 0), (290, 105, 120, 16), (270, 280, 150, 32)]):
        pts = []
        for k in range(8):
            a = math.radians(-90 + k * 45)
            rad = size / 2 if k % 2 == 0 else size / 9
            pts.append((cx + rad * math.cos(a), cy + rad * math.sin(a)))
        ks = {"a": static([cx, cy, 0]), "p": static([cx, cy, 0]),
              "s": keys((start, [0, 0, 100], OVERSHOOT), (start + 6, [100, 100, 100], LINEAR), (start + 11, [100, 100, 100], EASE_IN_OUT), (start + 16, [0, 0, 100])),
              "r": keys((start, -20, LINEAR), (start + 16, 20))}
        layers.append(layer(f"spark{i}", outlined([path(pts, closed=True, smooth=False)], PINK, 8), 48, w, h, ks, ind=i + 1))
    write("sparkle", w, h, 48, layers, "Three twinkling sparkles, on a loop")


def click():
    w = h = 260
    layers = [layer("dot", outlined([ellipse(w / 2, h / 2, 44)], PINK, 8), 24, w, h,
                    {"s": keys((0, [70, 70, 100], OVERSHOOT), (6, [110, 110, 100], EASE_IN_OUT), (24, [70, 70, 100]))})]
    for i, delay in enumerate([0, 12]):
        size = keys((delay, [20, 20], EASE_OUT), (delay + 18, [220, 220]))
        ring = {"ty": "el", "p": static([w / 2, h / 2]), "s": size}
        layers.append(layer(f"ring{i}", [group([ring, stroke(PINK, 9)]), group([ring, stroke(INK, 9)], (3, 4))], 24, w, h,
                            {"o": keys((delay, 100, LINEAR), (delay + 18, 0))}, ind=i + 2))
    write("click", w, h, 24, layers, "Rings rippling out from a click, on a loop")


def spinner():
    w = h = 240
    ring = ellipse(w / 2, h / 2, 170)
    arc = keys((0, 8, EASE_IN_OUT), (15, 70, EASE_IN_OUT), (30, 8))
    shapes = [group([ring, trim(arc), stroke(PINK, 22)]), group([ring, stroke(INK, 22, opacity=35)])]
    write("spinner", w, h, 30, [layer("spinner", shapes, 30, w, h, {"r": keys((0, 0, LINEAR), (30, 360))})], "A loading spinner, for a wait")


def pulse():
    w = h = 400
    ks = {"s": keys((0, [20, 20, 100], EASE_IN_OUT), (30, [100, 100, 100], EASE_IN_OUT), (60, [20, 20, 100]))}
    write("pulse", w, h, 60, [layer("pulse", outlined([ellipse(200, 200, 300)], PINK, 10), 60, w, h, ks)],
          "A dot that grows and shrinks, on a loop")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for make in (circle, underline, box, check, cross, burst, heart, star, exclaim, question, confetti, sparkle, click, spinner, pulse):
        make()
    for deg, name in ((0, "arrow-right"), (90, "arrow-down"), (180, "arrow-left"), (-90, "arrow-up")):
        arrow(name, deg)
    print("\n".join(sorted(os.listdir(OUT))))
