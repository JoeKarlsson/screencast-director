// Generates a first-draft plan.json from the analysis files.
//
//   node scripts/plan.ts <projectDir> [--force]
//
// The draft is a starting point for Claude to refine, so the rules are simple:
//   speech            -> keep at 1x (filler words like "um" are cut)
//   typing, no speech -> 3x
//   mouse, no speech  -> 1.5x
//   screen changing   -> 4x (builds, output scrolling by)
//   nothing happening -> cut
// Zooms follow clusters of clicks and typing.

import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Plan, Segment, Zoom } from "../src/types.ts";
import { loadProject, type InputEvent, type Project } from "./project.ts";

const RULES = {
  speechMergeGap: 0.7,
  speechPadBefore: 0.2,
  speechPadAfter: 0.35,
  bucket: 0.25,
  minIdleCut: 0.6,
  idleKeep: 0.1,
  typingSpeed: 3,
  mouseSpeed: 1.5,
  screenSpeed: 4,
  minSpedUp: 1.5,
  /** Mean frame difference (0-255 luma) above which the screen counts as changing. */
  motionThreshold: 0.25,
  fillers: /^(um+|uh+|erm+|uhm+|ah+|hmm+)[.,!?]*$/i,
  zoomGap: 2.5,
  zoomDistance: 0.2,
  zoomLeadIn: 0.6,
  zoomHold: 1.5,
  minZoom: 1.5,
};

type Interval = { start: number; end: number };
type Label = "speech" | "typing" | "mouse" | "screen" | "idle";

function mergeIntervals(list: Interval[], gap: number): Interval[] {
  const sorted = [...list].sort((a, b) => a.start - b.start);
  const out: Interval[] = [];
  for (const i of sorted) {
    const last = out[out.length - 1];
    if (last && i.start - last.end <= gap) last.end = Math.max(last.end, i.end);
    else out.push({ ...i });
  }
  return out;
}

function speechIntervals(p: Project): { speech: Interval[]; fillers: Interval[] } {
  const fillers = p.words.filter((w) => RULES.fillers.test(w.text)).map((w) => ({ start: w.start - 0.05, end: w.end + 0.05 }));
  const spoken = p.words
    .filter((w) => !RULES.fillers.test(w.text))
    .map((w) => ({ start: w.start - RULES.speechPadBefore, end: w.end + RULES.speechPadAfter }));
  return { speech: mergeIntervals(spoken, RULES.speechMergeGap), fillers };
}

function labelAt(t: number, p: Project, speech: Interval[], events: InputEvent[]): Label {
  const b = RULES.bucket;
  if (speech.some((s) => t + b > s.start && t < s.end)) return "speech";
  const near = events.filter((e) => e.t >= t - 0.5 && e.t < t + b + 0.5);
  if (near.some((e) => e.type === "key")) return "typing";
  if (near.some((e) => e.type !== "key")) return "mouse";
  const changing = p.motion.some(([mt, d]) => mt >= t && mt < t + b && d > RULES.motionThreshold);
  return changing ? "screen" : "idle";
}

export function buildSegments(p: Project): Segment[] {
  const { speech, fillers } = speechIntervals(p);
  const dur = p.source.duration;
  const runs: { label: Label; start: number; end: number }[] = [];
  for (let t = 0; t < dur; t += RULES.bucket) {
    const label = labelAt(t, p, speech, p.events);
    const end = Math.min(dur, t + RULES.bucket);
    const last = runs[runs.length - 1];
    if (last && last.label === label) last.end = end;
    else runs.push({ label, start: t, end });
  }

  const segments: Segment[] = [];
  for (const r of runs) {
    const len = r.end - r.start;
    let speed = 1;
    if (r.label === "idle") {
      if (len >= RULES.minIdleCut) {
        // Keep a sliver on each side so cuts don't feel clipped.
        const keepA = { start: r.start, end: r.start + RULES.idleKeep, speed: 1, note: "idle" };
        const keepB = { start: r.end - RULES.idleKeep, end: r.end, speed: 1, note: "idle" };
        if (r.start > 0) segments.push(keepA);
        if (r.end < dur) segments.push(keepB);
        continue;
      }
    } else if (r.label === "typing" && len >= RULES.minSpedUp) speed = RULES.typingSpeed;
    else if (r.label === "mouse" && len >= RULES.minSpedUp) speed = RULES.mouseSpeed;
    else if (r.label === "screen" && len >= RULES.minSpedUp) speed = RULES.screenSpeed;
    segments.push({ start: r.start, end: r.end, speed, note: r.label });
  }

  // Remove filler words from inside kept segments.
  let result = segments;
  for (const f of fillers) {
    result = result.flatMap((s) => {
      if (f.end <= s.start || f.start >= s.end) return [s];
      const parts: Segment[] = [];
      if (f.start > s.start) parts.push({ ...s, end: f.start });
      if (f.end < s.end) parts.push({ ...s, start: f.end });
      return parts;
    });
  }

  // Merge touching segments with the same speed.
  const merged: Segment[] = [];
  for (const s of result) {
    const last = merged[merged.length - 1];
    if (last && Math.abs(last.end - s.start) < 1e-6 && last.speed === s.speed) {
      last.end = s.end;
      if (s.note && last.note && !last.note.split("+").includes(s.note)) last.note += `+${s.note}`;
    } else merged.push({ ...s });
  }
  return merged
    .filter((s) => s.end - s.start > 0.04)
    .map((s) => ({ ...s, start: +s.start.toFixed(3), end: +s.end.toFixed(3) }));
}

