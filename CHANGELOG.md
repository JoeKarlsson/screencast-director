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
- Space plays and pauses even after you've sent a Claude edit (the box keeps focus but is empty), and clicking the preview or timeline takes focus out of a text field so the shortcuts work again.
- Zooming the timeline (slider, pinch, ⌥-scroll, ⌘= / ⌘-) keeps the playhead where it is, and centers it if it was scrolled out of view, instead of drifting ahead while you drag the slider.
- An AI edit no longer shows "Claude is editing…" forever. Each reply goes to the request it answers, an edit that fails says why (Claude Code's own error, like being signed out), and one that finishes silently says so. Quitting the app stops a Claude edit still running instead of leaving it changing your plan in the background. Old edits stuck this way now say they didn't finish.
- Zooming the timeline all the way out shows the whole timeline, however long the video is, and it stays fitted when the window or the edit's length changes.
- When the timeline is zoomed out too far to read words, the Words row marks where you speak instead of going blank.
- The timeline starts in output time, so cuts close up and sped-up clips draw at their real length. Clips show their frames in both modes; the toggle by Fit switches back to the whole recording.
- An unanalyzed recording shows a labeled Analyze button in the toolbar and in the inspector.
- The X on a banner is easier to hit. Before, only a click right on the X closed it.
- Move a recording to the Trash from its right-click menu in the sidebar or on Home.
- Claude edits can run `director describe`, `still` and `review` again. The app's path has spaces, so the quoted command Claude ran didn't match its allow rule and was blocked.
- Claude Code is found when it is installed in ~/.local/bin and only .zshrc adds that folder to PATH. Before, the app said Claude Code wasn't installed.
- Renaming a recording while it's analyzing or exporting waits until it's done, then renames it, even if you've clicked away to another recording. Before, the rename broke the analysis with "The folder motion.json doesn't exist".
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
- The AI knows what you clicked: analysis reads the text around each click on screen (on-device, with Apple's Vision), so the timeline says `click on "Settings…"` and zooms say what they're aimed at. Older recordings get it before their first AI edit, or with `director screentext`.
- With a script, the timeline lists script lines the edit is missing (never said, or every take cut), so the AI can restore a take or tell you.
- New starter ideas in the Ask box: chapter cards, a lower third with your name, boxing what you click, blurring emails and keys, a cinematic feel.
- What you asked is kept with the recording, so the history is still there after switching recordings.

### Editing
- Animations: Vox-style explainers with real app logos, stickers that pop in, hand-drawn lines and highlighter, timed to what you say. Two templates to start (One at a Time: wiring apps up one by one until it's a mess; One Hub: one connection that fans out to all of them). Add one with the ✦ button over your in/out range, the selected words, or from the playhead. Edit its heading, logos, apps and labels in the inspector, and set each beat to the playhead, or press Fill In From What I Say and Claude writes it from your words. They have their own Animations row on the timeline, render by themselves when you change them, and move with their beats when you drag them.
- Storyboard animations: build any diagram step by step, each step on a word. Show a logo, dot, card or label, connect them, add a note, count something up, highlight, dim or hide, tangle the lines, circle the board, or clear to a new board. Steps are edited in the inspector.
- Each video keeps its own copy of the animation templates it uses, so changing a template later never changes a finished video. Update Template takes the latest on purpose; Save to My Templates puts a video's version in your library (~/Library/Application Support/Screencast Director/Animations) for other videos. Templates and logos made for one video live in its animations folder.
- Camera > Bubble adjusts the camera bubble while you demo: drag it anywhere in the preview, or set its size, position (or snap it to a corner), shape (circle, rounded, square), border and shadow.
- Cut out background: show just you over the screen, with no circle, using on-device person segmentation. In a bottom corner the cutout stands on the frame's edge.
- The background cutout shows your whole upper body. Before, the bubble's square edges and the camera zoom sliced off your shoulders and arms.
- The background cutout only applies to the camera bubble over your screen. Full-camera stretches keep your room behind you, and it fades back in as the camera grows to full screen.
- Chapter cards darken the video behind them more, so the title reads over a busy screen.
- The camera stays in sync with your voice. After a recording, the app compares your lips with the audio and lines the camera up. Some webcams deliver frames late, which put the camera a third of a second behind. Camera > Lip sync has a slider to adjust it by hand and a Sync to My Voice button; the CLI has `director sync-camera`.
- Camera punch-ins (`camera.punchIns` in the plan): the camera snaps tighter on your face for a beat, then snaps back, for punctuation on a key line.
- Pause trimming drops clips stranded between cuts: anything under a second, or under two seconds and mostly silence. The cut runs on to where you start talking again, instead of flickering through a stray word or a sliver of silence.
- In a narrated recording, the draft cuts silent scrolling and pointing longer than 3 seconds instead of keeping it at 1.5x. Shorter moves, and recordings with no narration, still play at 1.5x.
- Playback no longer redraws the whole editor 30 times a second; only the playhead, clock and current transcript word follow it.
- A Claude Code edit is one undo step, however many times it saved the plan, and timeline edits wait until it finishes.
- Dragging a slider saves the plan once you pause instead of on every tick.
- Errors (a failed analysis, preview or save) show as banners, with Retry for the preview.
- ⌫ on a selected cut restores it, as its tooltip says (the toolbar button becomes Restore).
- Edit by text: the Transcript button (⌥⌘T) opens the transcript beside the preview. Drag across words (or shift-click, then ⇧←/⇧→) to select them, then Cut, Zoom, add a Title (or lower third, slate, chapter), Annotate, or Ask AI about them. Find in transcript with match counts, filler words in italics, and the spoken word stays in view while playing.
- The inspector has controls for every motion feature: motion style tiles with live easing curves, a zoom's ease and length, a title's style, second line and in/out animations, an annotation's kind, area (drag on the frame), label and animations, a clip's styled cut, and caption styles. Preview plays from just before the item.
- A Marks track for annotations, a title button that holds lower thirds, slates and chapters, and an Annotate menu (A adds a box).
- Pinch or ⌥-scroll to zoom the timeline around the pointer; the zoom slider and ⌘= / ⌘- keep the playhead in place. The timeline follows the playhead while playing, clicking an empty spot moves the playhead, and ⌥← / ⌥→ nudge the selected item a frame.
- A strip under the scrubber shows the finished video's shape: real-time clips in blue, sped-up parts in orange, titles as ticks and zooms underlined.
- Transport buttons have VoiceOver labels.
- Select several items: ⇧- or ⌘-click bars, drag a box over empty track space, or ⌘A. Drag any of them, or press ⌥← / ⌥→, to move them together; ⌫ removes them all.
- Markers: M drops one at the playhead, ; and ' jump between them, and you can name them in the inspector. The AI sees them, so "zoom in after the intro marker" works.
- In and out: I and O mark a range, then cut it, speed it up, zoom it, title it, annotate it or ask the AI about it from the timeline toolbar. ⌥X clears it.
- Output time: a timeline toggle lays the timeline out like the finished video. Cuts collapse, sped-up clips shrink to their real length, and the ruler counts output time; editing works the same.
- Clicking any empty spot on the timeline now moves the playhead (only the top strip of the tracks responded before).
- The trim cursor no longer gets stuck after deselecting a bar.
- Fixed a hang at the end of an AI edit: pipeline steps now run on the main thread, so they never update the window from the background.
- Clips on the timeline show thumbnails from the recording, and after an AI edit the parts it changed glow briefly (the timeline scrolls to them).
- The timeline has track icons, a color per track, a playhead you can drag on the ruler, and snapping to the playhead and other edges (hold ⌘ to turn it off).
- The inspector has icon tabs (Selection, Background & Frame, Camera, Audio, Cursor & Overlays, Format, Transcript), with controls grouped in cards.
- Sound effects: `sfx` in plan.json plays a whoosh, pop or ding at a moment in the recording, at full volume over the voice. Ask Claude to add them; the Audio tab lists them and removes them, and `describe` shows where each lands (or that it's cut).
- Captions skip words in sped-up stretches. Those play muted, so their words showed up on screen without being heard.

### Motion
- A video that opens (or ends) on the full camera starts and stays there, instead of easing in from the bubble over the first frames.
- The camera bubble's border no longer draws over a full-frame animation.
- Two parts of one animation that meet across a cut play straight through, instead of fading out and in with your face and the screen flashing between them.
- The cursor, click ripples, shortcut chips and annotations no longer draw over a full-frame animation.
- A B-roll or animation clip a little shorter than its slot holds its last frame, instead of flashing its first frame at the end.
- `describe` warns when the full-camera layout hides clicks or typing, so a demo can't end up behind your face.
- Motion styles (Smooth, Snappy, Cinematic, Bouncy) set how every move in the video eases: zooms, layout changes, and how titles and other overlays come and go. Classic keeps the old look.
- Zooms ease along real curves (or springs), change scale evenly and keep the point they zoom toward still on screen, so a zoom into a corner no longer swings out and back. Each zoom can pick its own ease and speed.
- Titles, shortcut chips and captions animate in and out: fade, fade up, slide, pop, zoom, blur, wipe, word by word or typewriter.
- New title styles: lower third, full-screen slate and chapter card, each with an optional second line.
- Annotations on the screen that follow zooms: spotlight, box with a label, arrow, highlighter and privacy blur.
- Caption styles: karaoke (a box slides behind the word being said), word pop, and bold outlined captions.
- Styled cuts: blur, dip, flash, punch in and whip pan.
- Crossfades: a cut can dissolve between the two clips (a quarter second each side) without changing the video's length.
- B-roll: show a picture or clip over part of the video, inside the screen card or over the whole frame, with the same entrances and exits. The B-roll button copies the file into the project's broll/ folder.

### Security
- Headless Claude edits no longer load your personal Claude Code settings either, so your own allow rules can't let an edit run commands beyond the three `director` checks.
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
