// "lottie": a Lottie animation (an After Effects export as .json, e.g. from LottieFiles) played at a
// spot in the frame, frame-exact: each seek shows the Lottie frame for that moment (lottie-web,
// vendor/lottie_svg.min.js). Over the video with `overlay`, or on the paper.
//
// data: lottie (a file in the video's animations/lottie/ folder, e.g. "confetti.json"), x, y (its center
//       in % of the frame; default 50, 50), width (% of the frame's width; default 40), speed (default 1),
//       loop (default true: plays again from the top; false holds the last frame)
// cues: play (when it starts; default the animation's start)
"use strict";
TEMPLATES.lottie = function (data, cues, duration) {
  if (!LOTTIE) throw new Error(`no Lottie file: put it in the video's animations/lottie/ folder and name it in data.lottie`);
  const box = el("lottiebox");
  const w = (Number(data.width) || 40) / 100 * STAGE.w;
  const ratio = (LOTTIE.h || 1) / (LOTTIE.w || 1);
  box.style.width = `${w}px`;
  box.style.height = `${w * ratio}px`;
  const x = (Number.isFinite(data.x) ? data.x : 50) / 100 * STAGE.w - w / 2, y = (Number.isFinite(data.y) ? data.y : 50) / 100 * STAGE.h - w * ratio / 2;
  const anim = lottie.loadAnimation({ container: box, renderer: "svg", loop: false, autoplay: false, animationData: LOTTIE });
  const frames = Math.max(1, (LOTTIE.op || 1) - (LOTTIE.ip || 0)), fps = LOTTIE.fr || 30;
  const speed = Number(data.speed) || 1, loop = data.loop !== false, start = cue(cues, "play", 0);

  return t => {
    grain(t);
    place(box, x, y, t >= start ? 1 : 0);
    const f = Math.max(0, (t - start) * fps * speed);
    anim.goToAndStop(loop ? f % frames : Math.min(f, frames - 1), true);
  };
};
