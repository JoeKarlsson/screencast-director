---
paths:
  - "bin/**"
---

# Recording and ffmpeg (`bin/sd`)

- The Homebrew ffmpeg here has no `drawtext`; `drawbox` sizes and positions don't animate. Animate with `overlay` expressions.
- `test/sd-test.sh` (CI) covers `sd`: help, import and its errors, plan and describe on a temp projects folder (`SD_PROJECTS`, `SD_DIRECTOR`), and what `record` does after ffmpeg stops. It sources `bin/sd`, which then only defines its functions, so keep record's logic in functions (`capture_start`, `camera_offset`, `write_source`) the test can call. Recording itself needs devices and stays manual.
- `freezedetect` compares against the first frame of a freeze, so slow changes break it; motion uses frame-to-frame difference (`tblend` + `signalstats`) instead.
