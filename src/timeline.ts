// Pure timeline math shared by the planner and the renderer. No React here.

import type { LayoutMode, Plan, Segment, Zoom } from "./types.ts";

export type MappedSegment = Segment & {
  /** First output frame of this segment. */
  outStart: number;
  /** Output length in frames. */
  frames: number;
};

export function mapSegments(segments: Segment[], fps: number): MappedSegment[] {
  const sorted = [...segments].sort((a, b) => a.start - b.start);
  const mapped: MappedSegment[] = [];
  let outStart = 0;
  for (const s of sorted) {
    const frames = Math.round(((s.end - s.start) / s.speed) * fps);
    if (frames < 1) continue;
    mapped.push({ ...s, outStart, frames });
    outStart += frames;
  }
  return mapped;
}

export function totalFrames(mapped: MappedSegment[]): number {
  const last = mapped[mapped.length - 1];
  return last ? last.outStart + last.frames : 1;
}

/** Output frame (fractional) for a source time, or null if that moment is cut. */
export function srcToOut(mapped: MappedSegment[], t: number, fps: number): number | null {
  for (const s of mapped) {
    if (t >= s.start && t < s.end) return s.outStart + ((t - s.start) * fps) / s.speed;
  }
  return null;
}

/** Like srcToOut, but a cut moment snaps to the next kept frame (or the previous one if `before`). */
export function srcToOutClamped(mapped: MappedSegment[], t: number, fps: number, before = false): number {
  const exact = srcToOut(mapped, t, fps);
  if (exact !== null) return exact;
  if (before) {
    for (let i = mapped.length - 1; i >= 0; i--) {
      if (mapped[i].end <= t) return mapped[i].outStart + mapped[i].frames;
    }
    return 0;
  }
  for (const s of mapped) if (s.start >= t) return s.outStart;
  return totalFrames(mapped);
}

