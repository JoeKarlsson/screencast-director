// "note": a sticker over the video, the same as a meme sticker: a big word or number with the site's
// crayon mark scribbled around it, a word beside it, a line under it and an optional logo above. Give
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
  // Type sized to the sticker's width; a long line shrinks until it fits on one row.
  const line = card.querySelector(".line");
  for (let k = 1; line && line.scrollWidth > line.clientWidth + 1 && k > .35; k *= .92) card.style.setProperty("--k", k * .92);

  // The mark goes around the big word (else the text beside it), in the card's own pixels.
  const target = card.querySelector(".big") || card.querySelector(".txt");
  const kind = data.mark || "oval";
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "mark");
  svg.setAttribute("width", card.offsetWidth); svg.setAttribute("height", card.offsetHeight);
  card.appendChild(svg);
  const strokes = [];
  const stroke = (d, width, transform = "") => {
    const p = document.createElementNS(NS, "path");
    // The pen keeps its width however the mark is stretched to fit the word.
    p.setAttribute("d", d); p.setAttribute("pathLength", "1"); p.setAttribute("stroke-width", width); p.setAttribute("vector-effect", "non-scaling-stroke");
    if (transform) p.setAttribute("transform", transform);
    p.style.strokeDasharray = 1; p.style.strokeDashoffset = 1;
    svg.appendChild(p); strokes.push(p);
  };
  if (target && kind !== "none" && typeof SCRIBBLES !== "undefined") {
    const x = target.offsetLeft, y = target.offsetTop, w = target.offsetWidth, h = target.offsetHeight;
    const pen = Math.max(4, card.offsetWidth * .016);
    if (kind === "underline") {
      // Just under the letters (Anton's line box is tight to them), into the card's bottom padding.
      stroke(squiggle([x, y + h * 1.1], [x + w, y + h * 1.1], 0, 3).d, pen);
    } else {
      const m = kind === "burst" ? SCRIBBLES.burstDense : SCRIBBLES.oval;
      const [, , vw, vh] = m.viewBox.split(" ").map(Number);
      // The oval rings the word with room to spare; the burst flares off its top right corner.
      const box = kind === "burst" ? [x + w * .82, y - h * .2, h * .7, h * .7] : [x - w * .2, y - h * .12, w * 1.4, h * 1.24];
      const sx = box[2] / vw, sy = box[3] / vh;
      m.path.split(/(?=M)/).map(d => d.trim()).filter(Boolean)
        .forEach(d => stroke(d, pen, `translate(${box[0]} ${box[1]}) scale(${sx} ${sy})`));
    }
  }
  const start = cue(cues, "mark", .45);

  return t => {
    // Drawn on stroke after stroke over half a second, like a pen going round.
    const p = clamp((t - start) / .5) * strokes.length;
    strokes.forEach((s, i) => { s.style.strokeDashoffset = 1 - clamp(p - i); });
  };
};