export function buildZooms(p: Project): Zoom[] {
  // Typing has no caret position, so it borrows the last click before it.
  let lastClick: InputEvent | undefined;
  const focus: (InputEvent & { fx: number; fy: number })[] = [];
  for (const e of p.events) {
    if (e.type === "click") {
      lastClick = e;
      focus.push({ ...e, fx: e.x, fy: e.y });
    } else if (e.type === "key") {
      const anchor = lastClick && e.t - lastClick.t < 20 ? lastClick : e;
      focus.push({ ...e, fx: anchor.x, fy: anchor.y });
    }
  }

  const clusters: (typeof focus)[] = [];
  for (const e of focus) {
    if (e.fx < 0 || e.fx > 1 || e.fy < 0 || e.fy > 1) continue; // another display
    const cur = clusters[clusters.length - 1];
    const prev = cur?.[cur.length - 1];
    if (prev && e.t - prev.t <= RULES.zoomGap && Math.hypot(e.fx - prev.fx, e.fy - prev.fy) <= RULES.zoomDistance) cur.push(e);
    else clusters.push([e]);
  }

  const zooms: Zoom[] = clusters.map((c) => {
    const typing = c.filter((e) => e.type === "key").length > c.length / 2;
    const start = Math.max(0, c[0].t - RULES.zoomLeadIn);
    const end = Math.max(c[c.length - 1].t + RULES.zoomHold, start + RULES.minZoom);
    return {
      start: +start.toFixed(2),
      end: +Math.min(end, p.source.duration).toFixed(2),
      x: +(c.reduce((a, e) => a + e.fx, 0) / c.length).toFixed(3),
      y: +(c.reduce((a, e) => a + e.fy, 0) / c.length).toFixed(3),
      scale: typing ? 2 : 1.6,
      note: typing ? `typing (${c.length} keys)` : `${c.length} click(s)`,
    };
  });

  // Overlapping zooms hand off: the earlier one ends where the next begins (renders as a pan).
  for (let i = 0; i + 1 < zooms.length; i++) {
    if (zooms[i].end > zooms[i + 1].start) zooms[i].end = zooms[i + 1].start;
  }
  return zooms.filter((z) => z.end - z.start > 0.3);
}

export function buildPlan(p: Project): Plan {
  return {
    version: 1,
    source: { video: p.source.video, width: p.source.width, height: p.source.height, duration: p.source.duration },
    ...(p.source.camera ? { camera: p.source.camera } : {}),
    output: { width: 1920, height: 1080, fps: 30 },
    style: { background: ["#1d2b64", "#f8cdda"], padding: 0.06, radius: 14, transition: 0.8 },
    segments: buildSegments(p),
    zooms: buildZooms(p),
    defaultLayout: p.source.camera ? "pip" : "screen",
    layouts: [],
    captions: { enabled: p.words.length > 0, maxWords: 7 },
    clickRipples: true,
    shortcutChips: true,
    callouts: [],
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [dir, flag] = process.argv.slice(2);
  if (!dir) {
    console.error("usage: node scripts/plan.ts <projectDir> [--force]");
    process.exit(64);
  }
  const out = join(dir, "plan.json");
  if (existsSync(out) && flag !== "--force") {
    console.error(`${out} exists (it may hold edits). Pass --force to regenerate it.`);
    process.exit(1);
  }
  const plan = buildPlan(loadProject(dir));
  writeFileSync(out, JSON.stringify(plan, null, 2) + "\n");
  console.log(`wrote ${out}: ${plan.segments.length} segments, ${plan.zooms.length} zooms`);
}
