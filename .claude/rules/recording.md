---
paths:
  - "bin/**"
---

# Recording and ffmpeg (`bin/sd`)

- The Homebrew ffmpeg here has no `drawtext`; `drawbox` sizes and positions don't animate. Animate with `overlay` expressions.
- `freezedetect` compares against the first frame of a freeze, so slow changes break it; motion uses frame-to-frame difference (`tblend` + `signalstats`) instead.
