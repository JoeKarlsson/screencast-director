// "stat": one big number on a card. It rises in, counts up to its value, a track under it fills to
// value/max, and a caption fades in below. Made to float over the video (overlay), or to fill the frame.
// Timing adapted from HyperFrames' mk-progress-stat (HeyGen, Apache-2.0; see vendor/hyperframes-NOTICE.md),
// rewritten as a function of t.
//
// data: value (a number), prefix (before it, e.g. "$"), unit (after it, e.g. "%" or "x"), label (beside
//       the number), caption (under the track), max (the track's full value; no track without it),
//       x, y (the card's center in % of the frame; default 50, 50)
// cues: count (the number starts counting), caption
"use strict";
TEMPLATES.stat = function (data, cues, duration) {
  const value = Number(data.value) || 0;
  const decimals = Math.min(2, (String(data.value ?? "").split(".")[1] || "").length);
  const fmt = v => `${data.prefix || ""}${v.toLocaleString("en-US", { minimumFractionDigits: decimals, maximumFractionDigits: decimals })}${data.unit || ""}`;
  const T = { count: cue(cues, "count", .5), caption: cue(cues, "caption", cue(cues, "count", .5) + 1.4) };
  const max = Number(data.max) > 0 ? Number(data.max) : null;
  const card = el("statcard", `<div class="row"><span class="num"></span>${data.label ? `<span class="label">${esc(data.label)}</span>` : ""}</div>`
    + (max ? '<div class="track"><div class="fill"></div></div>' : "")
    + (data.caption ? `<div class="caption">${esc(data.caption)}</div>` : ""));
  const num = card.querySelector(".num"), fill = card.querySelector(".fill"), caption = card.querySelector(".caption");
  // The widest the number gets, so the card is sized once and doesn't grow as it counts.
  num.textContent = fmt(value);
  num.style.minWidth = `${num.offsetWidth}px`;
  const x = (Number.isFinite(data.x) ? data.x : 50) / 100 * STAGE.w, y = (Number.isFinite(data.y) ? data.y : 50) / 100 * STAGE.h;
  const w = card.offsetWidth, h = card.offsetHeight;

  return t => {
    grain(t);
    // Rises in from a little below, then holds; out over the last 0.4 s, so it doesn't cut off.
    const rise = easeOut((t - .1) / .6), out = clamp((duration - t) / .4);
    place(card, x - w / 2, y - h / 2 + 28 * (1 - rise), 1, 0, rise * out);
    const k = easeOut((t - T.count) / 1.6);
    num.textContent = fmt(frameStart(t) < T.count ? 0 : value * easeOut((frameStart(t) - T.count) / 1.6));
    if (fill) fill.style.transform = `scaleX(${clamp(value / max) * k})`;
    if (caption) caption.style.opacity = easeOut((t - T.caption) / .5);
  };
};
// x and y are shares of the frame, so the board takes the frame's shape (a vertical video's too).
TEMPLATES.stat.reflows = true;
