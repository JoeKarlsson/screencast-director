---
paths:
  - "bin/**"
---

# ffmpeg and `bin/sd`

- The Homebrew ffmpeg here has no `drawtext`; `drawbox` sizes and positions don't animate. Animate with `overlay` expressions.
- `macos/cli-test.sh` (CI) covers `sd`: help, import and its errors, plan (with `--force` passed through) and describe on a temp projects folder (`SD_PROJECTS`, `SD_DIRECTOR`). The app records; `sd` has no record command. An agent starts and stops recording in the running app with `open "screencastdirector://record/start"` (see `DirectorCore/AppURL.swift`), and follows it with `director status --wait recording|ready` (`DirectorCore/RecordingStatus.swift`).
- `freezedetect` compares against the first frame of a freeze, so slow changes break it; motion uses frame-to-frame difference (`tblend` + `signalstats`) instead.