export function outToSrc(mapped: MappedSegment[], f: number, fps: number): number | null {
  for (const s of mapped) {
    if (f >= s.outStart && f < s.outStart + s.frames) return s.start + ((f - s.outStart) / fps) * s.speed;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Smoothing. Zooms and layout changes are step functions over output frames;
// averaging them under a Hann window turns every step into an eased transition,
// and turns back-to-back zooms into a pan instead of zoom-out-zoom-in.

export function smooth(f: number, halfWidth: number, sample: (frame: number) => number[]): number[] {
  if (halfWidth < 1) return sample(f);
  let acc: number[] | null = null;
  let total = 0;
  for (let d = -halfWidth; d <= halfWidth; d++) {
    const w = 0.5 + 0.5 * Math.cos((Math.PI * d) / (halfWidth + 1));
    const v = sample(f + d);
    if (!acc) acc = v.map(() => 0);
    for (let i = 0; i < v.length; i++) acc[i] += v[i] * w;
    total += w;
  }
  return acc!.map((x) => x / total);
}

export type OutZoom = { startF: number; endF: number; x: number; y: number; scale: number };

export function zoomsToOut(zooms: Zoom[], mapped: MappedSegment[], fps: number): OutZoom[] {
  return zooms
    .map((z) => ({
      startF: srcToOutClamped(mapped, z.start, fps),
      endF: srcToOutClamped(mapped, z.end, fps, true),
      x: z.x,
      y: z.y,
      scale: z.scale,
    }))
    .filter((z) => z.endF > z.startF)
    .sort((a, b) => a.startF - b.startF);
}

export type Camera = { scale: number; x: number; y: number };

export function cameraAt(f: number, zooms: OutZoom[], halfWidth: number): Camera {
  const [scale, x, y] = smooth(f, halfWidth, (frame) => {
    let hit: OutZoom | undefined;
    for (const z of zooms) if (frame >= z.startF && frame < z.endF) hit = z;
    return hit ? [hit.scale, hit.x, hit.y] : [1, 0.5, 0.5];
  });
  // Keep the zoomed viewport inside the recording.
  const half = 0.5 / Math.max(scale, 1);
  return {
    scale,
    x: Math.min(Math.max(x, half), 1 - half),
    y: Math.min(Math.max(y, half), 1 - half),
  };
}

// ---------------------------------------------------------------------------
// Layouts: where the screen card and the camera sit, per mode.

export type Rect = { x: number; y: number; w: number; h: number; r: number; opacity: number };
export type LayoutBoxes = { screen: Rect; cam: Rect };

const MODES: LayoutMode[] = ["screen", "pip", "side", "camera"];

export function fitRect(area: { x: number; y: number; w: number; h: number }, aspect: number) {
  let w = area.w;
  let h = w / aspect;
  if (h > area.h) {
    h = area.h;
    w = h * aspect;
  }
  return { x: area.x + (area.w - w) / 2, y: area.y + (area.h - h) / 2, w, h };
}

export function layoutBoxes(mode: LayoutMode, plan: Plan): LayoutBoxes {
  const W = plan.output.width;
  const H = plan.output.height;
  const pad = plan.style.padding * H;
  const aspect = plan.source.width / plan.source.height;
  const r = plan.style.radius;
  const full = { x: pad, y: pad, w: W - 2 * pad, h: H - 2 * pad };
  const screenFull = { ...fitRect(full, aspect), r, opacity: 1 };
  const bubble = Math.round(H * 0.24);
  const pipCam = { x: W - pad - bubble, y: H - pad - bubble, w: bubble, h: bubble, r: bubble / 2, opacity: 1 };

  switch (mode) {
    case "screen":
      // Camera shrinks into the bubble spot and fades out.
      return { screen: screenFull, cam: { ...pipCam, w: bubble * 0.6, h: bubble * 0.6, x: pipCam.x + bubble * 0.2, y: pipCam.y + bubble * 0.2, opacity: 0 } };
    case "pip":
      return { screen: screenFull, cam: pipCam };
    case "side": {
      const camW = (W - 3 * pad) * 0.3;
      const screenArea = { x: pad, y: pad, w: W - 3 * pad - camW, h: H - 2 * pad };
      const s = fitRect(screenArea, aspect);
      const camH = Math.min(s.h, camW * (16 / 9));
      return {
        screen: { ...s, r, opacity: 1 },
        cam: { x: W - pad - camW, y: s.y + (s.h - camH) / 2, w: camW, h: camH, r, opacity: 1 },
      };
    }
    case "camera":
      return { screen: { ...screenFull, opacity: 0 }, cam: { ...full, r, opacity: 1 } };
  }
}

export type OutLayout = { startF: number; endF: number; mode: LayoutMode };

export function layoutsToOut(plan: Plan, mapped: MappedSegment[]): OutLayout[] {
  const fps = plan.output.fps;
  return plan.layouts
    .map((l) => ({
      startF: srcToOutClamped(mapped, l.start, fps),
      endF: srcToOutClamped(mapped, l.end, fps, true),
      mode: l.mode,
    }))
    .filter((l) => l.endF > l.startF);
}

function rectToVec(r: Rect): number[] {
  return [r.x, r.y, r.w, r.h, r.r, r.opacity];
}
function vecToRect(v: number[]): Rect {
  return { x: v[0], y: v[1], w: v[2], h: v[3], r: v[4], opacity: v[5] };
}

export function layoutAt(f: number, plan: Plan, ranges: OutLayout[], halfWidth: number): LayoutBoxes {
  const boxes = Object.fromEntries(MODES.map((m) => [m, layoutBoxes(m, plan)])) as Record<LayoutMode, LayoutBoxes>;
  const v = smooth(f, halfWidth, (frame) => {
    let mode = plan.defaultLayout;
    for (const l of ranges) if (frame >= l.startF && frame < l.endF) mode = l.mode;
    const b = boxes[mode];
    return [...rectToVec(b.screen), ...rectToVec(b.cam)];
  });
  return { screen: vecToRect(v.slice(0, 6)), cam: vecToRect(v.slice(6, 12)) };
}
