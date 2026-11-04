// Shared motion-graphics kit for the animation templates: the Vox-style look (paper, grain, a camera
// that always drifts, stickers that pop in with overshoot, hand-drawn lines that draw on, highlighter
// swipes) and the init/seek entry points the renderer calls.
"use strict";
const NS = "http://www.w3.org/2000/svg";
const TEMPLATES = {};
let cam, lines, LOGOS = {};
// The look (config.theme): "" is the paper collage; "terminal" is a 90s screen with its own motion.
let THEME = "";

// --- motion -----------------------------------------------------------------
const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
const easeOut = x => 1 - Math.pow(1 - clamp(x), 3);
const easeInOut = x => { x = clamp(x); return x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
// A sticker slapped down: grows past full size and settles.
function popScale(t, start, dur = .42) {
  if (t < start) return 0;
  // Terminal: no bounce; it flickers on like a screen element, then holds.
  if (THEME === "terminal") return t - start < .2 ? Math.floor((t - start) * 24) % 2 === 0 ? 1 : 0 : 1;
  const u = (t - start) / dur;
  if (u >= 1) return 1;
  const c = 2.6;
  return 1 + (c + 1) * Math.pow(u - 1, 3) + c * Math.pow(u - 1, 2);
}
// A little blur on the way in, standing in for motion blur.
function popBlur(t, start) { if (THEME === "terminal") return 0; const u = (t - start) / .25; return u > 0 && u < 1 ? (1 - u) * 6 : 0; }
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
  p.setAttribute("fill", "none"); p.setAttribute("stroke", color); p.setAttribute("stroke-width", term ? Math.min(width, 3) : width);
  p.setAttribute("stroke-linecap", term ? "square" : "round"); p.setAttribute("stroke-linejoin", term ? "miter" : "round");
  p.setAttribute("pathLength", "1");
  lines.appendChild(p); return p;
}
function bez(p0, p1, p2, p3, u) { const v = 1 - u; return [0, 1].map(i => v*v*v*p0[i] + 3*v*v*u*p1[i] + 3*v*u*u*p2[i] + u*u*u*p3[i]); }
// A hand-drawn curve from a to b, "boiling" six times a second; `tangle` throws the middle around.
function handCurve(a, b, t, seed, bend = 0, tangle = 0) {
  if (THEME === "terminal") return elbow(a, b, t, seed);
  const r = rand(seed * 31 + Math.floor(t * 6));
  const j = () => (r() - .5) * 3.2;
  const dx = b[0] - a[0], dy = b[1] - a[1], L = Math.hypot(dx, dy) || 1, nx = -dy / L, ny = dx / L;
  const r2 = rand(seed * 7 + 3), k = tangle * 520;
  const c1 = [a[0] + dx * .33 + nx * bend + (r2() - .5) * k + j(), a[1] + dy * .33 + ny * bend + (r2() - .5) * k + j()];
  const c2 = [a[0] + dx * .66 + nx * bend + (r2() - .5) * k + j(), a[1] + dy * .66 + ny * bend + (r2() - .5) * k + j()];
  return { d: `M${a[0] + j()},${a[1] + j()} C${c1} ${c2} ${b[0] + j()},${b[1] + j()}`, at: u => bez(a, c1, c2, b, u) };
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
}
// A heading with the `highlight` part swiped in highlighter.
function heading(text, highlight) {
  const i = highlight ? text.indexOf(highlight) : -1;
  const html = i < 0 ? `<span class="wrapt"><span class="hl"></span>${esc(text)}</span>`
    : `${esc(text.slice(0, i))}<span class="wrapt"><span class="hl"></span>${esc(highlight)}</span>${esc(text.slice(i + highlight.length))}`;
  const h = el("head", html + (THEME === "terminal" ? '<span class="cursor">█</span>' : ""));
  return { node: h, hl: h.querySelector(".hl") };
}
function setHL(hl, p) {
  if (!hl) return;
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
  const seekTemplate = make(config.data || {}, config.cues || {}, config.duration);
  window.seek = t => {
    seekTemplate(t);
    for (const c of document.querySelectorAll(".cursor")) c.style.visibility = Math.floor(t * 2) % 2 ? "hidden" : "visible";
    if (THEME === "terminal") terminalTick(t);
  };
  await Promise.all([...document.images].map(i => i.decode().catch(() => {})));
  window.seek(0);
  return true;
};
