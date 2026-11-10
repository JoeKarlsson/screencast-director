// "chart": one chart that builds as it's talked through. Bars rise one after another (or a line draws
// through its points, a dot landing on each), each value counting up as it arrives, then one value
// gets the accent and a tag that counts up to it, with an optional note beside it.
// Timing adapted from HyperFrames' chart-story (HeyGen, Apache-2.0; see vendor/hyperframes-NOTICE.md),
// rewritten as a function of t.
//
// data: title, highlight, kind ("bars", the default, or "line"), values [up to 12 numbers],
//       labels [one per value], unit (after each value, e.g. "%" or "k"), prefix (before it, e.g. "$"),
//       emphasize (index of the value to call out; default the largest), note (text beside the callout)
// cues: chart (the first bar rises or the line starts), callout (the accent and its tag)
"use strict";
TEMPLATES.chart = function (data, cues, duration) {
  const values = (data.values || []).map(Number).filter(Number.isFinite).slice(0, 12);
  const labels = (data.labels || []).map(String);
  const line = data.kind === "line";
  const n = Math.max(1, values.length);
  const T = { chart: cue(cues, "chart", 1), callout: cue(cues, "callout", cue(cues, "chart", 1) + n * .22 + 1) };
  const hot = Number.isInteger(data.emphasize) && data.emphasize >= 0 && data.emphasize < values.length
    ? data.emphasize : values.indexOf(Math.max(...values));
  const decimals = Math.min(2, Math.max(0, ...values.map(v => (String(v).split(".")[1] || "").length)));
  const fmt = v => `${data.prefix || ""}${v.toLocaleString("en-US", { minimumFractionDigits: decimals, maximumFractionDigits: decimals })}${data.unit || ""}`;
  // A round top for the scale: 1, 2 or 5 times a power of ten, at or above the largest value.
  const top = (() => {
    const m = Math.max(...values, 0);
    if (m <= 0) return 1;
    const p = Math.pow(10, Math.floor(Math.log10(m)));
    return [1, 2, 2.5, 5, 10].map(k => k * p).find(v => v >= m * 1.08) || 10 * p;
  })();

  // The plot, in stage px: below the heading, with room for the labels under the baseline.
  const X0 = 210, X1 = 1710, Y0 = 330, Y1 = 880;
  const slot = (X1 - X0) / n;
  const xAt = i => X0 + slot * (i + .5), yAt = v => Y1 - (Y1 - Y0) * clamp(v / top, 0, 1.2);
  const head = heading(data.title || "", data.highlight);
  const base = path(5, "var(--ink)");
  const barW = Math.min(150, slot * .62);
  const bars = values.map((v, i) => {
    const bar = line ? null : el("bar");
    if (bar) { bar.style.width = `${barW}px`; bar.style.marginLeft = `${-barW / 2}px`; bar.classList.toggle("hot", i === hot); }
    const value = el("label value", "");
    const name = labels[i] ? el("label cat", esc(labels[i])) : null;
    // Line: each dot lands as the line reaches it.
    const dot = line ? el("pip") : null;
    if (dot) dot.classList.toggle("hot", i === hot);
    return { v, i, bar, value, name, dot, t: T.chart + (line ? i / Math.max(1, n - 1) * 1.6 : i * .22) };
  });
  // The line as one curve through every point, drawn on by length.
  const pts = values.map((v, i) => [xAt(i), yAt(v)]);
  const lens = pts.slice(1).map((p, i) => Math.hypot(p[0] - pts[i][0], p[1] - pts[i][1]));
  const total = lens.reduce((a, b) => a + b, 0) || 1;
  const curve = {
    still: true, // a chart's line carries no packets
    d: pts.length ? `M${pts.map(p => p.map(c => c.toFixed(1)).join(",")).join(" L")}` : "",
    at: u => {
      let d = clamp(u) * total;
      for (let i = 0; i < lens.length; i++) {
        if (d <= lens[i] || i === lens.length - 1) { const k = lens[i] ? clamp(d / lens[i]) : 0; return [pts[i][0] + (pts[i + 1][0] - pts[i][0]) * k, pts[i][1] + (pts[i + 1][1] - pts[i][1]) * k]; }
        d -= lens[i];
      }
      return pts[0] || [0, 0];
    },
  };
  const trace = line && pts.length > 1 ? path(8, "var(--ink)") : null;
  const tag = values.length ? el("tag callout", "") : null;
  const note = data.note ? el("hand chip", `<span class="wrapt"><span class="hl"></span>${esc(data.note)}</span>`) : null;
  // How far along the line each point sits, for when its dot lands.
  const at = [0];
  lens.forEach((l, i) => at.push(at[i] + l / total));
  const drawSpan = 1.6;

  return t => {
    grain(t);
    camera(t, 1.05 - .05 * easeOut(t / 1.2) + .02 * clamp(t / Math.max(duration, 1)), 1.6);
    place(head.node, 110, 92, 1, 0, easeOut((t - .1) / .4));
    revealHeading(head, t, .1);
    setHL(head.hl, (t - .6) / .5);
    drawPath(base, { d: `M${X0 - 30},${Y1} L${X1 + 30},${Y1}` }, (t - T.chart + .5) / .5);
    const progress = line ? (t - T.chart) / drawSpan : 0;
    // Drawn at an even pace, so each dot lands just as the line reaches it.
    if (trace) drawPath(trace, curve, progress);
    bars.forEach(b => {
      const x = xAt(b.i);
      // Line: a dot lands where the line has reached it; bars: rise on a spring from the baseline.
      const start = line ? T.chart + at[b.i] * drawSpan : b.t;
      const grow = line ? 1 : spring((t - start) / .85, .82);
      const shown = t >= start;
      if (b.bar) {
        const h = Math.max(0, (Y1 - yAt(b.v)) * grow);
        b.bar.style.height = `${h}px`;
        place(b.bar, x, Y1 - h, shown ? 1 : 0);
        b.bar.classList.toggle("lit", t >= T.callout && b.i === hot);
      }
      if (b.dot) place(b.dot, pts[b.i][0], pts[b.i][1], popScale(t, start, .35));
      const kf = line ? clamp((frameStart(t) - start) / .5) : clamp(spring((frameStart(t) - start) / .85, .82));
      b.value.textContent = fmt(b.v * easeOut(kf));
      const vy = line ? pts[b.i][1] - 64 : Y1 - (Y1 - yAt(b.v)) * grow - 58;
      place(b.value, x - b.value.offsetWidth / 2, vy, shown ? 1 : 0, 0, clamp((t - start) / .25) * (b.i === hot && t >= T.callout ? 0 : 1));
      if (b.name) place(b.name, x - b.name.offsetWidth / 2, Y1 + 22, 1, 0, easeOut((t - T.chart + .4 - b.i * .05) / .4));
    });
    if (tag) {
      const v = values[hot], x = xAt(hot), y = line ? pts[hot][1] : yAt(v);
      // The tag counts up to the value as it lands, a little faster than the bars rose.
      tag.textContent = fmt(v * easeOut((frameStart(t) - T.callout) / .7));
      place(tag, x - tag.offsetWidth / 2, y - 120, popScale(t, T.callout, .45), -3);
    }
    if (note) {
      const x = xAt(hot), right = x < (X0 + X1) / 2;
      const y = (line ? pts[hot][1] : yAt(values[hot])) - 120;
      place(note, right ? x + 110 : x - 110 - note.offsetWidth, y - 6, popScale(t, T.callout + .3), right ? 2 : -2);
      setHL(note.querySelector(".hl"), (t - T.callout - .5) / .4);
    }
  };
};
