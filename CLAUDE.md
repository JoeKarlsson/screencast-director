# screencast-director

Record the screen, then edit by changing a JSON plan that Remotion renders. Claude's job is usually to edit `projects/<name>/plan.json` from Joe's instructions (use the `/edit-screencast` skill).

## Layout

- `bin/sd`: the CLI (record, import, analyze, plan, describe, preview, render, auto).
- `logger/InputLogger.swift`: input logger. Timestamps use `CLOCK_UPTIME_RAW`, the clock AVFoundation stamps frames with; `sd record` reads the first frame's time from ffmpeg's log (`start N`) into `source.json` `captureStart`. Plain typing is logged without characters.
- `scripts/plan.ts`: draft plan rules (speech 1x, typing 3x, mouse 1.5x, screen motion 4x, idle cut, filler words cut, zooms from click/typing clusters). `RULES` holds the thresholds.
- `scripts/describe.ts`: readable timeline with transcript text. Read this before and after editing a plan.
- `src/timeline.ts`: pure mapping and smoothing math, shared by the planner and renderer, unit tested.
- `src/Screencast.tsx`: the Remotion composition.
- `projects/<name>/` (gitignored): `screen.mp4`, `events.jsonl`, `source.json`, `transcript.json`, `motion.json`, `plan.json`, `out.mp4`.

## Plan rules that are easy to break

- All plan times are **source seconds** (positions in `screen.mp4`), never output seconds.
- `segments` must be ascending and non-overlapping. Anything not covered is cut.
- Segments with `speed > 1` render muted. Never speed up a segment where Joe is talking.
- Zooms that touch hand off as a pan; a gap shorter than `style.transition` reads as a quick out-and-in.
- `zoom.x`/`zoom.y` are 0..1 fractions of the recorded screen; scale 1.4 to 2.2 looks natural.
- `sd plan` refuses to overwrite an existing `plan.json` (it may hold edits); `--force` regenerates.

## Verifying an edit

- `bin/sd describe <name>` to check the timeline reads right.
- Spot-check frames instead of rendering the whole video:
  `npx remotion still Screencast /tmp/f.png --frame=<n> --props=$(node scripts/props.ts projects/<name>) --public-dir=projects/<name> --scale=0.5`
- `npm test` covers the timeline math and planner rules. `test/make-fixture.sh` builds a synthetic project (`projects/fixture`) whose green top bar grows 96 px per source second, so frame mapping can be read off any rendered frame.

## Gotchas

- Remotion `trimBefore` is in source frames and is not scaled by `playbackRate` (verified on the fixture).
- The Homebrew ffmpeg here has no `drawtext`; `drawbox` sizes and positions don't animate. Animate with `overlay` expressions.
- `freezedetect` compares against the first frame of a freeze, so slow changes break it; motion uses frame-to-frame difference (`tblend` + `signalstats`) instead.
- Node runs the `.ts` scripts directly (type stripping), so relative imports need the `.ts` extension and Node 22 lacks `import.meta.main`.
