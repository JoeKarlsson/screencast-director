// Shared motion-graphics kit for the animation templates: the Vox-style look (paper, grain, a camera
// that always drifts, stickers that pop in with overshoot, hand-drawn lines that draw on, highlighter
// swipes) and the init/seek entry points the renderer calls.
"use strict";
const NS = "http://www.w3.org/2000/svg";
const TEMPLATES = {};
let cam, lines, LOGOS = {};

// --- motion -----------------------------------------------------------------
const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
const easeOut = x => 1 - Math.pow(1 - clamp(x), 3);
const easeInOut = x => { x = clamp(x); return x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
// A sticker slapped down: grows past full size and settles.
function popScale(t, start, dur = .42) {
  if (t < start) return 0;
  const u = (t - start) / dur;
  if (u >= 1) return 1;
  const c = 2.6;
  return 1 + (c + 1) * Math.pow(u - 1, 3) + c * Math.pow(u - 1, 2);
}
// A little blur on the way in, standing in for motion blur.
function popBlur(t, start) { const u = (t - start) / .25; return u > 0 && u < 1 ? (1 - u) * 6 : 0; }
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
  p.setAttribute("fill", "none"); p.setAttribute("stroke", color); p.setAttribute("stroke-width", width);
  p.setAttribute("stroke-linecap", "round"); p.setAttribute("stroke-linejoin", "round"); p.setAttribute("pathLength", "1");
  lines.appendChild(p); return p;
}
function bez(p0, p1, p2, p3, u) { const v = 1 - u; return [0, 1].map(i => v*v*v*p0[i] + 3*v*v*u*p1[i] + 3*v*u*u*p2[i] + u*u*u*p3[i]); }
// A hand-drawn curve from a to b, "boiling" six times a second; `tangle` throws the middle around.
function handCurve(a, b, t, seed, bend = 0, tangle = 0) {
  const r = rand(seed * 31 + Math.floor(t * 6));
  const j = () => (r() - .5) * 3.2;
  const dx = b[0] - a[0], dy = b[1] - a[1], L = Math.hypot(dx, dy) || 1, nx = -dy / L, ny = dx / L;
  const r2 = rand(seed * 7 + 3), k = tangle * 520;
  const c1 = [a[0] + dx * .33 + nx * bend + (r2() - .5) * k + j(), a[1] + dy * .33 + ny * bend + (r2() - .5) * k + j()];
  const c2 = [a[0] + dx * .66 + nx * bend + (r2() - .5) * k + j(), a[1] + dy * .66 + ny * bend + (r2() - .5) * k + j()];
  return { d: `M${a[0] + j()},${a[1] + j()} C${c1} ${c2} ${b[0] + j()},${b[1] + j()}`, at: u => bez(a, c1, c2, b, u) };
}
function place(node, x, y, s = 1, rot = 0, opacity = 1, blur = 0) {
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
  const h = el("head", html);
  return { node: h, hl: h.querySelector(".hl") };
}
function setHL(hl, p) { if (hl) hl.style.transform = `skewX(-8deg) scaleX(${easeOut(p)})`; }
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
  const r = rand(seed * 100 + Math.floor(t * 12));
  const s = push * (1 + .005 * Math.sin(t * 1.3));
  const sx = (r() - .5) * shake, sy = (r() - .5) * shake, rot = (r() - .5) * shake * .05;
  cam.style.transform = `translate(${sx}px, ${sy}px) rotate(${rot}deg) scale(${s})`;
}
function grain(t) { document.getElementById("turb").setAttribute("seed", 1 + Math.floor(t * 3) % 5); }
// A cue's time (seconds from the animation's start), or a fallback when the plan leaves it out.
function cue(cues, name, fallback) { return typeof cues[name] === "number" ? cues[name] : fallback; }

// --- entry points --------------------------------------------------------------
// config: { template, data, cues, duration, width, height, fonts: [{family, url}], titleFont, bodyFont,
//           accent, paper, ink, logos }
window.init = async function (config) {
  cam = document.getElementById("cam");
  lines = document.getElementById("lines");
  LOGOS = config.logos || {};
  const root = document.documentElement.style;
  if (config.accent) root.setProperty("--accent", config.accent);
  if (config.paper) root.setProperty("--paper", config.paper);
  if (config.ink) root.setProperty("--ink", config.ink);
  for (const f of config.fonts || []) {
    try { document.fonts.add(await new FontFace(f.family, `url("${f.url}")`).load()); } catch (e) { /* the system font stands in */ }
  }
  if (config.titleFont) root.setProperty("--title", `"${config.titleFont}", Georgia, serif`);
  if (config.bodyFont) root.setProperty("--body", `"${config.bodyFont}", "Helvetica Neue", sans-serif`);
  const stage = document.getElementById("stage");
  stage.style.transform = `scale(${config.width / 1920}, ${config.height / 1080})`;
  const make = TEMPLATES[config.template];
  if (!make) throw new Error(`no template named "${config.template}" (have: ${Object.keys(TEMPLATES).join(", ")})`);
  window.seek = make(config.data || {}, config.cues || {}, config.duration);
  await Promise.all([...document.images].map(i => i.decode().catch(() => {})));
  window.seek(0);
  return true;
};
