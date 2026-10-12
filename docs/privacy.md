# Privacy

Screencast Director works on your Mac. It has no account, no analytics, and no server of its own. This page lists what it records, where that goes, and the few things that can leave your Mac.

## What a recording contains

Each recording is a folder in your projects folder (`~/Movies/Screencast Director` unless you change it in Settings). Everything below stays in that folder:

| File | What it is |
|------|------------|
| `screen.mp4` | The screen (or the one window you picked), with your microphone as its audio track. The app's own windows are left out unless you turn on "Show this app in recordings". |
| `camera.mp4` | Your camera, only when the camera is turned on. |
| `events.jsonl` | Input log: mouse moves, clicks, scrolls and key presses, with times and positions. **Typed characters are never logged.** Plain typing is stored as "a key was pressed"; only shortcut combos (⌘K, ⌃⇧P) get a label, so the editor can show them as on-screen chips. |
| `transcript.json` | What you said, word by word, with timings. |
| `loudness.json`, `motion.json` | Audio levels and how much the screen changes over time, used to find pauses and busy moments. |
| `plan.json` | Your edit: cuts, speeds, zooms, layouts, titles, style. |
| `.history/` | Earlier versions of `plan.json` (the last 30), so you can roll back an edit. |
| `script.md` | Your teleprompter script, only when you record with one open in Followspot. |
| `source.json` | Size, length and timing of the recording. |

Exports (MP4, GIF, captions, thumbnails) go where you save them.

## Transcription is local

Speech is transcribed on your Mac with whisper.cpp. Your audio is never sent anywhere for transcription.

## What can leave your Mac

Only two things, and only when you ask for them:

1. **AI edits and writing help.** When you ask the AI to change an edit, or to write a title, description or chapters, the request goes to the provider you chose in Settings: Claude Code (your Claude login), the Anthropic API, or an OpenAI-compatible endpoint (which can be a local one, such as Ollama). The request contains your instruction, the transcript, a text timeline of the edit and `plan.json`. Claude Code can also render still frames of the edit and look at them, which sends those images to Anthropic. Video and audio files are never sent. API keys are stored in your macOS Keychain.
2. **Uploads you start.** If you upload or share an export, that file goes to the service you picked, and nothing else does.

Nothing is sent in the background.

## Deleting a recording

Move its folder to the Trash in Finder (in the editor, ⌘⇧O shows it). That removes the video, audio, camera, input log, transcript and plan history together, because they all live in that one folder. Exports you saved elsewhere aren't touched; delete those separately.
