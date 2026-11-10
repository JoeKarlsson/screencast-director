// "hub": one connection to a hub that fans out to many apps, with one of each cost. The answer to "sprawl".
//
// data: title, highlight, center {logo, label}, hub {logo, label}, link (tag on the one line),
//       apps [up to 12 names, a 3-wide grid], more (label for the field of extra logos),
//       moreApps [names for that field, each shown once before any repeats; default: apps], costs [3 row labels]
// cues: hub, link, apps, more, cost1, cost2, cost3 (seconds from the start)
"use strict";
TEMPLATES.hub = function (data, cues, duration) {
  const T = {
    dot: 0, hub: cue(cues, "hub", 1.4), link: cue(cues, "link", 3.6), apps: cue(cues, "apps", 4.4), more: cue(cues, "more", 6.3),
    cost: [cue(cues, "cost1", 7.9), cue(cues, "cost2", 9.8), cue(cues, "cost3", 14.3)],
  };
  const D = [380, 600], H = [930, 600];
  const names = (data.apps || []).slice(0, 12);
  const apps = names.map((name, i) => ({ name, home: [1300 + (i % 3) * 175, 250 + Math.floor(i / 3) * 165], t: T.apps + i * .1, rot: (rand(i + 9)() - .5) * 8 }));
  apps.forEach((a, i) => { a.line = path(4, "var(--ink)"); a.node = el("sticker", logoHTML(a.name)); a.seed = i + 1; });
  const ghosts = [];
  // The field behind the grid: its own apps if given (each once before any repeats), else the grid's.
  const extra = (data.moreApps || []).filter(n => !names.includes(n));
  const field = extra.length ? extra : names;
  if (data.more && field.length) {
    const r = rand(77);
    for (let gx = 0; gx < 6; gx++) for (let gy = 0; gy < 9; gy++) {
      const x = 1210 + gx * 120 + (r() - .5) * 30, y = 120 + gy * 100 + (r() - .5) * 26;
      if (gx <= 4 && gy >= 1 && gy <= 7 && x > 1240 && x < 1880) continue; // keep the named grid clear
      ghosts.push({ node: el("ghost", logoHTML(field[ghosts.length % field.length])), at: [x, y], t: T.more + r() * 1.1 });
    }
  }
  const main = path(12, "var(--ink)");
  const center = data.center || {}, hubData = data.hub || {};
  const dot = el("dot", LOGOS[center.logo] ? `<img src="${LOGOS[center.logo]}">` : `<div class="word">${esc(center.logo || "")}</div>`);
  const dotLabel = center.label ? el("hand chip", `<span class="wrapt"><span class="hl"></span>${esc(center.label)}</span>`) : null;
  const hubNode = el("hub", `${LOGOS[hubData.logo] ? `<img src="${LOGOS[hubData.logo]}">` : ""}<div>${esc(hubData.label || "")}</div>`);
  const link = data.link ? el("tag", esc(data.link)) : null;
  const icons = ["lock", "shield", "log"].map(k => el("icon", ICONS[k]));
  const more = data.more ? el("hand", `<span class="wrapt"><span class="hl"></span>${esc(data.more)}</span>`) : null;
  const head = heading(data.title || "", data.highlight);
  const rows = tally((data.costs || []).slice(0, 3), T.cost, 110, 290, 100);

  return t => {
    grain(t);
    // Pull back out of a blur, like a camera move onto a new board.
    const pull = easeOut(t / .7);
    camera(t, 1.12 - .12 * pull + .03 * clamp(t / Math.max(duration, 1)), 2.2);
    document.getElementById("stage").style.filter = t < .7 ? `blur(${(1 - pull) * 10}px)` : "";
    place(head.node, 110, 92, 1, 0, easeOut((t - .1) / .4));
    setHL(head.hl, (t - .6) / .5);
    place(dot, D[0], D[1], popScale(t, T.dot, .5));
    if (dotLabel) { place(dotLabel, D[0] - 85, D[1] + 112, popScale(t, .4), -3); setHL(dotLabel.querySelector(".hl"), (t - .7) / .4); }
    drawPath(main, handCurve([D[0] + 95, D[1]], [H[0] - 165, H[1]], t, 99, 0), (t - T.hub - .3) / .4);
    const hs = popScale(t, T.hub, .5);
    place(hubNode, H[0], H[1], hs, -2 * (1 - hs));
    if (link) place(link, (D[0] + H[0]) / 2 - 60, D[1] - 90, popScale(t, T.link), -4);
    icons.forEach((ic, k) => place(ic, (D[0] + H[0]) / 2 - 70 + k * 70, D[1], popScale(t, T.cost[k], .4)));
    apps.forEach(a => {
      drawPath(a.line, handCurve([H[0] + 165, H[1]], [a.home[0] - 60, a.home[1]], t, a.seed, 0), (t - a.t) / .35, .85);
      place(a.node, a.home[0], a.home[1], popScale(t, a.t + .15) * .9, a.rot);
    });
    ghosts.forEach(g => place(g.node, g.at[0], g.at[1], popScale(t, g.t, .3), 0, .55));
    if (more) { place(more, 1470, 925, popScale(t, T.more + .9), -2); setHL(more.querySelector(".hl"), (t - T.more - 1.1) / .4); }
    showTally(rows, t, "1", 80);
  };
};
