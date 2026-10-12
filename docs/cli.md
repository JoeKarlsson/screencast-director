# CLI

The `sd` CLI records with ffmpeg and runs the rest of the pipeline from the terminal.

## Which engine runs

When the Swift `director` is built (`macos/build.sh`, or `swift build -c release --package-path macos`), `sd analyze`, `plan`, `describe` and `render` hand off to it. That's the same engine as the macOS app: whisper.cpp transcription, word timings snapped to the audio, eased zooms with motion blur, the smoothed cursor, profiles, retake marks and script takes, rendered with AVFoundation.

Without it, or with `SD_NODE=1`, they use the **legacy Node path**: mlx-whisper, the TypeScript planner (`scripts/plan.ts`, `src/timeline.ts`) and [Remotion](https://www.remotion.dev). The Node planner and Remotion renderer are kept working and tested, but new features land in Swift only. `sd render <name> --remotion` renders one project with Remotion while everything else uses Swift, which is useful when you want custom React motion graphics. `sd preview` always opens Remotion Studio.

## Setup

- Node 22.18+, ffmpeg, Xcode Command Line Tools (`swiftc`), and either `macos/build.sh` with whisper.cpp (`brew install whisper-cpp`), or for the legacy path [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) (`pip install mlx-whisper`, Apple silicon).
- `npm install`, then `logger/build.sh`.
- `bin/sd devices` lists screens, mics and cameras. Put your choices in `sd.env` (copy `sd.env.example`).
- Give your terminal app these permissions (System Settings > Privacy & Security): **Screen Recording**, **Microphone**, **Camera**, and **Input Monitoring** (for the logger).

## Pipeline

1. **Record** (`sd record <name>`): ffmpeg captures the screen, mic and optionally a camera. A small Swift logger records clicks, keystrokes and cursor moves on the same clock AVFoundation stamps frames with, so events line up with the video to the frame. Plain typing is logged without characters; only shortcuts like ⌘K are named.
2. **Analyze** (`sd analyze`): transcribes with word timestamps (whisper.cpp, or mlx-whisper on the legacy path) and measures frame-to-frame screen motion.
3. **Plan** (`sd plan`): writes a first-draft `plan.json`:
   - speech at 1x, filler words ("um", "uh") cut
   - typing without narration at 3x, other mouse work at 1.5x, screen changes (builds, scrolling output) at 4x
   - nothing happening: cut
   - zooms on clusters of clicks and typing, chained into pans when they're close together
4. **Edit**: ask Claude with the `/edit-screencast` skill in this repo, or edit `plan.json` yourself. `sd describe` prints the plan as a timeline with what was said in each part.
5. **Render** (`sd render`, or `sd render <name> --remotion` for Remotion) or preview in Remotion Studio (`sd preview`).

`sd auto <name>` runs analyze, plan and render in one go.

## Importing a recording

```sh
bin/sd import demo ~/Movies/take1.mov
```

Without an input log the draft has no click zooms, so ask Claude to add them from the narration.
