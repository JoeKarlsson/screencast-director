// Prints the plan as a readable timeline: every kept and cut range with what was said,
// plus zooms, layouts and callouts. This is what Claude reads before editing plan.json.
//
//   node scripts/describe.ts <projectDir>

import { mapSegments, totalFrames } from "../src/timeline.ts";
import type { Word } from "../src/types.ts";
import { fmt, loadPlan, loadProject } from "./project.ts";

const dir = process.argv[2];
if (!dir) {
  console.error("usage: node scripts/describe.ts <projectDir>");
  process.exit(64);
}

const project = loadProject(dir);
const plan = loadPlan(dir);
const fps = plan.output.fps;
const mapped = mapSegments(plan.segments, fps);

function said(start: number, end: number, words: Word[]): string {
  const text = words
    .filter((w) => w.start < end && w.end > start)
    .map((w) => w.text)
    .join(" ");
  return text ? `"${text}"` : "";
}

function activity(start: number, end: number): string {
  const ev = project.events.filter((e) => e.t >= start && e.t < end);
  const keys = ev.filter((e) => e.type === "key").length;
  const clicks = ev.filter((e) => e.type === "click").map((e) => `click@${fmt(e.t)}(${e.x.toFixed(2)},${e.y.toFixed(2)})`);
  const shortcuts = ev.filter((e) => e.type === "key" && e.label).map((e) => e.label);
  const parts = [];
  if (keys) parts.push(`${keys} keys`);
  parts.push(...clicks);
  if (shortcuts.length) parts.push(shortcuts.join(" "));
  return parts.length ? `[${parts.join(", ")}]` : "";
}

const lines: string[] = [];
const outLen = totalFrames(mapped) / fps;
lines.push(`# ${dir}`);
lines.push(`source ${fmt(plan.source.duration)} -> output ${fmt(outLen)} at ${plan.output.width}x${plan.output.height}@${fps}`);
lines.push("");
lines.push("## Timeline (source times; out = position in the final video)");

let cursor = 0;
for (const s of mapped) {
  if (s.start - cursor > 0.05) {
    lines.push(`  CUT  src ${fmt(cursor)}-${fmt(s.start)} ${said(cursor, s.start, project.words)} ${activity(cursor, s.start)}`.trimEnd());
  }
  const speed = s.speed === 1 ? "1x " : `${s.speed}x`;
  lines.push(
    `  ${speed}  src ${fmt(s.start)}-${fmt(s.end)}  out ${fmt(s.outStart / fps)}  (${s.note ?? ""}) ${said(s.start, s.end, project.words)} ${activity(s.start, s.end)}`.trimEnd(),
  );
  cursor = s.end;
}
if (plan.source.duration - cursor > 0.05) lines.push(`  CUT  src ${fmt(cursor)}-${fmt(plan.source.duration)}`);

lines.push("");
lines.push("## Zooms");
if (!plan.zooms.length) lines.push("  (none)");
plan.zooms.forEach((z, i) =>
  lines.push(`  #${i} src ${fmt(z.start)}-${fmt(z.end)} at (${z.x}, ${z.y}) x${z.scale} ${z.note ?? ""} ${said(z.start, z.end, project.words)}`.trimEnd()),
);

lines.push("");
lines.push(`## Layout: default "${plan.defaultLayout}"${plan.camera ? "" : " (no camera recorded)"}`);
plan.layouts.forEach((l) => lines.push(`  src ${fmt(l.start)}-${fmt(l.end)} ${l.mode} ${l.note ?? ""}`.trimEnd()));

if (plan.callouts.length) {
  lines.push("");
  lines.push("## Callouts");
  plan.callouts.forEach((c) => lines.push(`  src ${fmt(c.start)}-${fmt(c.end)} "${c.text}"`));
}

console.log(lines.join("\n"));
