# macOS app

`macos/` is a native app (Apple silicon, macOS 15+) with the same pipeline as the CLI and no Node.

## Install

```sh
brew install whisper-cpp        # or bundle your own: macos/build-whisper.sh (needs cmake)
macos/build.sh --install        # builds /Applications/Screencast Director.app
macos/test.sh                   # Swift checks for the timeline math and planner
```

The app asks for **Screen & System Audio Recording**, **Microphone**, **Input Monitoring** and, optionally, **Camera** permission. Builds are signed with a local code-signing identity when one exists, so permissions survive rebuilds.

Projects live in `~/Movies/Screencast Director`, in the same format the CLI uses.

## Record

Press ⌃⌥⌘R from any app, or use the menu bar button. ScreenCaptureKit records the main display and your mic (the app's own windows stay out of the shot), your camera if you turn it on in Settings, and a click and keystroke log.

When you stop, the app transcribes with whisper.cpp, drafts a plan and opens a live preview.

## Edit

- **Ask the AI** in plain language. The preview reloads when `plan.json` changes.
- **Timeline tracks:** Clips (blue is real time, orange is sped up, dashed is cut; click a cut to restore it), Words, Zoom, Layout and Titles. Drag on the ruler to scrub. Select a bar and drag its handles to trim it; drag zooms, layouts and titles to move them.
- **Inspector:** the Selection tab sets clip speed, zoom level and focus (drag on a frame of the recording), a layout's mode, or a title's text. The Style tab sets split screen, background, padding, corners, zoom speed, captions, overlays and output size.
- **Undo:** ⌘Z undoes any edit, including the AI's.

## Profiles and formats

- **Profiles** set a branded look: background, a corner-bracket frame, fonts, caption and title colors, and a logo. Pick one per video in the Style tab, choose a default in Settings, or save any video's look as a profile. Profiles live in `~/Library/Application Support/Screencast Director/Profiles/<name>/` with their fonts and logos.
- **Formats:** 16:9, 9:16, 1:1 or 4:5 at 720p to 4K. Vertical, square and feed crop the screen and pan to follow zooms and clicks, with the camera stacked below.
- **Export** renders the current format or any preset (YouTube 4K and 1080p; Shorts, Reels and TikTok; Square; Feed) to its own file without changing the plan.

## AI editing (Settings > AI editing)

- **Claude Code** (default): uses your Claude login, so no API key. It can run `director describe` and `still` to check its own work.
- **Anthropic API:** your key, stored in the Keychain.
- **Any OpenAI-compatible endpoint:** OpenRouter, OpenAI, a gateway such as LiteLLM, or Ollama. Fill in the base URL, model and an optional key.

The API providers send the timeline, transcript and plan in one request and get back the whole updated plan.

## Publish

**Publish…** in the editor writes into `publish/` in the recording's folder:

- `captions.srt`, timed to the edited video
- `chapters.txt`, from your titles (YouTube needs at least three, each at least 10 s long)
- `transcript.txt` with timestamps
- `description.md`: title options, a description, chapters and tags, drafted by your AI provider
- `thumbnail-N.png`: the clearest smiling camera frames, with you cut out of the background next to the screen and the title in your profile's style

## Keyboard shortcuts

They follow Screen Studio's defaults. ⌘/ lists them all.

| Area | Keys |
|---|---|
| Playback | Space plays, J/K/L shuttle, ← → step a frame (⇧ for a second), ⌘← ⌘→ jump to start or end |
| Clips | C splits, ⌫ removes, X removes back to the previous cut, S changes speed |
| Zoom and layout | = and − change zoom level, ⌘D duplicates a zoom, 1-4 set the camera layout, ⌃L adds a layout |
| Timeline and export | ⌘= and ⌘− zoom the timeline, ⌘⇧E exports |
| Additions | Z adds a zoom, T adds a title |

## Headless

`macos/.build/release/director` runs `analyze`, `plan`, `describe`, `render`, `still` and `publish` without the UI:

```sh
director render <project-dir> --preset vertical
director publish <project-dir> --title "My demo"
```
