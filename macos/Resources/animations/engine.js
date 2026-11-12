// Shared motion-graphics kit for the animation templates: the Vox-style look (paper, grain, a camera
// that always drifts, stickers that pop in with overshoot, hand-drawn lines that draw on, highlighter
// swipes) and the init/seek entry points the renderer calls.
"use strict";
const NS = "http://www.w3.org/2000/svg";
const TEMPLATES = {};
let cam, lines, LOGOS = {};
// The Lottie animation the data names (config.lottie, its parsed JSON), for the lottie template.
let LOTTIE = null;
// Floating over the video (config.overlay): templates place things where asked instead of framing them.
let OVERLAY = false;
// The look (config.theme): "" is the paper collage; "terminal" is a 90s screen with its own motion.
// Any other theme comes from a pack: its stylesheet (config.themeCSS) and scripts, run after this file,
// which register THEMES[name] with any of these hooks (HOOKS while it's the theme):
//   setup({stage, k, config})      once the stage is sized, before the template builds (k: px per stage px)
//   stroke(path, width) -> width   a new line's stroke
//   curve(a, b, t, seed, bend, tangle) -> {d, at}   a line's hand-drawn route (a falsy return keeps the paper's)
//   draw(path, curve, progress, opacity) -> bool     after a line is drawn; true hides the SVG path
//   highlight(hl, p) -> bool       a heading's highlight at progress p; true skips the highlighter swipe
//   beforePackets(t), tick(t)      each frame, before the packets and last
let THEME = "";
const THEMES = {};
let HOOKS = {};
// The hand-drawn marks (config.marks: the app's, or the theme's over them), {name: {viewBox, path}}.
let SCRIBBLES = {};

