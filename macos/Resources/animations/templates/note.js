// "note": a sticker over the video, the same as a meme sticker: a big word or number with a
// hand-drawn mark (the look's marks) around it, a word beside it, a line under it and an optional logo above. Give
// the animation `sticker` ({x, y, w}) in the plan: the video pops it on and off like every sticker,
// and the mark draws itself on once it has landed.
//
// data: big (the word or number the mark goes around, e.g. "3–4"), text (beside it, e.g. "years"),
//       small (a line under it), logo (a logo name, above), mark ("oval", the default, "underline",
//       "burst" or "none"), dark (true: a black card with the text in the accent, for a white logo)
// cues: mark (when the mark starts drawing; default 0.45 s in, once the sticker has landed)
"use strict";
TEMPLATES.note = function (data, cues, duration) {
  const card = document.createElement("div");
  card.id = "sticker";
  card.className = "note" + (data.dark ? " dark" : "");
  card.innerHTML = (data.logo ? `<div class="logo">${logoHTML(data.logo)}</div>` : "")
    + `<div class="line">${data.big ? `<span class="big">${esc(data.big)}</span>` : ""}${data.text ? `<span class="txt">${esc(data.text)}</span>` : ""}</div>`
    + (data.small ? `<div class="small">${esc(data.small)}</div>` : "");
  document.body.appendChild(card);
  const line = card.querySelector(".line"), txt = card.querySelector(".txt"), small = card.querySelector(".small"), logo = card.querySelector(".logo");

  // The mark goes around the big word (else the text beside it), in the card's own pixels. The
  // word it marks is `.marked`: the render's mark probe lets the mark cross that text and no other.
  const target = card.querySelector(".big") || txt;
  const kind = target && typeof SCRIBBLES !== "undefined" ? data.mark || "oval" : "none";
  if (target && kind !== "none") target.classList.add("marked");
  const pen = Math.max(4, card.offsetWidth * .016);
  // Each stroke as [d, transform], and the box the pen covers, [left, top, right, bottom].
  const markShape = () => {
    const x = target.offsetLeft, y = target.offsetTop, w = target.offsetWidth, h = target.offsetHeight;
    if (kind === "underline") {
      // Just under the letters (Anton's line box is tight to them). The squiggle bows and waves by
      // a fixed number of pixels, so its box comes from the curve itself, plus its jitter.
      const s = squiggle([x, y + h * 1.1], [x + w, y + h * 1.1], 0, 3);
      const pts = Array.from({ length: 41 }, (_, i) => s.at(i / 40));
      const pad = pen / 2 + 2;
      return {
        strokes: [[s.d, ""]],
        box: [Math.min(...pts.map(p => p[0])) - pad, Math.min(...pts.map(p => p[1])) - pad,
          Math.max(...pts.map(p => p[0])) + pad, Math.max(...pts.map(p => p[1])) + pad],
      };
    }
    const m = kind === "burst" ? SCRIBBLES.burstDense : SCRIBBLES.oval;
    const [, , vw, vh] = m.viewBox.split(" ").map(Number);
    // The oval rings the word with room to spare; the burst flares off its top right corner.
    const b = kind === "burst" ? [x + w * .82, y - h * .2, h * .7, h * .7] : [x - w * .2, y - h * .12, w * 1.4, h * 1.24];
    const sx = b[2] / vw, sy = b[3] / vh;
    // The drawing can overshoot its viewBox, so its box is the path's own points (a curve stays
    // inside its control points).
    const n = m.path.match(/-?[\d.]+/g).map(Number), xs = n.filter((_, i) => i % 2 === 0), ys = n.filter((_, i) => i % 2 === 1);
    return {
      strokes: m.path.split(/(?=M)/).map(d => d.trim()).filter(Boolean).map(d => [d, `translate(${b[0]} ${b[1]}) scale(${sx} ${sy})`]),
      box: [b[0] + Math.min(...xs) * sx - pen / 2, b[1] + Math.min(...ys) * sy - pen / 2,
        b[0] + Math.max(...xs) * sx + pen / 2, b[1] + Math.max(...ys) * sy + pen / 2],
    };
  };

  // Type sized to the sticker's width: a long line shrinks until it fits on one row and its mark
  // fits on the card. Then the other text moves out of the mark's way (the line beside it, the line
  // under it, the logo above) and the card grows to hold it, so the pen never crosses a word.
  const room = card.offsetWidth * .025;
  const box = e => [e.offsetLeft, e.offsetTop, e.offsetLeft + e.offsetWidth, e.offsetTop + e.offsetHeight];
  const hits = (a, b) => a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3];
  const px = (e, prop) => parseFloat(getComputedStyle(e)[prop]) || 0;
  let k = 1;
  const shrink = () => {
    // Smaller type, so the room made for the last mark starts over.
    for (const e of [card, line, small, logo]) if (e) e.removeAttribute("style");
    k *= .92; card.style.setProperty("--k", k);
  };
  for (let pass = 0; pass < 40; pass++) {
    if (line && line.scrollWidth > line.clientWidth + 1 && k > .35) { shrink(); continue; }
    if (kind === "none") break;
    const m = markShape().box;
    if ((m[0] < 0 || m[2] > card.offsetWidth) && k > .35) { shrink(); continue; }
    let moved = false;
    if (txt && txt !== target && hits(m, box(txt))) { line.style.columnGap = `${px(line, "columnGap") + m[2] - box(txt)[0] + room}px`; moved = true; }
    if (small && hits(m, box(small))) { small.style.marginTop = `${px(small, "marginTop") + m[3] - box(small)[1] + room}px`; moved = true; }
    if (logo && hits(m, box(logo))) { logo.style.marginBottom = `${px(logo, "marginBottom") + box(logo)[3] - m[1] + room}px`; moved = true; }
    if (m[3] > card.offsetHeight) { card.style.paddingBottom = `${px(card, "paddingBottom") + m[3] - card.offsetHeight + room}px`; moved = true; }
    if (m[1] < 0) { card.style.paddingTop = `${px(card, "paddingTop") - m[1] + room}px`; moved = true; }
    if (!moved) break;
  }

  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "mark");
  svg.setAttribute("width", card.offsetWidth); svg.setAttribute("height", card.offsetHeight);
  card.appendChild(svg);
  // Pieces the app can move by hand (the engine's applyLayout). The mark follows the word it rings,
  // sized about that word's center.
  const big = card.querySelector(".big");
  for (const [name, node] of [["big", big], ["text", txt], ["small", small], ["logo", logo]]) if (node) node.setAttribute("data-piece", name);
  if (target) {
    svg.setAttribute("data-follows", target === big ? "big" : "text");
    svg.style.transformOrigin = `${target.offsetLeft + target.offsetWidth / 2}px ${target.offsetTop + target.offsetHeight / 2}px`;
  }
  const strokes = kind === "none" ? [] : markShape().strokes.map(([d, transform]) => {
    const p = document.createElementNS(NS, "path");
    // The pen keeps its width however the mark is stretched to fit the word.
    p.setAttribute("d", d); p.setAttribute("pathLength", "1"); p.setAttribute("stroke-width", pen); p.setAttribute("vector-effect", "non-scaling-stroke");
    if (transform) p.setAttribute("transform", transform);
    p.style.strokeDasharray = 1; p.style.strokeDashoffset = 1;
    svg.appendChild(p); return p;
  });
  const start = cue(cues, "mark", .45);

  return t => {
    // Drawn on stroke after stroke over half a second (times the hand-tuned pop length), like a pen going round.
    const p = clamp((t - start) / (.5 * TUNE.pop)) * strokes.length;
    strokes.forEach((s, i) => { s.style.strokeDashoffset = 1 - clamp(p - i); });
  };
};
