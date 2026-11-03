# CLI

The `sd` CLI runs the editing pipeline from the terminal on a recording made in the app, or one you import. `sd analyze`, `plan`, `describe` and `render` run the Swift `director`, the same engine as the macOS app, rebuilding it first when its sources changed. Everything `sd` can't do (stills, publish, GIF, join, upload) is a `director` command; run `macos/.build/release/director` with no arguments for the list.

## Setup

- ffmpeg, whisper.cpp (`brew install ffmpeg whisper-cpp`) and the Xcode Command Line Tools, on Apple silicon.

## Pipeline

1. **Record** in the app (or `sd import` a video). The app logs clicks, keystrokes and cursor moves on the same clock the screen recording stamps frames with, so events line up with the video to the frame. Plain typing is logged without characters; only shortcuts like ⌘K are named.
2. **Analyze** (`sd analyze`): transcribes with word timestamps (whisper.cpp) and measures frame-to-frame screen motion.
3. **Plan** (`sd plan`): writes a first-draft `plan.json`:
   - speech at 1x, filler words ("um", "uh") cut
   - typing without narration at 3x, other mouse work at 1.5x, screen changes (builds, scrolling output) at 4x
   - nothing happening: cut
   - zooms on clusters of clicks and typing, chained into pans when they're close together
4. **Edit**: ask Claude with the `/edit-screencast` skill in this repo, or edit `plan.json` yourself. `sd describe` prints the plan as a timeline with what was said in each part.
5. **Render** (`sd render`), or open the project in the app to preview it.

`sd auto <name>` runs analyze, plan and render in one go.

## Importing a recording

```sh
bin/sd import demo ~/Movies/take1.mov
```

Without an input log the draft has no click zooms, so ask Claude to add them from the narration.
