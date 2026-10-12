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

## macOS app (`macos/`)

- `Sources/DirectorCore`: Swift ports of the plan model, `timeline.ts` (Timeline.swift), `plan.ts` (Planner.swift) and `describe.ts`, plus native analysis (motion from decoded frames, whisper-cli → mlx-style transcript.json) and the renderer: `Scene` draws a frame with Core Image + CoreText, `Composition` builds the AVComposition (cuts and speed as edits, muting and fades in an audio mix) with a custom compositor. The same composition feeds the preview player and the export.
- **Two implementations of the same rules.** A change to the planner, timeline math or look in TypeScript needs the same change in Swift (and the reverse). `npm test` and `macos/test.sh` check the same cases.
- `Sources/director`: CLI (`analyze`, `plan`, `describe`, `render`, `still`, `debug`). The app bundles it, and `Resources/edit-prompt.md` tells headless Claude to use it (`{{DIRECTOR}}` is replaced with its path).
- `Sources/ScreencastDirector`: the app. ScreenCaptureKit recorder (sample buffers use the host clock, same as `InputTap`'s `CLOCK_UPTIME_RAW`), library, preview, and the Claude box (`claude -p --permission-mode acceptEdits` with only Read/Edit/Write and `director describe`/`still` allowed).
- Build with `macos/build.sh`; Command Line Tools only, so no SwiftUI macros (`@State`): view state lives in `ObservableObject`s, as in Followspot.
- SourceKit reports "Cannot find type ... in scope" on single files; ignore it and trust `swift build`.
- An `AVAssetTrack` does not keep its `AVURLAsset` alive. Inserting from a track whose asset was freed fails with the unhelpful -11800/-12780; keep the asset in scope (see `camAsset` in Composition.swift).
- Claude's Edit tool writes `plan.json` in place, which a folder watch misses; the app polls the file's modification date instead.
- Bindings into the plan's arrays (`zooms[i]`) must be bounds-checked (`bindItem` in Inspector.swift): after an undo or delete removes the selected item, SwiftUI can read the old binding once before redrawing, and an out-of-range index kills the app. `commit()` clears a stale selection before publishing the plan for the same reason.
- Editor shortcuts live in `Shortcuts.swift` (Screen Studio's defaults; its action table is `dist/BtdkWdRa.js` and siblings in `app.asar`, keys under `defaultShortcut`). A local key monitor in AppDelegate dispatches them and lets keys through while a text field has focus.
- Driving the UI in tests: timeline bars are accessibility buttons (ordered by position, not by track), so System Events `perform action "AXPress"` selects them; `perform action "AXIncrement"` moves a slider (setting `value` doesn't reach the SwiftUI binding). Always `set frontmost to true` and check it before `keystroke`, or the keys go to whatever app is in front. Use `key code 44` for ⌘/, since `keystroke "/"` is layout-dependent.
- Window screenshots (`screencapture -l`) of a window on another Space show the player black. Bring the window forward before judging the preview.

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
