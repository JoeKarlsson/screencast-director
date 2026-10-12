// Bundles plan.json with the transcript and input events into the props file Remotion renders.
//
//   node scripts/props.ts <projectDir>   -> <projectDir>/.render/props.json

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { RenderProps } from "../src/types.ts";
import { clicksOf, loadPlan, loadProject, shortcutsOf } from "./project.ts";

const dir = process.argv[2];
if (!dir) {
  console.error("usage: node scripts/props.ts <projectDir>");
  process.exit(64);
}

const project = loadProject(dir);
const props: RenderProps = {
  plan: loadPlan(dir),
  words: project.words,
  clicks: clicksOf(project),
  shortcuts: shortcutsOf(project),
};

mkdirSync(join(dir, ".render"), { recursive: true });
const out = join(dir, ".render", "props.json");
writeFileSync(out, JSON.stringify(props));
console.log(out);
