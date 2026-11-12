# CLI

The `sd` CLI runs the editing pipeline from the terminal on a recording made in the app, or one you import. `sd analyze`, `plan`, `draft`, `describe` and `render` run the Swift `director`, the same engine as the macOS app, rebuilding it first when its sources changed. Everything `sd` can't do (stills, contact sheets, publish, GIF, join, upload) is a `director` command; run `bin/director` (which rebuilds it when its sources changed) with no arguments for the list, and `bin/director validate <dir>` to find what's wrong with a plan.

## Setup

- ffmpeg, whisper.cpp (`brew install ffmpeg whisper-cpp`) and the Xcode Command Line Tools, on Apple silicon.

## Pipeline

1. **Record** in the app (or `sd import` a video). The app logs clicks, keystrokes and cursor moves on the same clock the screen recording stamps frames with, so events line up with the video to the frame. Plain typing is logged without characters; only shortcuts like ⌘K are named.
2. **Analyze** (`sd analyze`): transcribes with word timestamps (whisper.cpp) and measures frame-to-frame screen motion.
3. **Plan** (`sd plan`): writes a first-draft `plan.json`:
   - speech at 1x, filler words ("um", "uh") cut
   - typing without narration at 3x, other mouse work at 1.5x, screen changes (builds, scrolling output) at 4x
   - nothing happening: cut
   - zooms on clusters of clicks and typing (as many as one zoomed view can show), chained into pans when they're within 1.5 s, none in the first 2.5 s and none for the click that stops the recording

   `sd draft` is the draft the app makes after recording: the plan above, then your default profile, pause level and voice polish (the app's settings), the camera centered on your face and lined up with your voice.
4. **Edit**: ask Claude with the `/edit-screencast` skill in this repo, or edit `plan.json` yourself. `sd describe` prints the plan as a timeline with what was said in each part.
5. **Render** (`sd render`), or open the project in the app to preview it.

`sd auto <name>` runs analyze, draft and render in one go.

## Everything the app does, from the terminal or an agent

Edits are `plan.json` changes. The app checks the file every second, so an edit made outside it shows up in the open editor, and ⌘Z undoes it. Everything else has a `director` command, and recording, which only the running app can do, has a link:

| In the app | From the terminal |
|---|---|
| Timeline, inspector, transcript and Claude box edits | edit `plan.json`, then `director validate <dir>`; `director cut`, `restore`, `move`, `repeat`, `pauses` |
| Start Over from a Fresh Draft | `director draft <dir> --force` |
| Claude box › Rewind to before this ask | `director asks <dir>` (numbered), `director asks <dir> rewind <n>` |
| Camera › Center on face, Lip sync | `director frame-camera`, `sync-camera` |
| Apply a profile, Save This Look as a Profile | `director profile <dir> <name>`, `profile-save <dir> <name> [--music] [--voice] [--camera]`, `profiles` |
| Install a Pack, Export Profiles as a Pack | `director pack install <folder or .sdpack> [--replace]`, `pack export <out[.sdpack]> --profile <name>... [--work]`, `pack list`, `pack remove <name>` |
| The Animations theme choices | `director themes [dir]` |
| An animation's live preview while paused | `director animate-preview <dir>`: one JSON request a line on stdin (`{"index", "t", "plan"?}`), a PNG of that frame per reply; `animate-test` for a clip and contact sheet |
| Add B-roll, Choose LUT, Music File, logo, font | `director add <dir> broll\|lut\|music\|logo\|font <file>`, then use the printed path in `plan.json` |
| More sound effects and pictures from Openverse | `director stock <dir> sounds\|images <query> [--credit-ok]`, then `stock <dir> get-sound\|get-image <id>...`; sounds land in My Sounds › Openverse, pictures in `broll/`, each logged in `openverse-licenses.csv` |
| Video B-roll and GIFs | `director stock <dir> videos <query> [--credit-ok] [--source nasa,commons,archive]` or `stock <dir> gifs <query>` (KLIPY reaction GIFs in personal videos only), then `stock <dir> get-video\|get-gif <id>...`; MP4s land in `broll/`, each logged in `broll/stock-licenses.csv`. KLIPY's key: Settings > Stock in the app (Keychain), or `KLIPY_API_KEY` (`bin/director` loads the repo's `.env.local`) |
| Animation template: freeze, Update Template, Save to My Templates | `director template <dir> freeze\|update\|save <name>` |
| Lottie picker, Import Lottie File… | `director lottie <dir> list`, `director lottie <dir> add <file.json>... [--library]` |
| Export, clips, GIF, captions and thumbnails | `director render [--preset id\|--clip name\|--clips]`, `gif`, `publish` |
| Upload and Copy Link | `director upload <file>` (uses Settings › Sharing; macOS asks once to let it read the keys) |
| Join Recordings, Import Video | `director join`, `sd import` |
| Settings (recording, drafts, AI, sharing) | `director settings`, `settings get <key>`, `settings set <key> <value>` (API keys stay in Settings) |
| Record, Stop, Pause, Resume, Restart, Discard, Mark Retake | `open "screencastdirector://record/start"` (`stop`, `pause`, `resume`, `restart`, `discard`, `retake`; a discarded or restarted take goes to the Trash) |
| Watch the recording widget | `director status [--wait <state>] [--timeout <s>]` |
| Open a recording in the editor | `open "screencastdirector://open?project=<folder>"` (a folder outside the projects folder asks first) |

`director validate` checks `plan.json` after a hand edit. It lists each problem with its JSON path, like `zooms[3].x is 1.4; positions are fractions from 0 to 1`, and exits 1 when there are any. Items that run past the end of the recording are only warnings, since they stop there.

`director status` prints the recorder's state as JSON: `idle`, `countdown`, `recording`, `paused`, `saving`, `drafting`, `ready` or `failed`, with the recording's folder once there is one. `ready` comes after the app has drafted and named the recording, so its folder won't move again. To record from a script or an agent:

```sh
open "screencastdirector://record/start"
director status --wait recording      # fails if recording couldn't start (permissions, devices)
# ... the demo ...
open "screencastdirector://record/stop"
director status --wait ready          # prints the project folder, drafted and named
```

The app picks up `director settings set` the next time it comes to the front. Rendering from the CLI while the app has the same video open is safe: each render writes its own temporary file.

## Importing a recording

```sh
bin/sd import demo ~/Movies/take1.mov
```

Without an input log the draft has no click zooms, so ask Claude to add them from the narration.
