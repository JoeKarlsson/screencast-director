// "storyboard": a diagram built step by step, each step cued to a word. No fixed layout: the steps
// say what appears, what connects, what gets counted, dimmed or circled, and when to clear to a new board.
//
// data: title, highlight, steps: [{ cue, do, ... }] where do is one of
//   show      { id, kind: dot|sticker|card|label, logo?, label?, x?, y? }  (x, y in % of the frame;
//             nodes without them are laid out around the board's first node)
//   connect   { from, to, label?, dashed? }
//   note      { text, x?, y? }
//   count     { label, value }       a big number and label in the tally on the left
//   highlight { target }             a yellow ring around a node
//   dim       { target }             fade a node (and its lines) back
//   hide      { target }
//   tangle    {}                     the board's lines knot up and the camera shakes
//   circle    {}                     a marker circle around everything on the board
//   clear     {}                     everything leaves; later steps start a new board
// cues: one per step, named by the step's `cue` (seconds from the start)
"use strict";
TEMPLATES.storyboard = function (data, cues, duration) {
  const steps = (data.steps || []).map((s, k) => ({ ...s, t: cue(cues, s.cue, 0.6 + k * 1.2) }));

  // Boards: a clear ends one and starts the next.
  const boards = [{ start: 0, end: Infinity }];
  steps.forEach(s => {
    s.board = boards.length - 1;
    if (s.do === "clear") { boards[boards.length - 1].end = s.t; boards.push({ start: s.t, end: Infinity }); }
  });

  // Where nodes go: given positions in %, else the first is the board's center and the rest ring it.
  const nodes = {};
  boards.forEach((b, bi) => {
    const shows = steps.filter(s => s.do === "show" && s.board === bi);
    const free = shows.filter(s => s.x == null || s.y == null);
    const center = [1180, 540];
    free.forEach((s, k) => {
      if (k === 0) { s.px = center; return; }
      const n = free.length - 1, a = -Math.PI / 2 + 2 * Math.PI * (k - 1) / Math.max(n, 1);
      s.px = [center[0] + 480 * Math.cos(a), center[1] + 300 * Math.sin(a)];
    });
    shows.forEach(s => { if (!s.px) s.px = [s.x / 100 * 1920, s.y / 100 * 1080]; });
  });

  const lines = [];
  const rows = [];
  let seed = 1;
  steps.forEach(s => {
    if (s.do === "show") {
      const kind = s.kind || "sticker";
      const logo = s.logo && LOGOS[s.logo] ? `<img src="${LOGOS[s.logo]}">` : "";
      let node, label = null;
      if (kind === "dot") {
        node = el("dot", logo || `<div class="word">${esc(s.label || "")}</div>`);
        if (logo && s.label) label = el("hand chip", `<span class="wrapt"><span class="hl"></span>${esc(s.label)}</span>`);
      } else if (kind === "card") {
        node = el("hub", `${logo}<div>${esc(s.label || "")}</div>`);
      } else if (kind === "label") {
        node = el("hand chip", `<span class="wrapt"><span class="hl"></span>${esc(s.label || "")}</span>`);
      } else {
        node = el("sticker", logo || `<div class="word">${esc(s.label || s.logo || "")}</div>`);
        if (logo && s.label) label = el("label", esc(s.label));
      }
      const ring = el("ringmark", "");
      nodes[s.id] = { s, node, label, ring, kind, t: s.t, board: s.board, dimT: Infinity, hideT: Infinity, hlT: Infinity, rot: (rand(seed++)() - .5) * 10 };
    }
  });
  steps.forEach(s => {
    const n = nodes[s.target];
    if (s.do === "dim" && n) n.dimT = Math.min(n.dimT, s.t);
    if (s.do === "hide" && n) n.hideT = Math.min(n.hideT, s.t);
    if (s.do === "highlight" && n) n.hlT = Math.min(n.hlT, s.t);
    if (s.do === "connect" && nodes[s.from] && nodes[s.to]) {
      lines.push({ s, path: path(s.dashed ? 4 : 5, "var(--ink)"), label: s.label ? el("tag", esc(s.label)) : null, seed: seed++ });
    }
    if (s.do === "note") s.node = el("tag", esc(s.text || ""));
    if (s.do === "count") rows.push(s);
  });
  const tallyRows = rows.map((s, k) => {
    const n = el("row", `<span class="num"></span><span class="wrapt"><span class="hl"></span><span class="label">${esc(s.label || "")}</span></span>`);
    const sameBoard = rows.filter(r => r.board === s.board);
    return { s, node: n, num: n.querySelector(".num"), hl: n.querySelector(".hl"), y: 380 + sameBoard.indexOf(s) * 130 };
  });
  const tangles = steps.filter(s => s.do === "tangle");
  const circles = steps.filter(s => s.do === "circle").map(s => ({ s, path: path(14, "var(--accent)") }));
  const clears = steps.filter(s => s.do === "clear");
  const head = heading(data.title || "", data.highlight);

  // How far a board has left (1 = gone), for its exit when the next board starts.
  const gone = (board, t) => easeOut((t - boards[board].end) / .35);
  const tangleOf = (board, t) => Math.max(0, ...tangles.filter(s => s.board === board).map(s => easeInOut((t - s.t) / 1.6)));
  const at = n => n.s.px;

  return t => {
    grain(t);
    const lastClear = clears.filter(s => s.t <= t).pop();
    const pull = lastClear ? easeOut((t - lastClear.t) / .7) : 1;
    const board = boards.findIndex(b => t >= b.start && t < b.end);
    const tangle = tangleOf(board, t);
    camera(t, 1.03 - .03 * pull + .025 * clamp(t / Math.max(duration, 1)) + .03 * tangle, 2.2 + 7 * tangle);
    document.getElementById("stage").style.filter = lastClear && t - lastClear.t < .7 ? `blur(${(1 - pull) * 8}px)` : "";
    place(head.node, 110, 92, 1, 0, easeOut((t - .1) / .4));
    setHL(head.hl, (t - .6) / .5);

    lines.forEach(l => {
      const a = nodes[l.s.from], b = nodes[l.s.to];
      const out = gone(l.s.board, t), dim = Math.max(easeOut((t - a.dimT) / .5), easeOut((t - b.dimT) / .5));
      const hidden = t >= Math.min(a.hideT, b.hideT);
      const curve = handCurve(at(a), at(b), t, l.seed, l.seed % 2 ? 30 : -30, tangleOf(l.s.board, t) * (l.seed % 3 === 0 ? 1.1 : .8));
      drawPath(l.path, curve, hidden ? 0 : (t - l.s.t) / .45, (1 - .78 * dim) * (1 - out));
      if (l.s.dashed) {
        // Dashes and the draw-on share stroke-dasharray, so a dashed line fades in instead.
        l.path.style.strokeDasharray = ".012 .014";
        l.path.style.strokeDashoffset = 0;
        l.path.style.opacity = hidden ? 0 : clamp((t - l.s.t) / .45) * (1 - .78 * dim) * (1 - out);
      }
      if (l.label) { const m = curve.at(.5); place(l.label, m[0] - 60, m[1] - 50, hidden ? 0 : popScale(t, l.s.t + .3) * (1 - out), -3, 1 - .78 * dim); }
    });
    Object.values(nodes).forEach(n => {
      const out = gone(n.board, t);
      const hide = easeOut((t - n.hideT) / .3);
      const s = popScale(t, n.t) * (1 - out) * (1 - hide);
      const dim = easeOut((t - n.dimT) / .5);
      const [x, y] = at(n);
      place(n.node, x, y, s, n.kind === "sticker" ? n.rot * (1 - .3 * s) : 0, 1 - .78 * dim, popBlur(t, n.t));
      if (dim > .01) n.node.style.filter += ` grayscale(${dim})`;
      if (n.label) {
        const below = n.kind === "dot" ? 118 : 86;
        place(n.label, x - (n.kind === "dot" ? 95 : 50), y + below, popScale(t, n.t + .25) * (1 - out) * (1 - hide), -3, 1 - .78 * dim);
        setHL(n.label.querySelector(".hl"), (t - n.t - .5) / .4);
      }
      if (n.kind === "label") setHL(n.node.querySelector(".hl"), (t - n.t - .3) / .4);
      const r = n.kind === "dot" ? 120 : n.kind === "card" ? 190 : 86;
      n.ring.style.width = n.ring.style.height = `${2 * r}px`;
      n.ring.style.margin = `${-r}px 0 0 ${-r}px`;
      place(n.ring, x, y, popScale(t, n.hlT, .5) * (1 - out) * (1 - hide), 0, .9);
    });
    steps.filter(s => s.do === "note").forEach(s => {
      const p = s.x != null && s.y != null ? [s.x / 100 * 1920, s.y / 100 * 1080] : [130, 380 + 140 * steps.filter(o => o.do === "note" && o.board === s.board).indexOf(s)];
      place(s.node, p[0], p[1], popScale(t, s.t) * (1 - gone(s.board, t)), [-4, 3, -2][steps.indexOf(s) % 3]);
    });
    tallyRows.forEach(r => {
      const s = popScale(t, r.s.t, .4) * (1 - gone(r.s.board, t));
      place(r.node, 110, r.y - 52, s > 0 ? 1 : 0, 0, clamp(s * 1.5));
      r.node.style.transform += ` translateX(${(1 - clamp(s)) * -40}px)`;
      const v = Number(r.s.value);
      r.num.textContent = isNaN(v) ? String(r.s.value ?? "") : String(Math.round(v * easeOut((t - r.s.t) / .6)));
      setHL(r.hl, (t - r.s.t - .2) / .4);
    });
    circles.forEach(c => {
      const ps = Object.values(nodes).filter(n => n.board === c.s.board && n.t <= c.s.t).map(at);
      if (!ps.length) return;
      const xs = ps.map(p => p[0]), ys = ps.map(p => p[1]);
      const cx = (Math.min(...xs) + Math.max(...xs)) / 2, cy = (Math.min(...ys) + Math.max(...ys)) / 2;
      const rx = (Math.max(...xs) - Math.min(...xs)) / 2 + 150, ry = (Math.max(...ys) - Math.min(...ys)) / 2 + 130;
      const pts = [];
      for (let k = 0; k <= 48; k++) {
        const a = -1.2 + k / 48 * 2 * Math.PI * 1.06, rr = 1 + .03 * Math.sin(k * 1.7);
        pts.push([cx + rx * rr * Math.cos(a), cy + ry * rr * Math.sin(a)]);
      }
      c.path.setAttribute("d", "M" + pts.map(p => p.join(",")).join(" L"));
      c.path.style.strokeDasharray = 1; c.path.style.strokeDashoffset = 1 - easeOut((t - c.s.t) / .7);
      c.path.style.opacity = t < c.s.t ? 0 : .85 * (1 - gone(c.s.board, t)); c.path.style.mixBlendMode = "multiply";
    });
  };
};
