// Shared motion-graphics kit for the animation templates: the Vox-style look (paper, grain, a camera
// that always drifts, stickers that pop in with overshoot, hand-drawn lines that draw on, highlighter
// swipes) and the init/seek entry points the renderer calls.
"use strict";
const NS = "http://www.w3.org/2000/svg";
const TEMPLATES = {};
let cam, lines, LOGOS = {};
// The look (config.theme): "" is the paper collage; "terminal" is a 90s screen with its own motion;
// "zine" is joekarlsson.com: black, hot pink, squiggly crayon lines and the site's scribbles drifting behind.
let THEME = "";

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
const easeInOut = x => { x = clamp(x); return x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
// A sticker slapped down: springs past full size (about 9%) and settles.
function popScale(t, start, dur = .42) {
  if (t < start) return 0;
  // Terminal: no bounce; it flickers on like a screen element, then holds.
  if (THEME === "terminal") return t - start < .2 ? Math.floor((t - start) * 24) % 2 === 0 ? 1 : 0 : 1;
  return spring((t - start) / dur, .6);
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
  return file ? `<img src="${file}">` : `<div class="word">${esc(name)}</div>`;
}
function path(width, color) {
  const p = document.createElementNS(NS, "path");
  const term = THEME === "terminal";
  p.setAttribute("fill", "none"); p.setAttribute("stroke", color);
  p.setAttribute("stroke-width", term ? Math.min(width, 3) : THEME === "zine" ? width * 1.8 : width);
  // Zine: drawn in crayon, the grainy, broken-edged stroke of the site's scribbles.
  if (THEME === "zine") p.setAttribute("filter", "url(#crayon)");
  p.setAttribute("stroke-linecap", term ? "square" : "round"); p.setAttribute("stroke-linejoin", term ? "miter" : "round");
  p.setAttribute("pathLength", "1");
  lines.appendChild(p); return p;
}
function bez(p0, p1, p2, p3, u) { const v = 1 - u; return [0, 1].map(i => v*v*v*p0[i] + 3*v*v*u*p1[i] + 3*v*u*u*p2[i] + u*u*u*p3[i]); }
// A hand-drawn curve from a to b, "boiling" six times a second; `tangle` throws the middle around.
function handCurve(a, b, t, seed, bend = 0, tangle = 0) {
  if (THEME === "terminal") return elbow(a, b, t, seed);
  if (THEME === "zine") return squiggle(a, b, t, seed);
  const r = rand(seed * 31 + Math.floor(t * 6));
  const j = () => (r() - .5) * 3.2;
  const dx = b[0] - a[0], dy = b[1] - a[1], L = Math.hypot(dx, dy) || 1, nx = -dy / L, ny = dx / L;
  const r2 = rand(seed * 7 + 3), k = tangle * 520;
  const c1 = [a[0] + dx * .33 + nx * bend + (r2() - .5) * k + j(), a[1] + dy * .33 + ny * bend + (r2() - .5) * k + j()];
  const c2 = [a[0] + dx * .66 + nx * bend + (r2() - .5) * k + j(), a[1] + dy * .66 + ny * bend + (r2() - .5) * k + j()];
  return { d: `M${a[0] + j()},${a[1] + j()} C${c1} ${c2} ${b[0] + j()},${b[1] + j()}`, at: u => bez(a, c1, c2, b, u) };
}
// A squiggly crayon line from a to b for the zine theme: a hand-wobbled wave (about 9 px high, a wave
// every 55 px, flat at the ends) along a gentle bow, boiling six times a second like the site's marks.
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
  if (packetLayer && curve.at && progress >= 1 && opacity > .05) packetLines.push({ p, curve, opacity });
  // Zine: p5.brush draws it instead (the path stays, hidden, for layout).
  if (brushLines && curve.at) {
    p.style.visibility = "hidden";
    if (progress > 0 && opacity > 0) brushLines.queue.push({ p, curve, progress: clamp(progress), opacity });
  }
}

