import assert from "node:assert/strict";
import { test } from "node:test";
import { cameraAt, mapSegments, outToSrc, srcToOut, srcToOutClamped, totalFrames, zoomsToOut } from "../src/timeline.ts";
import { buildSegments, buildZooms } from "../scripts/plan.ts";
import type { Project } from "../scripts/project.ts";

const fps = 30;
const segs = [
  { start: 0, end: 2, speed: 1 },
  { start: 5, end: 11, speed: 3 },
  { start: 12, end: 13, speed: 1 },
];

test("segments map to consecutive output frames", () => {
  const m = mapSegments(segs, fps);
  assert.deepEqual(
    m.map((s) => [s.outStart, s.frames]),
    [
      [0, 60],
      [60, 60],
      [120, 30],
    ],
  );
  assert.equal(totalFrames(m), 150);
});

test("source and output times round-trip; cut moments map to null", () => {
  const m = mapSegments(segs, fps);
  assert.equal(srcToOut(m, 8, fps), 90); // 3 s into a 3x segment = 1 s of output
  assert.equal(outToSrc(m, 90, fps), 8);
  assert.equal(srcToOut(m, 3, fps), null);
  assert.equal(srcToOutClamped(m, 3, fps), 60);
  assert.equal(srcToOutClamped(m, 3, fps, true), 60);
  assert.equal(srcToOutClamped(m, 11.5, fps), 120);
});

test("camera rests at the center without zooms and reaches a long zoom's target", () => {
  const m = mapSegments([{ start: 0, end: 10, speed: 1 }], fps);
  assert.deepEqual(cameraAt(10, [], 12), { scale: 1, x: 0.5, y: 0.5 });
  const zooms = zoomsToOut([{ start: 2, end: 8, x: 0.6, y: 0.4, scale: 2 }], m, fps);
  const mid = cameraAt(150, zooms, 12);
  assert.equal(mid.scale, 2);
  assert.ok(Math.abs(mid.x - 0.6) < 1e-9 && Math.abs(mid.y - 0.4) < 1e-9);
  const easing = cameraAt(60, zooms, 12); // exactly at the zoom start: halfway there
  assert.ok(easing.scale > 1.3 && easing.scale < 1.7);
});

test("zoomed viewport is clamped inside the recording", () => {
  const m = mapSegments([{ start: 0, end: 10, speed: 1 }], fps);
  const zooms = zoomsToOut([{ start: 0, end: 10, x: 0.98, y: 0.01, scale: 2 }], m, fps);
  const c = cameraAt(150, zooms, 12);
  assert.equal(c.x, 0.75);
  assert.equal(c.y, 0.25);
});

function project(over: Partial<Project>): Project {
  return {
    dir: "",
    source: { video: "screen.mp4", width: 1920, height: 1080, duration: 12 },
    words: [],
    events: [],
    motion: [],
    ...over,
  };
}

test("planner keeps speech, cuts idle, speeds up typing, drops fillers", () => {
  const p = project({
    words: [
      { text: "Hello", start: 0.5, end: 1.0 },
      { text: "um", start: 1.2, end: 1.5 },
      { text: "there", start: 1.6, end: 2.0 },
      { text: "done", start: 10.0, end: 10.5 },
    ],
    events: Array.from({ length: 15 }, (_, i) => ({ t: 5 + i * 0.2, type: "key" as const, x: 0.5, y: 0.5 })),
  });
  const s = buildSegments(p);
  const at = (t: number) => s.find((x) => t >= x.start && t < x.end);
  assert.equal(at(0.7)?.speed, 1);
  assert.equal(at(1.35), undefined, "filler cut");
  assert.equal(at(3.5), undefined, "idle cut");
  assert.equal(at(6)?.speed, 3, "typing sped up");
  assert.equal(at(10.2)?.speed, 1);
});

test("planner zooms on clicks and hands off between nearby zooms", () => {
  const p = project({
    events: [
      { t: 2, type: "click", x: 0.2, y: 0.2 },
      { t: 3, type: "click", x: 0.8, y: 0.8 },
    ],
  });
  const z = buildZooms(p);
  assert.equal(z.length, 2);
  assert.equal(z[0].end, z[1].start);
  assert.deepEqual([z[1].x, z[1].y], [0.8, 0.8]);
});
