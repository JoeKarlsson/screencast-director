---
paths:
  - "macos/Tests/**"
  - "macos/*.sh"
  - "test/**"
---

# Test suites

- `test.sh`, `playback-test.sh` and `media-test.sh` compile their checks through `run-checks.sh` (plain swiftc against every DirectorCore source). A new `Tests/Checks*.swift` file's function is called from `Checks.main`.
- `macos/test.sh` covers the timeline math, planner rules, editing, `PlanCheck`, the Claude box's arguments and edit-prompt.md's coverage of plan fields. `test/make-fixture.sh` builds a synthetic project (`projects/fixture`) whose green top bar grows 96 px per source second, so frame mapping can be read off any rendered frame.
- `macos/playback-test.sh` plays a composition from a synthetic recording through `AVPlayerItemVideoOutput` and fails on black or missing frames (runs in CI).
- `macos/media-test.sh` (`Tests/Media.swift`, about 50 s, runs in CI) checks the media pipeline on synthetic recordings it draws with CoreGraphics (ffmpeg muxes a test tone): motion sampling, WAV extraction and loudness, `analyze` without audio, Vision screen text under a click, `Join.run` (camera stretched onto the joined clock, every timed file shifted), GIF export, and `Publish.run` without a camera. It also runs the export queue to two finished exports, the face steps (thumbnail faces, face centering, the person cutout, lip sync recovering a 0.3 s camera lag) on `test/fixtures/talking-head.mp4` (40 s of a public-domain NASA downlink; see its README), and the conversion of whisper-cli's JSON into transcript.json from a captured sample (`test/fixtures/whisper-cli.json`). No model runs in tests: whisper itself and `Analyzer.transcribe` (which runs whisper-cli) are untested.
- `macos/animate-test.sh` renders one animation per bundled template through `director animate` on a temp fixture and fails on a template error, a missing or wrong-length clip, or a blank last frame (about 2 minutes, runs in CI).
- `macos/cli-test.sh` (runs in CI, about 90 s) runs each `director` command and `bin/sd` (help, import, plan with --force, describe) on a temp fixture with a written transcript.json, and checks what they wrote: plan.json edits, `validate`'s problems and exit code, rendered sizes and lengths (the video stream exactly; the sound must reach the end and stop within a second, since AAC padding varies), and that bad input fails with a message. Skipped: `upload` (credentials; only its missing-settings error), `analyze` with audio (Whisper; it runs on a silent copy instead), `frame-camera`/`sync-camera` (need a face; only their no-camera errors).
- `macos/smoke-test.sh` drives the app; see `macos-app.md`.