// --- motion -----------------------------------------------------------------
const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
// Springs, in closed form: the step response from 0 to 1 at x (x = 1 is the move's length), a pure
// function of time like everything here. `zeta` under 1 overshoots a little and settles; 1 is
// critically damped (no overshoot). Both start from rest, so a move accelerates and decelerates.
function spring(x, zeta = 1) {
  if (x <= 0) return 0;
  if (zeta >= 1) { const w = 7 * x; return 1 - (1 + w) * Math.exp(-w); }
  // Settled to 1% by x = 1.
  const w = 4.6 / zeta, wd = w * Math.sqrt(1 - zeta * zeta);
  return 1 - Math.exp(-zeta * w * x) * (Math.cos(wd * x) + zeta / Math.sqrt(1 - zeta * zeta) * Math.sin(wd * x));
}
// A critically damped spring, landing exactly on 1 at x = 1.
const easeOut = x => clamp(spring(clamp(x)) / spring(1));
// The start of the 12 fps frame t falls in: a number counting up shows one value a frame, so motion
// blur's snapshots (spread inside the frame) never average two numbers into a smear.
const frameStart = t => Math.floor(t * 12 + 1e-4) / 12;
// Accelerating away, for things leaving: a decelerating exit covers most of its distance before the eye can follow.
const easeIn = x => clamp(x) ** 2;
const easeInOut = x => { x = clamp(x); return x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
// Hand-tuning from the plan (config.tune): `pop` scales how long pop-ins and draw-ons take, `bounce`
// is how far a pop overshoots (0 none, .4 the house spring), `stagger` scales the gaps between words
// and strokes. Unset, everything moves as designed.
let TUNE = { pop: 1, bounce: .4, stagger: 1 };
function applyTune(tune = {}) {
  TUNE = {
    pop: clamp(tune.pop ?? 1, .25, 4),
    bounce: clamp(tune.bounce ?? .4, 0, .8),
    stagger: clamp(tune.stagger ?? 1, 0, 4),
  };
}
// A sticker slapped down: springs past full size (about 9%) and settles.
function popScale(t, start, dur = .42) {
  if (t < start) return 0;
  // Terminal: no bounce; it flickers on like a screen element, then holds.
  if (THEME === "terminal") return t - start < .2 ? Math.floor((t - start) * 24) % 2 === 0 ? 1 : 0 : 1;
  return spring((t - start) / (dur * TUNE.pop), 1 - TUNE.bounce);
}
// Pop-ins used to blur here in place of motion blur. The renderer now averages subframes for real
// motion blur, so this stays only for templates frozen into videos before that.
function popBlur() { return 0; }
function rand(seed) { let s = Math.floor(seed) * 9301 + 49297; return () => (s = (s * 9301 + 49297) % 233280) / 233280; }

// --- building blocks ---------------------------------------------------------
function el(cls, html = "") { const d = document.createElement("div"); d.className = "abs " + cls; d.innerHTML = html; cam.appendChild(d); return d; }
const ICONS = {
  lock: '<svg viewBox="0 0 24 24"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>',
  shield: '<svg viewBox="0 0 24 24"><path d="M12 3l7 3v5c0 5-3.5 8.5-7 10-3.5-1.5-7-5-7-10V6z"/><path d="M9 12l2 2 4-4"/></svg>',
  log: '<svg viewBox="0 0 24 24"><rect x="5" y="3" width="14" height="18" rx="2"/><path d="M9 8h6M9 12h6M9 16h4"/></svg>',
};
function esc(s) { return String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]); }
// A logo by name (config.logos maps names to file URLs), or the name itself in the sticker when there's no file.
function logoHTML(name) {
  const file = LOGOS[name];
  return file ? `<img src="${file}" alt="${esc(name)}">` : `<div class="word">${esc(name)}</div>`;
}
function path(width, color) {
  const p = document.createElementNS(NS, "path");
  const term = THEME === "terminal";
  p.setAttribute("fill", "none"); p.setAttribute("stroke", color);
  p.setAttribute("stroke-width", term ? Math.min(width, 3) : HOOKS.stroke ? HOOKS.stroke(p, width) : width);
  p.setAttribute("stroke-linecap", term ? "square" : "round"); p.setAttribute("stroke-linejoin", term ? "miter" : "round");
  p.setAttribute("pathLength", "1");
  lines.appendChild(p); return p;
}
function bez(p0, p1, p2, p3, u) { const v = 1 - u; return [0, 1].map(i => v*v*v*p0[i] + 3*v*v*u*p1[i] + 3*v*u*u*p2[i] + u*u*u*p3[i]); }
// A hand-drawn curve from a to b, "boiling" six times a second; `tangle` throws the middle around.
function handCurve(a, b, t, seed, bend = 0, tangle = 0) {
  if (THEME === "terminal") return elbow(a, b, t, seed);
  const themed = HOOKS.curve && HOOKS.curve(a, b, t, seed, bend, tangle);
  if (themed) return themed;
  const r = rand(seed * 31 + Math.floor(t * 6));
  const j = () => (r() - .5) * 3.2;
  const dx = b[0] - a[0], dy = b[1] - a[1], L = Math.hypot(dx, dy) || 1, nx = -dy / L, ny = dx / L;
  const r2 = rand(seed * 7 + 3), k = tangle * 520;
  const c1 = [a[0] + dx * .33 + nx * bend + (r2() - .5) * k + j(), a[1] + dy * .33 + ny * bend + (r2() - .5) * k + j()];
  const c2 = [a[0] + dx * .66 + nx * bend + (r2() - .5) * k + j(), a[1] + dy * .66 + ny * bend + (r2() - .5) * k + j()];
  return { d: `M${a[0] + j()},${a[1] + j()} C${c1} ${c2} ${b[0] + j()},${b[1] + j()}`, at: u => bez(a, c1, c2, b, u) };
}
// A squiggly line from a to b: a hand-wobbled wave (about 9 px high, a wave every 55 px, flat at the
// ends) along a gentle bow, boiling six times a second. The note's underline; themes may route lines with it.
function squiggle(a, b, t = 0, seed = 1) {
  const r = rand(seed * 31 + Math.floor(t * 6));
  const dx = b[0] - a[0], dy = b[1] - a[1], L = Math.hypot(dx, dy) || 1, nx = -dy / L, ny = dx / L;
  const n = Math.max(8, Math.round(L / 14)), waves = L / 55, bow = seed % 2 ? 30 : -30;
  const off = (u, j) => Math.sin(u * waves * 2 * Math.PI + seed) * 9 * Math.sin(Math.PI * u) + j + Math.sin(Math.PI * u) * bow;
  const pts = [];
  for (let i = 0; i <= n; i++) {
    const u = i / n, w = off(u, i === 0 || i === n ? 0 : (r() - .5) * 3);
    pts.push([a[0] + dx * u + nx * w, a[1] + dy * u + ny * w]);
  }
  const f = p => p.map(v => v.toFixed(1)).join(",");
  let d = `M${f(pts[0])}`;
  for (let i = 1; i < pts.length - 1; i++) d += ` Q${f(pts[i])} ${f([(pts[i][0] + pts[i + 1][0]) / 2, (pts[i][1] + pts[i + 1][1]) / 2])}`;
  d += ` L${f(pts[pts.length - 1])}`;
  return { d, at: u => { const w = off(clamp(u), 0); return [a[0] + dx * u + nx * w, a[1] + dy * u + ny * w]; } };
}
// A right-angle route from a to b (across, down or up, across), for the terminal theme. Its bend
// jitters a couple of pixels twelve times a second, like a signal on a CRT.
function elbow(a, b, t = 0, seed = 1) {
  const j = (rand(seed * 31 + Math.floor(t * 12))() - .5) * 4;
  const mx = Math.round((a[0] + b[0]) / 2 + j);
  const pts = [a, [mx, a[1]], [mx, b[1]], b];
  const lens = pts.slice(1).map((p, i) => Math.hypot(p[0] - pts[i][0], p[1] - pts[i][1]));
  const total = lens.reduce((x, y) => x + y, 0) || 1;
  const at = u => {
    let d = clamp(u) * total;
    for (let i = 0; i < lens.length; i++) {
      if (d <= lens[i] || i === lens.length - 1) {
        const k = lens[i] ? d / lens[i] : 0;
        return [pts[i][0] + (pts[i + 1][0] - pts[i][0]) * k, pts[i][1] + (pts[i + 1][1] - pts[i][1]) * k];
      }
      d -= lens[i];
    }
  };
  return { d: `M${pts.map(p => p.join(",")).join(" L")}`, at };
}
function place(node, x, y, s = 1, rot = 0, opacity = 1, blur = 0) {
  if (THEME === "terminal") rot = 0;
  node.style.transform = `translate(${x}px, ${y}px) rotate(${rot}deg) scale(${s})`;
  node.style.opacity = s <= 0.001 ? 0 : opacity;
  node.style.filter = blur > .2 ? `blur(${blur}px)` : "";
}
function drawPath(p, curve, progress, opacity = 1) {
  p.setAttribute("d", curve.d); p.style.strokeDasharray = 1; p.style.strokeDashoffset = 1 - clamp(progress);
  p.style.opacity = progress <= 0 ? 0 : opacity;
  if (packetLayer && curve.at && !curve.still && progress >= 1 && opacity > .05) packetLines.push({ p, curve, opacity });
  // A theme can draw the line itself (the path stays, hidden, for layout).
  if (HOOKS.draw && curve.at && HOOKS.draw(p, curve, progress, opacity)) p.style.visibility = "hidden";
}
// Puts a node just above the SVG lines (and above what a theme put there before), under every node
// made after it.
let lineTop = null;
function aboveLines(node) { (lineTop || lines).after(node); lineTop = node; }

