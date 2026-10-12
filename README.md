# screencast-director

Record your screen, then let Claude edit it. A Screen Studio-style polish (auto-zoom on clicks and typing, sped-up typing, cut dead air, captions, camera bubble and split layouts), but the edit is a JSON file that Claude reads and rewrites from plain-language instructions, and [Remotion](https://www.remotion.dev) renders it.

```
sd record demo --camera     # screen + mic + camera, plus a click/keystroke log
sd auto demo                # transcribe, draft an edit, render projects/demo/out.mp4
claude "/edit-screencast demo cut my retakes and zoom in when I mention the config file"
sd render demo
```

## Why

GUI tools like Screen Studio and [Recordly](https://github.com/webadderallorg/Recordly) do the polish well, but every edit is a drag on a timeline. Headless tools like [screenstudio-alt](https://github.com/connerkward/screenstudio-alternative-skill) are scriptable but don't know what you're saying. This project drives the edit from the **narration**: Whisper word timestamps decide what's a retake, when typing can be sped up (you're not talking), where a zoom belongs ("now look at this button"), and what the captions say.

## macOS app

`macos/` is a native app (Apple silicon, macOS 15+) with the same pipeline and no Node:

- **Record** with ⌃⌥⌘R from any app, or the menu bar button. ScreenCaptureKit records the main display and your mic (the app's own windows stay out of the shot), plus your camera if you turn it on in Settings, plus the click and keystroke log.
- When you stop, it transcribes (whisper.cpp, sharing Followspot's models), drafts a plan, and opens a live preview.
- **Ask Claude** in plain language. The app runs Claude Code headless on the project, and the preview reloads when `plan.json` changes.
- **Export** renders natively with AVFoundation and Core Image. The fixture renders in about 2 s, against 23 s with Remotion.

**Editing by hand.** The editor has a preview, a scrubber timeline and an inspector:

- **Timeline tracks:** Clips (blue is real time, orange is sped up, dashed is cut; click a cut to restore it), Words, Zoom, Layout and Titles. Drag on the ruler to scrub. Select a bar and drag its white handles to trim it; drag zooms, layouts and titles to move them.
- **Inspector:** the Selection tab sets clip speed, zoom level and focus (drag on a frame of the recording), a layout's mode, or a title's text. The Style tab sets split screen, background, padding, corners, zoom speed, captions, overlays and output size.
- **Undo:** ⌘Z undoes any edit, including Claude's.

**Profiles and formats.**

- **Profiles** set a branded look: background, a corner-bracket frame, fonts, caption and title colors, and a logo. Pick one per video in the Style tab, choose a default for new recordings in Settings, or save any video's look as a profile.
  - Profiles live in `~/Library/Application Support/Screencast Director/Profiles/<name>/profile.json` with their fonts and logos. They're kept out of this repo because brand fonts are licensed.
- **Formats:** 16:9, 9:16, 1:1 or 4:5 at 720p to 4K. Vertical, square and feed crop the screen and pan to follow zooms and clicks, with the camera stacked below.
- **Export** renders the current format or any preset (YouTube 4K and 1080p; Shorts, Reels and TikTok; Square; Feed) to its own file without changing the plan. `director render <dir> --preset vertical` does the same headless.

**Keyboard shortcuts** follow Screen Studio's defaults, read from its own action table:

- **Playback:** Space plays, J/K/L shuttle, ← → step a frame (⇧ for a second), ⌘← ⌘→ jump to the start or end.
- **Clips:** C splits, ⌫ removes, X removes back to the previous cut, S changes speed.
- **Zoom and layout:** = and − change the zoom level, ⌘D duplicates a zoom, 1-4 set the camera layout, ⌃L adds a layout.
- **Timeline and export:** ⌘= and ⌘− zoom the timeline, ⌘⇧E exports.
- **Our own additions** (Screen Studio has no default for these): Z adds a zoom, T adds a title.

⌘/ lists them all.

```
macos/build.sh --install     # → /Applications/Screencast Director.app
macos/test.sh                # Swift checks for the timeline math and planner
```

The app needs Screen & System Audio Recording, Microphone, Input Monitoring and (optionally) Camera permission. Builds are signed with a local identity when one exists (Followspot's works), so permissions survive rebuilds. Without a bundled `whisper-cli` (`macos/build-whisper.sh`, needs cmake) it uses Homebrew's (`brew install whisper-cpp`). Projects live in `~/Movies/Screencast Director`, in the same format the CLI uses, and `macos/.build/release/director` runs `analyze`, `plan`, `describe`, `render` and `still` headless.

## How it works

1. **Record** (`sd record`): ffmpeg captures the screen, mic and optionally a camera. A small Swift logger records clicks, keystrokes and cursor moves on the same host clock AVFoundation stamps frames with, so events line up with the video to the frame. Plain typing is logged without characters; only shortcuts like ⌘K are named.
2. **Analyze** (`sd analyze`): mlx-whisper transcribes with word timestamps; ffmpeg measures frame-to-frame screen motion.
3. **Plan** (`sd plan`): writes a first-draft `plan.json`:
   - speech at 1x, filler words ("um", "uh") cut
   - typing without narration at 3x, other mouse work at 1.5x, screen changes (builds, scrolling output) at 4x
   - nothing happening: cut
   - zooms on clusters of clicks and typing, chained into pans when they're close together
4. **Edit**: ask Claude (the `/edit-screencast` skill in this repo), or edit `plan.json` yourself. `sd describe` prints the plan as a timeline with what was said in each part.
5. **Render** (`sd render`) or preview (`sd preview`, Remotion Studio).

### plan.json

All times are seconds in the raw recording.

```jsonc
{
  "segments": [{ "start": 0, "end": 3.4, "speed": 1 }, { "start": 6.5, "end": 9.5, "speed": 3 }],
  "zooms": [{ "start": 6.4, "end": 10.6, "x": 0.75, "y": 0.29, "scale": 2 }],
  "defaultLayout": "pip",                       // screen | pip | side | camera
  "layouts": [{ "start": 0, "end": 4, "mode": "camera" }],
  "callouts": [{ "start": 10, "end": 11.5, "text": "Open the palette" }],
  "captions": { "enabled": true, "maxWords": 7 },
  "style": { "background": ["#1d2b64", "#f8cdda"], "padding": 0.06, "radius": 14, "transition": 0.8 }
}
```

The full schema is in [src/types.ts](src/types.ts).

## Setup (macOS)

- Node 22.18+, ffmpeg, Xcode command line tools (`swiftc`), and [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) (`pip install mlx-whisper`, Apple Silicon).
- `npm install`, then `logger/build.sh`.
- `sd devices` lists screens, mics and cameras; put your choices in `sd.env` (copy `sd.env.example`).
- Permissions for your terminal app (System Settings > Privacy & Security): **Screen Recording**, **Microphone**, **Camera**, and **Input Monitoring** (for the logger).

Already have a recording? `sd import demo ~/Movies/take1.mov` works too; without an input log the draft has no click zooms, so ask Claude to add them from the narration.

## Development

- `npm test`: timeline math and planner rules.
- `test/make-fixture.sh`: builds a synthetic project with speech, idle, typing and motion sections. Its green top bar grows 96 px per source second, so any rendered frame shows which source moment it came from.

## Licensing note

Remotion is free for individuals and companies of up to three people; larger companies need a [company license](https://www.remotion.dev/license).