// --- zine lines in p5.brush ------------------------------------------------------
// The zine theme draws its lines with p5.brush's colored pencil (vendor/brush.js) for the grainy,
// broken edge of real crayon: drawPath queues each line and seek draws them all on a canvas just
// above the SVG lines, boiling six times a second like the SVG crayon did.
const ZINE_BRUSH = { name: "cpencil", scale: 1.5 };
let brushLines = null;
function setupBrushLines(k) {
  if (typeof brush === "undefined") throw new Error("the zine theme's lines need p5.brush (vendor/brush.js)");
  // Drawn at twice the clip's resolution: p5.brush's stroke masks have no antialiasing, so at 1x its
  // grain shows as pixel blocks.
  const W = Math.round(STAGE.w * k), H = Math.round(STAGE.h * k), density = 2;
  const gl = document.createElement("canvas");
  gl.width = W * density; gl.height = H * density;
  const glc = gl.getContext("webgl2", { alpha: true, premultipliedAlpha: true, preserveDrawingBuffer: true, antialias: true });
  if (!glc) throw new Error("the zine theme's lines need WebGL2");
  brush.load(gl);
  brush.scaleBrushes(ZINE_BRUSH.scale);
  // Shown through a 2D canvas, which composites the transparent strokes over the stage.
  const shown = document.createElement("canvas");
  shown.width = W; shown.height = H;
  shown.style.cssText = `position: absolute; left: 0; top: 0; width: ${STAGE.w}px; height: ${STAGE.h}px; pointer-events: none`;
  lines.after(shown);
  brushLines = { gl, glc, ctx: shown.getContext("2d"), k: k * density, W, H, queue: [], seeds: new Map() };
}
// A path's stroke color with its opacity, resolving var(--ink) and friends.
function brushColor(p, opacity) {
  const raw = p.getAttribute("stroke") || "var(--ink)";
  const name = raw.match(/^var\((--[\w-]+)\)$/);
  const css = name ? getComputedStyle(document.documentElement).getPropertyValue(name[1]).trim() : raw;
  const probe = document.createElement("canvas").getContext("2d");
  probe.fillStyle = css;
  const hex = probe.fillStyle; // #rrggbb, or rgba() when it already has alpha
  const [r, g, b] = hex.startsWith("#") ? [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16)) : hex.match(/[\d.]+/g).slice(0, 3).map(Number);
  return [r, g, b, clamp(opacity)];
}
function drawBrushLines(t) {
  const L = brushLines;
  brush.clear();
  // brush.clear() leaves transparent white (1,1,1,0), which a premultiplied canvas shows as white.
  L.glc.bindFramebuffer(L.glc.FRAMEBUFFER, null);
  L.glc.clearColor(0, 0, 0, 0);
  L.glc.clear(L.glc.COLOR_BUFFER_BIT);
  brush.push();
  // Points go in canvas pixels rather than through brush.scale, which would blow up the grain too.
  brush.translate(-L.gl.width / 2, -L.gl.height / 2);
  for (const line of L.queue) {
    // Each path keeps its own texture, changing only on the boil.
    if (!L.seeds.has(line.p)) L.seeds.set(line.p, L.seeds.size + 1);
    const seed = L.seeds.get(line.p);
    brush.seed(seed * 31 + Math.floor(t * 6));
    brush.noiseSeed(seed);
    const n = Math.max(2, Math.ceil(80 * line.progress));
    const pts = Array.from({ length: n + 1 }, (_, j) => line.curve.at(j / n * line.progress).map(v => v * L.k));
    brush.set(ZINE_BRUSH.name, brushColor(line.p, line.opacity), +line.p.getAttribute("stroke-width") * L.k / ZINE_BRUSH.scale / 1.1);
    brush.spline(pts, 0);
  }
  brush.pop();
  brush.render();
  L.ctx.clearRect(0, 0, L.W, L.H);
  L.ctx.imageSmoothingQuality = "high";
  L.ctx.drawImage(L.gl, 0, 0, L.W, L.H);
  L.queue = [];
}
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
    p.style.strokeDashoffset = THEME === "terminal" ? (t >= start ? 0 : 1) : 1 - easeOut((t - start - i * .07) / .3);
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
}
// The site's burst scribble, in the accent, flaring behind a node as it lands and erasing.
function burstMark(behind) {
  if (THEME === "terminal" || typeof SCRIBBLES === "undefined") return null;
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
  b.strokes.forEach((p, i) => { p.style.strokeDashoffset = u < 0 ? 1 : u < .55 ? 1 - easeOut((u - i * .012) / .2) : -easeOut((u - .55) / .25); });
}
// Heading words rise out of a mask line, 60 ms apart (heading() wraps each word).
function revealHeading(h, t, start) {
  h.node.querySelectorAll(".rw > span").forEach((w, i) => {
    const p = THEME === "terminal" ? (t >= start + i * .06 ? 1 : 0) : spring((t - start - i * .06) / .5, .75);
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
  // Above the lines (and the zine's brush canvas), under every node made after it.
  (brushLines ? lines.nextSibling : lines).after(packetLayer);
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

function heading(text, highlight) {
  const i = highlight ? text.indexOf(highlight) : -1;
  const html = i < 0 ? `<span class="wrapt"><span class="hl"></span>${esc(text)}</span>`
    : `${esc(text.slice(0, i))}<span class="wrapt"><span class="hl"></span>${esc(highlight)}</span>${esc(text.slice(i + highlight.length))}`;
  const h = el("head", html + (THEME === "terminal" ? '<span class="cursor">█</span>' : ""));
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
  // Zine: a heading's highlighted words turn pink (animation.html); nothing is drawn over them.
  if (THEME === "zine") { hl.parentElement.classList.toggle("on", p > 0); return; }
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
  const r = rand(seed * 100 + Math.floor(t * 12));
  const s = push * (1 + .005 * Math.sin(t * 1.3));
  const sx = (r() - .5) * shake, sy = (r() - .5) * shake, rot = (r() - .5) * shake * .05;
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
// The zine theme's background: the site's scribbles (scribbles.js), dim, drifting behind the board. Each
// draws in, holds and erases on its own slow loop (a mark of several strokes draws them one after
// another, the site's redraw timing), bobs and turns a little, and boils between three wobble frames.
const ZINE_MARKS = [
  // name, x and y (fractions of the stage, below the heading), width (fraction of the short side), pink?
  ["coil", .6, .24, .5, false], ["burstDense", .83, .66, .24, true], ["asterisk", .05, .8, .11, true],
  ["tally", .02, .36, .21, false], ["oval", .5, .76, .38, false], ["cross", .86, .3, .17, true], ["hatch", .3, .9, .22, false],
];
let zineMarks = [];
function buildZineMarks() {
  const layer = document.getElementById("marks");
  if (!layer || typeof SCRIBBLES === "undefined") return [];
  const short = Math.min(STAGE.w, STAGE.h);
  return ZINE_MARKS.map(([name, x, y, w, pink], k) => {
    const m = SCRIBBLES[name], vb = m.viewBox.split(" ").map(Number);
    const svg = document.createElementNS(NS, "svg");
    svg.setAttribute("viewBox", vb.join(" ")); svg.setAttribute("class", "mark");
    const width = w * short;
    svg.style.left = `${x * STAGE.w}px`; svg.style.top = `${y * STAGE.h}px`;
    svg.style.width = `${width}px`; svg.style.height = `${width * vb[3] / vb[2]}px`;
    const g = document.createElementNS(NS, "g");
    g.setAttribute("stroke", pink ? "var(--accent)" : "#ECE6DA");
    // About 9 px on the stage, whatever the mark's viewBox.
    g.setAttribute("stroke-width", 9 * vb[2] / width);
    svg.appendChild(g);
    const strokes = m.path.split(/(?=M)/).map(d => d.trim()).filter(Boolean).map(d => {
      const p = document.createElementNS(NS, "path");
      p.setAttribute("d", d); p.setAttribute("pathLength", "1"); p.style.strokeDasharray = 1;
      g.appendChild(p); return p;
    });
    layer.appendChild(svg);
    return { svg, strokes, dur: 7 + k * 1.3, delay: k * .6 - 3, k };
  });
}
// How much of a stroke is hidden at loop position u (0..1): 1 before it draws, 0 while it holds, and
// negative as it erases from its start. One stroke draws over the first 35% and erases after 85%; a
// mark of several strokes draws each in 4.5% of the loop, one after another, and erases them in turn.
function redrawOffset(u, i, count) {
  if (count === 1) return u < .35 ? 1 - easeOut(u / .35) : u < .85 ? 0 : -easeInOut((u - .85) / .15);
  const s = i * .045;
  return u < s ? 1 : u < s + .045 ? 1 - easeOut((u - s) / .045) : u < .8 + s * .3 ? 0 : -clamp((u - .8 - s * .3) / .04);
}
function zineTick(t) {
  zineMarks.forEach(({ svg, strokes, dur, delay, k }) => {
    const u = (((t - delay) / dur) % 1 + 1) % 1;
    strokes.forEach((p, i) => { p.style.strokeDashoffset = redrawOffset(u, i, strokes.length); });
    const dx = 14 * Math.sin(t * .5 + k * 1.7), dy = 14 * Math.cos(t * .37 + k), rot = (k % 2 ? 2 : -2) * t;
    svg.style.transform = `translate(${dx}px, ${dy}px) rotate(${rot}deg)`;
    svg.style.filter = `url(#boil-${1 + Math.floor(t * 6 + k) % 3})`;
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

// --- entry points --------------------------------------------------------------
// config: { template, data, cues, duration, width, height, fonts: [{family, url}], titleFont, bodyFont,
//           accent, paper, ink, theme, safeTop, logos }
window.init = async function (config) {
  cam = document.getElementById("cam");
  lines = document.getElementById("lines");
  LOGOS = config.logos || {};
  const root = document.documentElement.style;
  THEME = config.theme || "";
  if (THEME) document.documentElement.classList.add(`theme-${THEME}`);
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
  if (THEME === "zine") {
    zineMarks = buildZineMarks();
    setupBrushLines(Math.min(config.width / STAGE.w, (config.height - top) / STAGE.h));
  }
  if (THEME !== "terminal") setupPackets();
  const seekTemplate = make(config.data || {}, config.cues || {}, config.duration);
  window.seek = t => {
    seekTemplate(t);
    if (brushLines) drawBrushLines(t);
    if (packetLayer) drawPackets(t);
    for (const c of document.querySelectorAll(".cursor")) c.style.visibility = Math.floor(t * 2) % 2 ? "hidden" : "visible";
    if (THEME === "terminal") terminalTick(t);
    if (THEME === "zine") zineTick(t);
  };
  await Promise.all([...document.images].map(i => i.decode().catch(() => {})));
  window.seek(0);
  return true;
};
