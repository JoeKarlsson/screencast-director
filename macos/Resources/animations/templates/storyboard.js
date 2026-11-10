// "storyboard": a diagram built step by step, each step cued to a word. No fixed layout: the steps
// say what appears, what connects, what gets counted, dimmed or circled, and when to clear to a new board.
//
// data: title, highlight, steps: [{ cue, do, ... }] where do is one of
//   show      { id, kind: dot|sticker|card|label, logo?, icon?, label?, x?, y? }  (x, y in % of the frame;
//             nodes without them are laid out around the board's first node; icon is a hand-drawn
//             line icon used when there's no logo: laptop, prompter, camera, mic, phone, server,
//             database, cloud, user, doc, chart, bolt)
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
//
// Every node slams in with a burst behind it, icons draw themselves, the heading rises a word at a
// time, packets run along finished lines, and the camera keeps what's on the board filling the frame:
// close on the first node, pulling back on a spring as each new one appears.
"use strict";
TEMPLATES.storyboard = function (data, cues, duration) {
  const steps = (data.steps || []).map((s, k) => ({ ...s, t: cue(cues, s.cue, 0.6 + k * 1.2) }));

  // Boards: a clear ends one and starts the next.
  const boards = [{ start: 0, end: Infinity }];
  steps.forEach(s => {
    s.board = boards.length - 1;
    if (s.do === "clear") { boards[boards.length - 1].end = s.t; boards.push({ start: s.t, end: Infinity }); }
  });

  // On a board of another shape the heading wraps, and positions in % fill the space under it.
  const head = heading(data.title || "", data.highlight);
  // The heading stays put while the camera frames the board.
  document.getElementById("stage").appendChild(head.node);
  let top = 0, span = STAGE.h;
  if (STAGE.reflow) {
    head.node.style.whiteSpace = "normal";
    head.node.style.width = `${STAGE.w - 220}px`;
    head.node.style.fontSize = "80px";
    top = 92 + (head.node.offsetHeight || 80) + 60;
    span = STAGE.h - top - 70;
  }
  const px = (x, y) => [x / 100 * STAGE.w, top + y / 100 * span];

  // Where nodes go: given positions in %, else the first is the board's center and the rest ring it.
  const nodes = {};
  boards.forEach((b, bi) => {
    const shows = steps.filter(s => s.do === "show" && s.board === bi);
    const free = shows.filter(s => s.x == null || s.y == null);
    const center = STAGE.reflow ? [STAGE.w * .55, top + span / 2] : [1180, 540];
    free.forEach((s, k) => {
      if (k === 0) { s.px = center; return; }
      const n = free.length - 1, a = -Math.PI / 2 + 2 * Math.PI * (k - 1) / Math.max(n, 1);
      s.px = [center[0] + 480 * Math.cos(a), center[1] + 300 * Math.sin(a)];
    });
    shows.forEach(s => { if (!s.px) s.px = px(s.x, s.y); });
  });

  const lines = [];
  const rows = [];
  let seed = 1;
  steps.forEach(s => {
    if (s.do === "show") {
      const kind = s.kind || "sticker";
      const logo = s.logo && LOGOS[s.logo] ? `<img src="${LOGOS[s.logo]}">` : s.icon ? iconHTML(s.icon) : "";
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
      // Labels are text placed by their corner: no burst behind them.
      const burst = kind === "label" ? null : burstMark(node);
      // Its size, so lines stop at its edge; a text label is centered on its spot like the rest.
      const w = node.offsetWidth || (kind === "dot" ? 190 : kind === "card" ? 330 : 120), h = node.offsetHeight || (kind === "card" ? 150 : kind === "dot" ? 190 : 120);
      if (kind === "label") node.style.margin = `${-h / 2}px 0 0 ${-w / 2}px`;
      nodes[s.id] = { s, node, label, ring, burst, kind, w, h, t: s.t, board: s.board, dimT: Infinity, hideT: Infinity, hlT: Infinity, rot: (rand(seed++)() - .5) * 10 };
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

  // How far a board has left (1 = gone), for its exit when the next board starts.
  const gone = (board, t) => easeOut((t - boards[board].end) / .35);
  const tangleOf = (board, t) => Math.max(0, ...tangles.filter(s => s.board === board).map(s => easeInOut((t - s.t) / 1.6)));
  const at = n => n.s.px;

  // Framing: each time something appears, the camera eases (on a spring, summed per change so it stays
  // a pure function of time) to fit everything shown on that board so far, below the heading.
  const headroom = STAGE.reflow ? top : 200;
  const shownPoints = (board, time) => [
    ...Object.values(nodes).filter(n => n.board === board && n.t <= time).map(at),
    ...steps.filter(o => o.board === board && o.t <= time && o.do === "note").flatMap(o => {
      const p = o.x != null && o.y != null ? px(o.x, o.y) : [130, 380];
      return [p, [p[0] + 320, p[1]]];
    }),
    ...rows.filter(r => r.board === board && r.t <= time).flatMap(() => [[110, 380], [620, 380 + 130 * rows.filter(o => o.board === board).length]]),
  ];
  const frames = steps.filter(o => ["show", "note", "count", "clear"].includes(o.do)).map(o => {
    const board = o.do === "clear" ? o.board + 1 : o.board;
    const pts = shownPoints(board, o.t);
    if (!pts.length) return { t: o.t, k: 1, c: [STAGE.w / 2, headroom + (STAGE.h - headroom) / 2] };
    const xs = pts.map(p => p[0]), ys = pts.map(p => p[1]);
    // Room for the nodes themselves and their labels (bigger on a vertical video's square card).
    const big = STAGE.reflow ? 1.7 : 1;
    const bw = Math.max(...xs) - Math.min(...xs) + 560 * big, bh = Math.max(...ys) - Math.min(...ys) + 520 * big;
    const k = clamp(Math.min(STAGE.w / bw, (STAGE.h - headroom) / bh), 1, 1.45);
    return { t: o.t, k, c: [(Math.min(...xs) + Math.max(...xs)) / 2, (Math.min(...ys) + Math.max(...ys)) / 2] };
  });
  function framing(t) {
    if (!frames.length) return null;
    let logK = Math.log(frames[0].k), cx = frames[0].c[0], cy = frames[0].c[1];
    frames.forEach((f, i) => {
      if (!i) return;
      // The move starts before the node lands, so it arrives inside the frame.
      const p = spring((t - f.t + .35) / .9, .9), prev = frames[i - 1];
      // Scale in log space: the same ratio each frame reads as a steady zoom (huashu-motion's zlerp).
      logK += Math.log(f.k / prev.k) * p; cx += (f.c[0] - prev.c[0]) * p; cy += (f.c[1] - prev.c[1]) * p;
    });
    const k = Math.exp(logK);
    // Where the framed center lands: the middle of the space under the heading.
    const target = [STAGE.w / 2, headroom + (STAGE.h - headroom) / 2];
    const dx = target[0] - STAGE.w / 2 - k * (cx - STAGE.w / 2), dy = target[1] - STAGE.h / 2 - k * (cy - STAGE.h / 2);
    return ` translate(${dx}px, ${dy}px) scale(${k})`;
  }

  return t => {
    grain(t);
    const lastClear = clears.filter(s => s.t <= t).pop();
    const pull = lastClear ? easeOut((t - lastClear.t) / .7) : 1;
    const board = boards.findIndex(b => t >= b.start && t < b.end);
    const tangle = tangleOf(board, t);
    camera(t, 1.03 - .03 * pull + .025 * clamp(t / Math.max(duration, 1)) + .03 * tangle, 2.2 + 7 * tangle);
    const frame = framing(t);
    if (frame) cam.style.transform += frame;
    document.getElementById("stage").style.filter = lastClear && t - lastClear.t < .7 ? `blur(${(1 - pull) * 8}px)` : "";
    place(head.node, 110, 92, 1, 0, 1);
    revealHeading(head, t, .05);
    setHL(head.hl, (t - .6) / .5);

    lines.forEach(l => {
      const a = nodes[l.s.from], b = nodes[l.s.to];
      const out = gone(l.s.board, t), dim = Math.max(easeOut((t - a.dimT) / .5), easeOut((t - b.dimT) / .5));
      const hidden = t >= Math.min(a.hideT, b.hideT);
      // From edge to edge, so lines (and their packets) never run under a card or through a label.
      const big = STAGE.reflow ? 1.7 : 1;
      const from = edgePoint(at(b), at(a), a.w * big, a.h * big), to = edgePoint(at(a), at(b), b.w * big, b.h * big);
      const curve = handCurve(from, to, t, l.seed, l.seed % 2 ? 30 : -30, tangleOf(l.s.board, t) * (l.seed % 3 === 0 ? 1.1 : .8));
      drawPath(l.path, curve, hidden ? 0 : (t - l.s.t) / .45, (1 - .78 * dim) * (1 - out));
      if (l.s.dashed) {
        // Dashes and the draw-on share stroke-dasharray, so a dashed line fades in instead.
        l.path.style.strokeDasharray = ".012 .014";
        l.path.style.strokeDashoffset = 0;
        l.path.style.opacity = hidden ? 0 : clamp((t - l.s.t) / .45) * (1 - .78 * dim) * (1 - out);
      }
      if (l.label) { const m = curve.at(.5); place(l.label, m[0] - 60, m[1] - 50, hidden ? 0 : popScale(t, l.s.t + .3) * (1 - out), -3, 1 - .78 * dim); }
    });
    // In a vertical video's square card the stage is about half as wide, so nodes draw bigger.
    const big = STAGE.reflow ? 1.7 : 1;
    Object.values(nodes).forEach(n => {
      const out = gone(n.board, t);
      const hide = easeOut((t - n.hideT) / .3);
      const dim = easeOut((t - n.dimT) / .5);
      // Alive once it's down: a slow float, a pop and a flash when a packet reaches it, and a dip
      // (smaller, dimmer) while a newer node on the board takes the focus.
      const floatY = 6 * Math.sin(t * 1.7 + n.rot) * clamp((t - n.t - .4) / .5);
      const pulse = Math.max(0, ...lines.filter(l => l.s.to === n.s.id).map(l => arrivalPulse(l.path, t)));
      const dip = Math.max(0, ...Object.values(nodes).filter(o => o !== n && o.board === n.board && o.t > n.t)
        .map(o => { const u = (t - o.t) / .8; return u > 0 && u < 1 ? Math.sin(Math.PI * u) : 0; }));
      const [x, y0] = at(n), y = y0 + floatY;
      land(n.node, x, y, t, n.t, (1 - out) * (1 - hide) * big * (1 + .09 * pulse - .08 * dip), n.kind === "sticker" ? n.rot : n.rot * .4,
        (1 - .78 * dim) * (1 - .3 * dip));
      if (pulse > .02) n.node.style.filter = `brightness(${1 + .35 * pulse})`;
      drawIcons(n.node, t, n.t + .12);
      drawBurst(n.burst, x, y, t, n.t, (n.kind === "card" ? 1.05 : .8) * Math.sqrt(big), n.rot);
      if (dim > .01) n.node.style.filter += ` grayscale(${dim})`;
      if (n.label) {
        const below = (n.kind === "dot" ? 118 : 86) * big;
        place(n.label, x - (n.kind === "dot" ? 95 : 50), y + below, popScale(t, n.t + .25) * (1 - out) * (1 - hide) * big, -3, 1 - .78 * dim);
        setHL(n.label.querySelector(".hl"), (t - n.t - .5) / .4);
      }
      if (n.kind === "label") setHL(n.node.querySelector(".hl"), (t - n.t - .3) / .4);
      const r = (n.kind === "dot" ? 120 : n.kind === "card" ? 190 : 86) * big;
      n.ring.style.width = n.ring.style.height = `${2 * r}px`;
      n.ring.style.margin = `${-r}px 0 0 ${-r}px`;
      place(n.ring, x, y, popScale(t, n.hlT, .5) * (1 - out) * (1 - hide), 0, .9);
    });
    steps.filter(s => s.do === "note").forEach(s => {
      const p = s.x != null && s.y != null ? px(s.x, s.y) : [130, 380 + 140 * steps.filter(o => o.do === "note" && o.board === s.board).indexOf(s)];
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

TEMPLATES.storyboard.reflows = true;