// A heading with the `highlight` part swiped in highlighter.
// --- flourishes ----------------------------------------------------------------
// Moves from the explainers made with Claude (the "Claude Motion Tips" collection): headings revealed
// a word at a time out of a mask line, stickers slammed down with squash and stretch, a scribble burst
// flaring behind each landing, icons that draw themselves, and packets running along finished lines.

// Hand-drawn line icons in a 100-unit box, drawn on with drawIcons.
const ICON_PATHS = {
  laptop: "M20 26 H80 V64 H20 Z M10 72 H90 L84 82 H16 Z",
  prompter: "M18 18 H82 V54 H18 Z M28 30 H66 M28 41 H56 M34 54 L22 84 M66 54 L78 84",
  camera: "M12 34 H62 V74 H12 Z M62 46 L88 32 V76 L62 62 M22 26 H38",
  mic: "M38 16 A12 12 0 0 1 62 16 V44 A12 12 0 0 1 38 44 Z M26 40 A24 24 0 0 0 74 40 M50 64 V82 M34 84 H66",
  phone: "M32 10 H68 V90 H32 Z M44 80 H56",
  server: "M16 14 H84 V40 H16 Z M16 48 H84 V74 H16 Z M26 27 H40 M26 61 H40 M50 86 V74",
  database: "M18 22 A32 10 0 0 0 82 22 A32 10 0 0 0 18 22 V78 A32 10 0 0 0 82 78 V22 M18 50 A32 10 0 0 0 82 50",
  cloud: "M28 72 A16 16 0 0 1 26 40 A22 22 0 0 1 68 32 A18 18 0 0 1 76 72 Z",
  user: "M50 14 A16 16 0 1 1 49.9 14 Z M18 88 A32 30 0 0 1 82 88",
  doc: "M24 10 H62 L78 26 V90 H24 Z M62 10 V26 H78 M34 46 H68 M34 60 H68 M34 74 H56",
  chart: "M14 86 H88 M24 76 V52 M44 76 V34 M64 76 V44 M84 76 V20",
  bolt: "M56 8 L22 54 H48 L42 92 L78 42 H52 Z",
};
function iconHTML(name) {
  const d = ICON_PATHS[name];
  return d ? `<svg class="drawn" viewBox="0 0 100 100">${d.split(/(?=M)/).map(x => `<path pathLength="1" d="${x.trim()}"/>`).join("")}</svg>` : "";
}
// Draws a node's icon strokes one after another from `start`.
function drawIcons(node, t, start) {
  node.querySelectorAll("svg.drawn path").forEach((p, i) => {
    p.style.strokeDasharray = 1;
    p.style.strokeDashoffset = THEME === "terminal" ? (t >= start ? 0 : 1) : 1 - easeOut((t - start - i * .07 * TUNE.stagger) / (.3 * TUNE.pop));
  });
}
// A sticker slammed down: springs in, squashed on impact and stretched on the rebound. Terminal
// flickers on instead.
function land(node, x, y, t, start, size = 1, rot = 0, opacity = 1) {
  const s = popScale(t, start, .38);
  if (THEME === "terminal") return place(node, x, y, s * size, 0, opacity);
  const u = t - start, wob = u > 0 ? Math.exp(-u * 9) * Math.sin(u * 30) * .16 : 0;
  node.style.transform = `translate(${x}px, ${y}px) rotate(${rot * (1 - .4 * clamp(u / .4))}deg) scale(${s * size * (1 + wob)}, ${s * size * (1 - wob)})`;
  node.style.opacity = s <= .001 ? 0 : opacity;
  node.style.filter = "";
  // In the air its shadow falls wider and softer; it settles under the card as it lands.
  node.style.setProperty("--lift", u > 0 ? 1 - easeOut(u / (.3 * TUNE.pop)) : 1);
}
// The burst mark, in the accent, flaring behind a node as it lands and erasing.
function burstMark(behind) {
  if (THEME === "terminal" || !SCRIBBLES.burstDense) return null;
  const m = SCRIBBLES.burstDense, svg = document.createElementNS(NS, "svg");
  svg.setAttribute("viewBox", m.viewBox); svg.setAttribute("class", "abs burstmark");
  const g = document.createElementNS(NS, "g");
  g.setAttribute("stroke-width", 10 * m.viewBox.split(" ").map(Number)[2] / 330);
  const strokes = m.path.split(/(?=M)/).map(d => d.trim()).filter(Boolean).map(d => {
    const p = document.createElementNS(NS, "path");
    p.setAttribute("d", d); p.setAttribute("pathLength", "1"); p.style.strokeDasharray = 1; g.appendChild(p); return p;
  });
  svg.appendChild(g);
  (behind || cam.lastChild).before(svg);
  return { svg, strokes };
}
function drawBurst(b, x, y, t, start, size = 1, rot = 0) {
  if (!b) return;
  const u = t - start - .05;
  b.svg.style.opacity = u < 0 || u > .8 ? 0 : 1;
  b.svg.style.transform = `translate(${x}px, ${y}px) rotate(${rot * 3}deg) scale(${size * (.8 + .4 * easeOut(u / .5))})`;
  b.strokes.forEach((p, i) => { p.style.strokeDashoffset = u < 0 ? 1 : u < .55 ? 1 - easeOut((u - i * .012) / .2) : 2 - easeOut((u - .55) / .25); });
}
// Heading words rise out of a mask line, 60 ms apart (heading() wraps each word).
function revealHeading(h, t, start) {
  h.node.querySelectorAll(".rw > span").forEach((w, i) => {
    const gap = .06 * TUNE.stagger;
    const p = THEME === "terminal" ? (t >= start + i * gap ? 1 : 0) : spring((t - start - i * gap) / (.5 * TUNE.pop), .75);
    w.style.transform = `translateY(${(1 - p) * 110}%)`;
  });
}
// Packets: dots of the accent running along every finished line, two per line, toward its end.
// drawPath queues the lines; seek draws them (the terminal theme runs its own square packets).
let packetLayer = null, packetLines = [];
function setupPackets() {
  packetLayer = document.createElementNS(NS, "svg");
  packetLayer.setAttribute("class", "abs packets");
  packetLayer.setAttribute("width", STAGE.w); packetLayer.setAttribute("height", STAGE.h);
  // Above the lines (and anything a theme drew there), under every node made after it.
  (lineTop || lines).after(packetLayer);
}
function drawPackets(t) {
  const want = packetLines.length * 2;
  while (packetLayer.childNodes.length < want) {
    const c = document.createElementNS(NS, "circle");
    c.setAttribute("r", 11); c.setAttribute("fill", "var(--accent)");
    packetLayer.appendChild(c);
  }
  [...packetLayer.childNodes].forEach((c, k) => {
    const line = packetLines[k >> 1];
    if (!line) { c.style.visibility = "hidden"; return; }
    if (!packetIndex.has(line.p)) packetIndex.set(line.p, packetIndex.size);
    const i = packetIndex.get(line.p), u = (t * .85 + i * .37 + (k & 1) * .5) % 1;
    const [x, y] = line.curve.at(u);
    c.style.visibility = "visible";
    c.setAttribute("cx", x); c.setAttribute("cy", y);
    c.style.opacity = Math.sin(Math.PI * u) * line.opacity;
  });
  packetLines = [];
}
const packetIndex = new Map();
// How strongly a packet is arriving at the end of path p right now (1 on arrival, fading over about
// a quarter second), so a node can pop when data reaches it. 0 before its packets run.
function arrivalPulse(p, t) {
  if (!packetIndex.has(p)) return 0;
  const i = packetIndex.get(p);
  return Math.max(...[0, .5].map(k => Math.exp(-(((t * .85 + i * .37 + k) % 1) / .85) * 9)));
}
// The point where a line from a to b should stop: the edge of a box w by h centered on b, plus a gap.
function edgePoint(a, b, w, h, gap = 16) {
  const dx = a[0] - b[0], dy = a[1] - b[1], L = Math.hypot(dx, dy) || 1;
  const k = Math.min(w / 2 / (Math.abs(dx) || 1e-6), h / 2 / (Math.abs(dy) || 1e-6));
  const d = Math.min(L * .45, k * L + gap);
  return [b[0] + dx / L * d, b[1] + dy / L * d];
}

