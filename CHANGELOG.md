# Changelog

Each release lists what changed for people using the app or the CLI. The version lives in `VERSION`; `macos/release.sh` tags it and publishes the build.

## Unreleased

## 0.2.0 (2026-10-12)

The first tagged release. Everything runs on the native Swift engine.

### Recording
- Record the whole screen or one window, with mic and camera. ⌃⌥⌘R starts and stops from any app.
- ⌃⌥⌘M marks a retake: the line you just said is cut and the redo stays. FollowSpot scripts keep only the last take of each line.
- Record without the real cursor and draw a smoothed one from the mouse log.

### Editing
- Claude drafts the edit: talking stays at 1x, typing and waiting speed up, dead air and filler words are cut, and clicks get zooms. Claude checks its own zooms and cuts.
- Ask for edits in plain language with Claude Code (no API key), the Anthropic API, or any OpenAI-compatible endpoint.
- Timeline with clips, audio waveform, words, zooms, layouts and titles; an inspector; Screen Studio keyboard shortcuts; undo and plan history.
- Pause trimming (gentle, normal, tight), with word timings snapped to the measured audio.
- Edit the transcript to cut words.
- Join several recordings into one project.

### Look and sound
- Profiles with your background, fonts, colors, logo and frame, full bleed or padded.
- Intro and outro cards in the profile's look.
- Camera bubble, side by side or full frame, centered on your face, with reframing and color grading.
- Zooms ease in early with a long tail and motion blur.
- Voice normalizing, volume, a limiter, Apple voice isolation, and background music that ducks under speech.

### Export and sharing
- 16:9, 9:16, 1:1 and 4:5 at 720p to 4K, with presets, in a background export queue.
- SRT captions, chapters, an AI-drafted description and smiling-face thumbnails.
- GIF export for docs, and Upload and Copy Link to any S3-compatible bucket.

### Under the hood
- The `sd` CLI always runs the Swift `director`. The Node planner and Remotion renderer are gone.
- CI runs SwiftLint, ShellCheck, the checks and a headless playback test; `macos/smoke-test.sh` drives the app locally.
- [docs/privacy.md](docs/privacy.md) explains what's recorded and what can leave your Mac.

## 0.1.0

The untagged prototype: an ffmpeg recorder, a Node planner and a Remotion renderer.
