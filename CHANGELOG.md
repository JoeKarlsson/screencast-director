# Changelog

Each release lists what changed for people using the app or the CLI. The version lives in `VERSION`; `macos/release.sh` tags it and publishes the build.

## Unreleased

### Recording
- A floating recording widget: clock, mic level, camera preview, retake count, and Pause, Restart, Discard and Stop. It never shows up in the recording.
- Pause while recording. The paused stretch is cut from the draft.
- A 3-2-1 countdown before recording starts (Settings > Recording; ⌃⌥⌘R during it cancels).
- New Recording (⌘N) picks the display or window, the mic and the camera before you start. ⌃⌥⌘R still records right away.
- Record any connected display, not just the main one.
- The recording widget floats above full-screen apps and other floating windows, and the arrow on its right shrinks it to just the clock and Stop.
- If the recording stops on its own (mic unplugged, window closed), what was recorded is saved and the app says why. Before, the app kept acting as if it were still recording.

### App
- A new look: the app's indigo accent throughout, and a refreshed icon in the layered glass style.
- The start page is a gallery of your recordings with a big New Recording button. Setup folds away once everything's ready, and first-timers see how it works.
- Opening a recording shows a blurred poster with "Loading preview…" instead of a black box.
- The export button shows a progress ring while exports run.
- Smoother transitions when switching recordings and showing or hiding the inspector.
- Badges stay readable on a selected sidebar row.
- A menu bar menu: start, pause, retake, restart or discard a recording, pick the display, mic and camera, and open recent recordings.
- Standard Mac menus and windows: About, Hide, the Window menu, Show/Hide Inspector (⌥⌘I), and Settings split into General, Recording, AI and Sharing tabs.
- The editor's buttons move to the window toolbar; the project's name and length are in the title.
- The preview matches the export's shape (vertical, square) on a dark stage, with play, step and a scrubber under it.
- Sort the library by recently added (the default), oldest first, recently edited, name or length, from the Recordings header or View > Sort Recordings By.
- The library shows a poster frame, length, date and a New or Exported badge. Double-click a name to rename it in place.
- Errors and confirmations show as banners in the window instead of dialogs that block the app.
- Ask Claude: a new prompt box with starter ideas and a history of what you asked and what it changed.

### Editing
- Clips on the timeline show thumbnails from the recording, and after an AI edit the parts it changed glow briefly (the timeline scrolls to them).
- The timeline has track icons, a color per track, a playhead you can drag on the ruler, and snapping to the playhead and other edges (hold ⌘ to turn it off).
- The inspector has icon tabs (Selection, Background & Frame, Camera, Audio, Cursor & Overlays, Format, Transcript), with controls grouped in cards.

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