function heading(text, highlight) {
  const i = highlight ? text.indexOf(highlight) : -1;
  const html = i < 0 ? `<span class="wrapt"><span class="hl"></span>${esc(text)}</span>`
    : `${esc(text.slice(0, i))}<span class="wrapt"><span class="hl"></span>${esc(highlight)}</span>${esc(text.slice(i + highlight.length))}`;
  const h = el("head", html + (THEME === "terminal" ? '<span class="cursor">█</span>' : ""));
  // No heading: nothing to show (an overlay would otherwise draw its empty backing).
  if (!text) h.style.display = "none";
  // Each word in its own mask, for revealHeading.
  const walker = document.createTreeWalker ? document.createTreeWalker(h, 4) : null;
  const texts = [];
  while (walker && walker.nextNode()) if (!walker.currentNode.parentElement.closest(".cursor")) texts.push(walker.currentNode);
  texts.forEach(n => {
    const parts = n.textContent.split(/(\s+)/);
    const frag = document.createDocumentFragment();
    parts.forEach(w => {
      if (!w) return;
      if (/^\s+$/.test(w)) { frag.appendChild(document.createTextNode(w)); return; }
      const outer = document.createElement("span"); outer.className = "rw";
      const inner = document.createElement("span"); inner.textContent = w;
      outer.appendChild(inner); frag.appendChild(outer);
    });
    n.replaceWith(frag);
  });
  return { node: h, hl: h.querySelector(".hl") };
}
function setHL(hl, p) {
  if (!hl) return;
  if (HOOKS.highlight && HOOKS.highlight(hl, p)) return;
  // Terminal: inverse video that switches on, instead of a highlighter swipe.
  if (THEME === "terminal") { hl.parentElement.classList.toggle("on", p > 0); return; }
  hl.style.transform = `skewX(-8deg) scaleX(${easeOut(p)})`;
}
// The tally of costs: a big number and a highlighted label per row.
function tally(labels, starts, x, y, gap) {
  return labels.map((label, i) => {
    const n = el("row", `<span class="num"></span><span class="wrapt"><span class="hl"></span><span class="label">${esc(label)}</span></span>`);
    return { node: n, num: n.querySelector(".num"), hl: n.querySelector(".hl"), start: starts[i], x, y: y + i * gap };
  });
}
function showTally(rows, t, text, numSize) {
  rows.forEach(r => {
    const s = popScale(t, r.start, .4);
    place(r.node, r.x, r.y - 52, s > 0 ? 1 : 0, 0, clamp(s * 1.5));
    r.node.style.transform += ` translateX(${(1 - clamp(s)) * -40}px)`;
    r.num.textContent = text;
    if (numSize) r.num.style.fontSize = numSize + "px";
    setHL(r.hl, (t - r.start - .2) / .4);
  });
}
function camera(t, push, shake, seed = 1) {
  // Terminal: a camcorder on a tripod, drifting and pushing in slowly, never tilting or shaking.
  // Now and then the picture slips sideways for a frame, like a tape losing sync.
  if (THEME === "terminal") {
    const r = rand(seed * 100 + Math.floor(t * 12));
    const s = push * (1 + .012 * Math.sin(t * 1.1));
    const slip = r() < .06 ? (r() - .5) * 28 : 0;
    cam.style.transform = `translate(${14 * Math.sin(t * .7) + slip}px, ${9 * Math.sin(t * .53 + 1)}px) scale(${s})`;
    return;
  }
  // A handheld drift, continuous rather than a jitter re-rolled 12 times a second (huashu-motion's
  // CAM.drift): the same reach, without the buzz on card edges.
  const s = push * (1 + .005 * Math.sin(t * 1.3));
  const a = shake / 2, sx = a * (Math.sin(t * 2.9 + seed) + .4 * Math.sin(t * 7.3 + seed * 2)) / 1.4, sy = a * .8 * Math.sin(t * 3.7 + seed * 3);
  const rot = shake * .025 * Math.sin(t * 2.1 + seed * 5);
  cam.style.transform = `translate(${sx}px, ${sy}px) rotate(${rot}deg) scale(${s})`;
}
function grain(t) { document.getElementById("turb").setAttribute("seed", 1 + Math.floor(t * 3) % 5); }
// The terminal theme's life, every frame: the phosphor shimmers, the scanlines roll down, the grain
// changes, and a packet runs along each line once it's drawn.
function terminalTick(t) {
  const r = rand(Math.floor(t * 12) + 7);
  // The shimmer flickers the scanline layer, not a filter on the whole stage, which renders ten times slower.
  const scan = document.getElementById("vignette");
  if (scan) {
    scan.style.opacity = (.6 + .4 * r()).toFixed(3);
    scan.style.backgroundPosition = `0 ${((t * 12) % 4).toFixed(2)}px, 0 0`;
  }
  document.getElementById("turb")?.setAttribute("seed", 1 + Math.floor(t * 3) % 5);
  lines.querySelectorAll("path").forEach((p, i) => {
    if (typeof p.getTotalLength !== "function") return;
    const done = p.style.opacity !== "0" && parseFloat(p.style.strokeDashoffset) <= 0.001;
    // Two packets per line, each a bright square in a faint glow.
    if (!p.packets) {
      p.packets = [0, .5].map(() => ["glow", "core"].map(kind => {
        const q = document.createElementNS(NS, "rect");
        const size = kind === "glow" ? 34 : 16;
        q.setAttribute("width", size); q.setAttribute("height", size); q.setAttribute("fill", "var(--accent)");
        q.setAttribute("opacity", kind === "glow" ? .22 : 1);
        lines.appendChild(q);
        return { q, size };
      }));
    }
    const len = done ? p.getTotalLength() : 0;
    p.packets.forEach((pair, k) => {
      const at = done ? p.getPointAtLength(((t * .7 + i * .37 + k * .5) % 1) * len) : null;
      pair.forEach(({ q, size }) => {
        q.style.visibility = done ? "visible" : "hidden";
        if (at) { q.setAttribute("x", at.x - size / 2); q.setAttribute("y", at.y - size / 2); }
      });
    });
  });
}
// A cue's time (seconds from the animation's start), or a fallback when the plan leaves it out.
function cue(cues, name, fallback) { return typeof cues[name] === "number" ? cues[name] : fallback; }

