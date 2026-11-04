# plan.json

Each project folder holds the recording and a `plan.json` that describes the edit. All times are **seconds in the raw recording**, not in the output.

```jsonc
{
  "segments": [{ "start": 0, "end": 3.4, "speed": 1 }, { "start": 6.5, "end": 9.5, "speed": 3 }],
  "zooms": [{ "start": 6.4, "end": 10.6, "x": 0.75, "y": 0.29, "scale": 2 }],
  "defaultLayout": "pip",                       // screen | pip | side | camera
  "layouts": [{ "start": 0, "end": 4, "mode": "camera" }],
  "callouts": [{ "start": 10, "end": 11.5, "text": "Open Settings" }],
  "captions": { "enabled": true, "maxWords": 7 },
  "style": { "background": ["#1d2b64", "#f8cdda"], "padding": 0.06, "radius": 14, "transition": 0.8 }
}
```

- `segments` play in the order they're listed (plan `version` 2; version 1 plans play in recording order) and must not overlap. Anything not covered is cut. Usually they're in recording order; listing a later one first makes a cold open, and every zoom, title, caption and sound stays in source time and moves with its clip (`director move <dir> <start> <end> [--before <t>]`). A segment with `repeats: true` is a second showing of a moment that also plays in its own place, the only kind allowed to overlap (`director repeat <dir> <start> <end> [--before <t>]`): zooms, punch-ins, B-roll and captions play in both showings, titles and sound effects only in the original.
- Segments with `speed > 1` render muted.
- `effects`: shader plugins drawn on the screen, camera or whole frame, like `[{ "name": "analog", "params": { "bloom": 2 } }]`. See [effects.md](effects.md).
- `intro` / `outro` (macOS app only): `{ "enabled": true, "title": "...", "subtitle": "...", "duration": 2.5 }` adds a full-frame card before or after the video. A card is shown unless `"enabled": false`. Source times don't change; the output starts after the intro.

The full schema is in `macos/Sources/DirectorCore/Plan.swift`.

## Project folder

| File | What it is |
|---|---|
| `screen.mp4` | The screen recording (and `camera.mp4` when recorded) |
| `events.jsonl` | Clicks, keystrokes and cursor moves |
| `source.json` | Capture metadata, including the clock offset |
| `transcript.json` | Word-level transcript |
| `motion.json` | Frame-to-frame screen motion |
| `plan.json` | The edit |
| `voice-clean.m4a` | The cleaned voice, when Clean up voice is on (rendered on demand) |
| `out.mp4` | The render |
