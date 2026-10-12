# screencast-director

Record the screen, then edit by changing a JSON plan. The Swift engine in `macos/` (the app and the `director` CLI) is the main implementation; the Node planner and Remotion renderer are legacy. Claude's job is usually to edit `projects/<name>/plan.json` from the user's instructions (use the `/edit-screencast` skill).

## Layout

- `bin/sd`: the CLI (record, import, analyze, plan, describe, preview, render, auto). analyze/plan/describe/render delegate to `macos/.build/release/director` when it's built; `SD_NODE=1` forces the Node path and `sd render <name> --remotion` renders with Remotion.
- **Legacy (Node):** `scripts/plan.ts`, `scripts/describe.ts`, `src/timeline.ts` and `src/Screencast.tsx` below. Keep them working and `npm test` green, but they don't get new features: easing, motion blur, the smoothed cursor, word snapping, profiles, retakes and script takes are Swift-only.
- `logger/InputLogger.swift`: input logger. Timestamps use `CLOCK_UPTIME_RAW`, the clock AVFoundation stamps frames with; `sd record` reads the first frame's time from ffmpeg's log (`start N`) into `source.json` `captureStart`. Plain typing is logged without characters.
- `scripts/plan.ts`: draft plan rules (speech 1x, typing 3x, mouse 1.5x, screen motion 4x, idle cut, filler words cut, zooms from click/typing clusters). `RULES` holds the thresholds.
- `scripts/describe.ts`: readable timeline with transcript text. Read this before and after editing a plan.
- `src/timeline.ts`: pure mapping and smoothing math, shared by the planner and renderer, unit tested.
- `src/Screencast.tsx`: the Remotion composition.
- `projects/<name>/` (gitignored): `screen.mp4`, `events.jsonl`, `source.json`, `transcript.json`, `motion.json`, `plan.json`, `out.mp4`.

## macOS app (`macos/`)

- `Sources/DirectorCore`: Swift ports of the plan model, `timeline.ts` (Timeline.swift), `plan.ts` (Planner.swift) and `describe.ts`, plus native analysis (motion from decoded frames, whisper-cli → mlx-style transcript.json) and the renderer: `Scene` draws a frame with Core Image + CoreText, `Composition` builds the AVComposition (cuts and speed as edits, muting and fades in an audio mix) with a custom compositor. The same composition feeds the preview player and the export.
- **Two implementations of the same core rules.** A change to the shared planner rules or timeline math in TypeScript needs the same change in Swift (and the reverse); `npm test` and `macos/test.sh` check the same cases. Swift-only features don't need a Node port.
  - Known divergence: the Swift renderer eases the camera asymmetrically (`cameraAt(lead:tail:)`, zooms start 0.3 s early with a 1.6x ease-out tail), adds motion blur during camera moves, draws the smoothed cursor (`cursorHidden` recordings) and snaps word timings to loudness at load (`WordTiming`). The Remotion renderer does none of these; `cameraAt` with default arguments still matches `src/timeline.ts`.
- `Sources/director`: CLI (`analyze`, `plan`, `describe`, `render`, `still`, `debug`). The app bundles it, and `Resources/edit-prompt.md` tells headless Claude to use it (`{{DIRECTOR}}` is replaced with its path).
- `Sources/ScreencastDirector`: the app. ScreenCaptureKit recorder (sample buffers use the host clock, same as `InputTap`'s `CLOCK_UPTIME_RAW`), library, preview, and the Claude box (`claude -p --permission-mode acceptEdits` with only Read/Edit/Write and `director describe`/`still` allowed).
- Build with `macos/build.sh`; Command Line Tools only, so no SwiftUI macros (`@State`): view state lives in `ObservableObject`s.
- SourceKit reports "Cannot find type ... in scope" on single files; ignore it and trust `swift build`.
- An `AVAssetTrack` does not keep its `AVURLAsset` alive. Inserting from a track whose asset was freed fails with the unhelpful -11800/-12780; keep the asset in scope (see `camAsset` in Composition.swift).
- Claude's Edit tool writes `plan.json` in place, which a folder watch misses; the app polls the file's modification date instead.
- Bindings into the plan's arrays (`zooms[i]`) must be bounds-checked (`bindItem` in Inspector.swift): after an undo or delete removes the selected item, SwiftUI can read the old binding once before redrawing, and an out-of-range index kills the app. `commit()` clears a stale selection before publishing the plan for the same reason.
- Editor shortcuts live in `Shortcuts.swift` (Screen Studio's defaults; its action table is `dist/BtdkWdRa.js` and siblings in `app.asar`, keys under `defaultShortcut`). A local key monitor in AppDelegate dispatches them and lets keys through while a text field has focus.
- Driving the UI in tests: timeline bars are accessibility buttons (ordered by position, not by track), so System Events `perform action "AXPress"` selects them; `perform action "AXIncrement"` moves a slider (setting `value` doesn't reach the SwiftUI binding). Always `set frontmost to true` and check it before `keystroke`, or the keys go to whatever app is in front. Use `key code 44` for ⌘/, since `keystroke "/"` is layout-dependent.
- Profiles (`DirectorCore/Look.swift`, `Formats.swift`): `plan.look` holds fonts, colors, the bracket frame and the watermark; `style.screenAspect` crops the screen for vertical, square and feed formats, and `Scene.screenMap` pans the crop to the camera focus (the last click when there's no zoom). The Remotion path ignores both.
- AI providers (`ScreencastDirector/AI.swift`): Claude Code CLI (agentic), the Anthropic Messages API (raw HTTP, since Swift has no SDK; `fallbacks: "default"` with `server-side-fallback-2026-07-01`), or any OpenAI-compatible endpoint. API edits return the complete plan in a json code block, which is parsed, normalized and applied through `apply`, so it can be undone.
- Publishing (`DirectorCore/Publish.swift`): the SRT uses the same caption pages as the burned-in captions. Thumbnails score camera frames with `VNDetectFaceCaptureQualityRequest` plus `CIDetector` smile and blink detection, and cut the person out with `VNGeneratePersonSegmentationRequest`.
- AppleScript `keystroke ","` and `"/"` can map to other keys on non-US keyboard layouts (`","` opened the import panel). Use `key code` or click menu items; the app menu is `menu bar item 2`.
- A SwiftUI `Form` in an `NSWindow` built with `contentRect: .zero` collapses to its title bar. Give the window and the view a real size.
- Tests beyond `macos/test.sh`: `macos/playback-test.sh` plays a composition from a synthetic recording through `AVPlayerItemVideoOutput` and fails on black or missing frames (runs in CI). `macos/smoke-test.sh` builds dist/, launches that copy on a temp fixture (`-projectsFolder`, `-openProject`), and drives the editor through System Events by PID; it needs a GUI session, so it's local only.
- Every composition track must end exactly at the instruction's end. A camera track a few milliseconds long (scaled-range rounding) makes AVPlayer render nothing, black and silent, while `AVAssetImageGenerator` and export still work, so `director still` can't catch it. `buildComposition` trims to the frame count. Test playback with an `AVPlayerItemVideoOutput`, not just stills.
- Window screenshots (`screencapture -l`) of a window on another Space show the player black. Bring the window forward before judging the preview.

## Plan rules that are easy to break

- All plan times are **source seconds** (positions in `screen.mp4`), never output seconds.
- `segments` must be ascending and non-overlapping. Anything not covered is cut.
- Segments with `speed > 1` render muted. Never speed up a segment where the user is talking.
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