// The stage, in design px. A 16:9 clip gets the classic 1920×1080 board. Another shape (the square
// screen card of a vertical video, a 4:5 feed) gets a board of its own shape when the template lays
// itself out from STAGE (`TEMPLATES.name.reflows = true`); a short side of 1350 keeps the nodes, sized
// for the wide board, from crowding. Templates that don't reflow keep the 1920×1080 board, fitted.
let STAGE = { w: 1920, h: 1080, reflow: false };
function stageSize(width, height, reflows) {
  const ratio = width / height;
  if (!reflows || Math.abs(ratio - 16 / 9) < 0.01) return { w: 1920, h: 1080, reflow: false };
  return ratio >= 1 ? { w: Math.round(1350 * ratio), h: 1350, reflow: true } : { w: 1350, h: Math.round(1350 / ratio), reflow: true };
}
// The stage scaled evenly to the clip and centered on paper (a fitted 1920×1080 board letterboxes).
function stageTransform(width, height, stage = { w: 1920, h: 1080 }) {
  const k = Math.min(width / stage.w, height / stage.h);
  return `translate(${(width - stage.w * k) / 2}px, ${(height - stage.h * k) / 2}px) scale(${k})`;
}

// A sticker's height in pixels, for the renderer to size the clip to it.
window.stickerHeight = () => { const s = document.getElementById("sticker"); return s ? Math.ceil(s.getBoundingClientRect().height) : 0; };

