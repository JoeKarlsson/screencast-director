// Loads a project's analysis files into plain arrays in source seconds.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { Click, Plan, Shortcut, Word } from "../src/types.ts";

export type Source = {
  video: string;
  width: number;
  height: number;
  duration: number;
  /** Host-clock time of the first video frame (from `sd record`); absent for imports. */
  captureStart?: number;
  camera?: { video: string; offset: number };
};

export type InputEvent = { t: number; type: "move" | "click" | "scroll" | "key"; x: number; y: number; label?: string };

export type Project = {
  dir: string;
  source: Source;
  words: Word[];
  events: InputEvent[];
  /** [time, mean frame-to-frame difference] samples at 10 fps. */
  motion: [number, number][];
};

function readJson<T>(path: string, fallback: T): T {
  return existsSync(path) ? (JSON.parse(readFileSync(path, "utf8")) as T) : fallback;
}

export function loadProject(dir: string): Project {
  const source = readJson<Source | null>(join(dir, "source.json"), null);
  if (!source) throw new Error(`${dir}/source.json missing: run \`sd record\` or \`sd import\` first`);

  type WhisperJson = { segments: { words?: { word: string; start: number; end: number }[] }[] };
  const whisper = readJson<WhisperJson>(join(dir, "transcript.json"), { segments: [] });
  const words = whisper.segments
    .flatMap((s) => s.words ?? [])
    .map((w) => ({ text: w.word.trim(), start: w.start, end: w.end }))
    .filter((w) => w.text.length > 0);

  // Events are on the capture host clock; convert to seconds into the video.
  let events: InputEvent[] = [];
  const evPath = join(dir, "events.jsonl");
  if (existsSync(evPath) && source.captureStart !== undefined) {
    const start = source.captureStart;
    events = readFileSync(evPath, "utf8")
      .split("\n")
      .filter(Boolean)
      .map((l) => JSON.parse(l))
      .filter((e) => e.type !== "meta")
      .map((e) => ({ ...e, t: e.t - start }))
      .filter((e) => e.t >= 0 && e.t <= source.duration);
  }

  const motion = readJson<[number, number][]>(join(dir, "motion.json"), []);
  return { dir, source, words, events, motion };
}

export function clicksOf(p: Project): Click[] {
  return p.events.filter((e) => e.type === "click").map(({ t, x, y }) => ({ t, x, y }));
}

export function shortcutsOf(p: Project): Shortcut[] {
  return p.events
    .filter((e) => e.type === "key" && e.label && /[⌘⌃⌥]/.test(e.label))
    .map((e) => ({ t: e.t, label: e.label! }));
}

export function loadPlan(dir: string): Plan {
  return JSON.parse(readFileSync(join(dir, "plan.json"), "utf8")) as Plan;
}

export function fmt(t: number): string {
  const m = Math.floor(t / 60);
  const s = t - m * 60;
  return `${m}:${s.toFixed(1).padStart(4, "0")}`;
}
