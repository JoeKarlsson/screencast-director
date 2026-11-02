// "sprawl": one thing wired to many apps one at a time, each with its own costs, until it's a mess.
//
// data: title, highlight (part of title to highlighter), center {logo, label}, apps [up to 8 names],
//       extraApps [up to 4 names, added on "many"], questions [up to 3 notes], costs [3 row labels],
//       fewCount (apps kept on "few", default 2)
// cues: apps, q1, q2, q3, cost1, cost2, cost3, few, many, circle (seconds from the start)
"use strict";
TEMPLATES.sprawl = function (data, cues, duration) {
  const T = {
    dot: 0, apps: cue(cues, "apps", .6), q: [cue(cues, "q1", 5), cue(cues, "q2", 7), cue(cues, "q3", 9)],
    cost: [cue(cues, "cost1", 11.5), cue(cues, "cost2", 13.5), cue(cues, "cost3", 15.5)],
    few: cue(cues, "few", 1e9), many: cue(cues, "many", 1e9), circle: cue(cues, "circle", 1e9),
  };
  const C = [1200, 545];
  const first = (data.apps || []).slice(0, 8);
  const more = (data.extraApps || []).slice(0, 4);
  const fewCount = data.fewCount ?? 2;
  const apps = first.map((name, i) => {
    const a = -Math.PI / 2 + .25 + 2 * Math.PI * i / Math.max(first.length, 1);
    return { name, home: [C[0] + 520 * Math.cos(a), C[1] + 290 * Math.sin(a)], t: T.apps + i * .34, rot: (rand(i + 5)() - .5) * 14 };
  });
  const extraAt = [[1530, 195], [1690, 830], [850, 850], [1180, 175]];
  more.forEach((name, j) => apps.push({ name, home: extraAt[j], t: T.many + .1 + j * .16, rot: (rand(j + 50)() - .5) * 16, extra: true }));
  apps.forEach((a, i) => {
    a.line = path(5, "var(--ink)"); a.node = el("sticker", logoHTML(a.name)); a.seed = i + 1;
    a.icons = ["lock", "shield", "log"].map(k => el("icon", ICONS[k]));
  });
  const center = data.center || {};
  const dot = el("dot", LOGOS[center.logo] ? `<img src="logos/${LOGOS[center.logo]}">` : `<div class="word">${esc(center.logo || "")}</div>`);
  const dotLabel = center.label ? el("hand chip", `<span class="wrapt"><span class="hl"></span>${esc(center.label)}</span>`) : null;
  const notes = (data.questions || []).slice(0, 3).map((txt, i) => ({ node: el("tag", esc(txt)), s: T.q[i], at: [[130, 380], [170, 520], [130, 660]][i], rot: [-5, 4, -3][i] }));
  const head = heading(data.title || "", data.highlight);
  const rows = tally((data.costs || []).slice(0, 3), T.cost, 110, 380, 130);
  const ring = path(14, "var(--accent)");

  return t => {
    grain(t);
    const few = easeOut((t - T.few) / .5) * (1 - easeOut((t - T.many) / .4));
    const tangle = easeInOut((t - T.many - .3) / 1.8);
    camera(t, 1 + .03 * clamp(t / Math.max(duration, 1)) + .03 * tangle, 2.2 + 7 * tangle);
    place(head.node, 110, 92, 1, 0, easeOut((t - .1) / .4));
    setHL(head.hl, (t - .6) / .5);
    place(dot, C[0], C[1], popScale(t, T.dot, .5), 0, 1, popBlur(t, T.dot));
    if (dotLabel) { place(dotLabel, C[0] - 95, C[1] + 118, popScale(t, .5), -3); setHL(dotLabel.querySelector(".hl"), (t - .8) / .4); }

    apps.forEach((a, i) => {
      const dim = !a.extra && i >= fewCount ? few : 0;
      const op = 1 - .78 * dim;
      const curve = handCurve(C, a.home, t, a.seed, i % 2 ? 40 : -40, tangle * (i % 3 === 0 ? 1.1 : .8));
      drawPath(a.line, curve, (t - a.t) / .45, op);
      const s = popScale(t, a.t + .2);
      place(a.node, a.home[0], a.home[1], s, a.rot * (1 - .3 * s), op, popBlur(t, a.t + .2));
      if (dim > .01) a.node.style.filter += ` grayscale(${dim})`;
      a.icons.forEach((ic, k) => {
        const start = a.extra ? Math.max(T.cost[k], a.t + .45 + k * .12) : T.cost[k] + i * .07;
        place(ic, a.home[0] - 44 + k * 44, a.home[1] + 74, popScale(t, start, .35) * .62, 0, op, popBlur(t, start));
      });
    });
    notes.forEach(g => place(g.node, g.at[0], g.at[1], popScale(t, g.s), g.rot * popScale(t, g.s), 1 - easeOut((t - T.cost[0] + .3) / .4)));

    const visible = apps.filter(a => t >= a.t + .3).length;
    const n = few > .5 ? fewCount : visible;
    showTally(rows, t, t >= T.many + .3 ? `${n}+` : `${n}`);

    const pts = [];
    for (let k = 0; k <= 48; k++) {
      const a = -1.2 + k / 48 * 2 * Math.PI * 1.06, rr = 1 + .03 * Math.sin(k * 1.7);
      pts.push([C[0] + 600 * rr * Math.cos(a), C[1] + 10 + 390 * rr * Math.sin(a)]);
    }
    ring.setAttribute("d", "M" + pts.map(p => p.join(",")).join(" L"));
    ring.style.strokeDasharray = 1; ring.style.strokeDashoffset = 1 - easeOut((t - T.circle) / .7);
    ring.style.opacity = t < T.circle ? 0 : .85; ring.style.mixBlendMode = "multiply";
  };
};