// CSS animations and element.animate() in a template run on the page's clock: pin them to t.
function pinAnimations(t) {
  if (document.getAnimations) for (const a of document.getAnimations()) { a.pause(); a.currentTime = t * 1000; }
}

// --- entry points --------------------------------------------------------------
// config: { template, data, cues, duration, width, height, fonts: [{family, url}], titleFont, bodyFont,
//           accent, paper, ink, theme, themeCSS, marks, safeTop, logos, overlay (true: a transparent page over the video), lottie }
window.init = async function (config) {
  cam = document.getElementById("cam");
  lines = document.getElementById("lines");
  LOGOS = config.logos || {};
  LOTTIE = config.lottie || null;
  const root = document.documentElement.style;
  THEME = config.theme || "";
  if (THEME) document.documentElement.classList.add(`theme-${THEME}`);
  HOOKS = THEMES[THEME] || {};
  SCRIBBLES = config.marks || {};
  if (config.themeCSS) {
    const style = document.createElement("style");
    style.textContent = config.themeCSS;
    document.head.appendChild(style);
  }
  OVERLAY = config.overlay === true;
  applyTune(config.tune);
  // A sticker (config.sticker): the template builds #sticker, a card the page's width shown in a
  // sticker border over the video; the stage isn't shown.
  // ("sticker-page": the storyboard's .sticker class is a node's.)
  if (config.sticker) document.documentElement.classList.add("sticker-page");
  if (OVERLAY) document.documentElement.classList.add("overlay");
  if (config.accent) root.setProperty("--accent", config.accent);
  if (config.paper) root.setProperty("--paper", config.paper);
  if (config.ink) root.setProperty("--ink", config.ink);
  for (const f of config.fonts || []) {
    try { document.fonts.add(await new FontFace(f.family, `url("${f.url}")`).load()); } catch (e) { /* the system font stands in */ }
  }
  if (config.titleFont) root.setProperty("--title", `"${config.titleFont}", Georgia, serif`);
  if (config.bodyFont) root.setProperty("--body", `"${config.bodyFont}", "Helvetica Neue", sans-serif`);
  const make = TEMPLATES[config.template];
  if (!make) throw new Error(`no template named "${config.template}" (have: ${Object.keys(TEMPLATES).join(", ")})`);
  // A vertical video's app UI covers the clip's top `safeTop` pixels: lay the stage out below them.
  const top = config.safeTop || 0;
  STAGE = stageSize(config.width, config.height - top, make.reflows === true);
  const stage = document.getElementById("stage");
  stage.style.width = `${STAGE.w}px`;
  stage.style.height = `${STAGE.h}px`;
  stage.style.transform = `translate(0px, ${top}px) ` + stageTransform(config.width, config.height - top, STAGE);
  if (HOOKS.setup) HOOKS.setup({ stage, k: Math.min(config.width / STAGE.w, (config.height - top) / STAGE.h), config });
  if (THEME !== "terminal") setupPackets();
  const seekTemplate = make(config.data || {}, config.cues || {}, config.duration);
  window.seek = t => {
    pinAnimations(t);
    seekTemplate(t);
    if (HOOKS.beforePackets) HOOKS.beforePackets(t);
    if (packetLayer) drawPackets(t);
    for (const c of document.querySelectorAll(".cursor")) c.style.visibility = Math.floor(t * 2) % 2 ? "hidden" : "visible";
    if (THEME === "terminal") terminalTick(t);
    if (HOOKS.tick) HOOKS.tick(t);
  };
  await Promise.all([...document.images].map(i => i.decode().catch(() => {})));
  window.seek(0);
  return true;
};
