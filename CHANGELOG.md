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
- Getting Started plays a short demo in place of the 3-minute tour.
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
- Ask Claude shows each step as it works (reading the timeline, checking frame 412, editing the plan) and has a Stop button.
- After an AI edit, a list of what it changed: jump to each change, undo just that one, or keep them all.
- The AI knows your playhead, selected item and selected transcript words, so "zoom here" and "cut this" work. The box shows which AI answers, with a Set Up link when it isn't ready.
- What you asked is kept with the recording, so the history is still there after switching recordings.

### Editing
- Playback no longer redraws the whole editor 30 times a second; only the playhead, clock and current transcript word follow it.
- A Claude Code edit is one undo step, however many times it saved the plan, and timeline edits wait until it finishes.
- Dragging a slider saves the plan once you pause instead of on every tick.
- Errors (a failed analysis, preview or save) show as banners, with Retry for the preview.
- ⌫ on a selected cut restores it, as its tooltip says (the toolbar button becomes Restore).
- Edit by text: the Transcript button (⌥⌘T) opens the transcript beside the preview. Drag across words (or shift-click, then ⇧←/⇧→) to select them, then Cut, Zoom, add a Title (or lower third, slate, chapter), Annotate, or Ask AI about them. Find in transcript with match counts, filler words in italics, and the spoken word stays in view while playing.
- The inspector has controls for every motion feature: motion style tiles with live easing curves, a zoom's ease and length, a title's style, second line and in/out animations, an annotation's kind, area (drag on the frame), label and animations, a clip's styled cut, and caption styles. Preview plays from just before the item.
- A Marks track for annotations, a title button that holds lower thirds, slates and chapters, and an Annotate menu (A adds a box).
- Pinch or ⌥-scroll to zoom the timeline around the pointer; the zoom slider and ⌘= / ⌘- keep the playhead in place. The timeline follows the playhead while playing, clicking an empty spot moves the playhead, and ⌥← / ⌥→ nudge the selected item a frame.
- The trim cursor no longer gets stuck after deselecting a bar.
- Clips on the timeline show thumbnails from the recording, and after an AI edit the parts it changed glow briefly (the timeline scrolls to them).
- The timeline has track icons, a color per track, a playhead you can drag on the ruler, and snapping to the playhead and other edges (hold ⌘ to turn it off).
- The inspector has icon tabs (Selection, Background & Frame, Camera, Audio, Cursor & Overlays, Format, Transcript), with controls grouped in cards.

### Motion
- Motion styles (Smooth, Snappy, Cinematic, Bouncy) set how every move in the video eases: zooms, layout changes, and how titles and other overlays come and go. Classic keeps the old look.
- Zooms ease along real curves (or springs), change scale evenly and keep the point they zoom toward still on screen, so a zoom into a corner no longer swings out and back. Each zoom can pick its own ease and speed.
- Titles, shortcut chips and captions animate in and out: fade, fade up, slide, pop, zoom, blur, wipe, word by word or typewriter.
- New title styles: lower third, full-screen slate and chapter card, each with an optional second line.
- Annotations on the screen that follow zooms: spotlight, box with a label, arrow, highlighter and privacy blur.
- Caption styles: karaoke (a box slides behind the word being said), word pop, and bold outlined captions.
- Styled cuts: blur, dip, flash, punch in and whip pan.

### Security
- Claude Code edits can only read the recording's folder, edit plan.json and run the director's describe, still and review. A project folder's own `.claude/` settings and hooks are ignored, and check frames go in the project's `.checks/` folder instead of /tmp.
- YouTube descriptions and recording names from Claude Code run with no tools, from an empty folder.
- What was said and typed in a recording is treated as data, never as instructions. An AI edit that points the recording, camera, music, logos or fonts at a file outside the project is undone, and the reply says so.
- `director still` only writes into the project folder or a temp folder, and won't write through a symlink.
- Shortcut chips only record keys held with ⌘ or ⌃ (⌥ combos type characters, so they stay unlabeled), and nothing is logged while a password field has secure input on.
- Upload links get a random suffix so they can't be guessed, and Settings > Sharing warns when the endpoint isn't HTTPS.
- Releases list the zip's SHA-256 and can be signed with a Developer ID and notarized.

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
