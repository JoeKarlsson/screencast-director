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

There's no telemetry, no crash reporting and no update check. This is every network call the app and `director` make, and what starts each one:

1. **AI edits and writing help.** When you ask the AI to change an edit, or to write a title, description or chapters, the request goes to the provider you chose in Settings: Claude Code (your Claude login), the Anthropic API, or an OpenAI-compatible endpoint (which can be a local one, such as Ollama). The request contains your instruction, the transcript, a text timeline of the edit and `plan.json`. Claude Code can also render still frames of the edit and look at them, which sends those images to Anthropic. Video and audio files are never sent. API keys are stored in your macOS Keychain.
2. **Automatic names.** With **Name them from what you said** on (Settings, on by default), each new recording's transcript (up to its first 6,000 characters) goes to the same AI provider once, to suggest a name. Turn it off and transcripts only leave when you ask the AI for something.
3. **Uploads you start.** **Upload and Copy Link** (or `director upload`) sends the one file you pick to the S3-compatible bucket set in Settings > Sharing (its keys are in your Keychain), and nothing else goes with it.
4. **Stock searches and downloads.** `director stock`, run by you or by Claude in the Claude box when an edit needs B-roll, a sound or a GIF, sends the search words to Openverse, NASA's image library, Wikimedia Commons and the Internet Archive (archive.org). KLIPY is searched only when you've added your own key in Settings > Stock (kept in the Keychain) or set `KLIPY_API_KEY`. Downloading a result fetches the file from where that source says it's hosted.
5. **Capturing a website.** `director capture <dir> <url>` opens that page in an offscreen web view, the way a browser would (including the page's own scripts and requests), and downloads its logo.
6. **The Whisper model.** Getting Started gives you a `curl` command that downloads the model from Hugging Face. You run it; the app doesn't fetch it on its own.

Animations render on a page with no network access, and installing a pack makes no network calls.

## Deleting a recording

Move its folder to the Trash in Finder (in the editor, ⌘⇧O shows it). That removes the video, audio, camera, input log, transcript and plan history together, because they all live in that one folder. Exports you saved elsewhere aren't touched; delete those separately.
