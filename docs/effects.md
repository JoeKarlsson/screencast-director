# Effects

An effect is a shader that draws on every frame: film grain, a CRT look, a glitch that hits on each click. Effects are plugins. None ship with the app; you install the ones you want, and a video or profile turns them on.

Example pack: [screencast-director-glitch](https://github.com/JoeKarlsson/screencast-director-glitch) (analog VHS/CRT signal).

## Use one

Put the effect's folder in `~/Library/Application Support/Screencast Director/Effects/`, then list it in the plan:

```jsonc
"effects": [
  { "name": "analog" },
  { "name": "analog", "layer": "camera", "params": { "bloom": 2 } }
]
```

- `layer`: `screen` (the screen recording, before it's placed, so the effect follows zooms), `camera` (after the camera grade, mirrored when the camera is) or `frame` (the whole picture). Titles, captions and other overlays are always drawn on top, so they stay readable. Without `layer`, the effect uses its own.
- `params`: the effect's settings by name. One left out uses its default. Values are clamped to the effect's range.
- Effects on the same layer draw in the order listed.

A profile can turn effects on for every video: add the same `effects` list to its `profile.json`.

The first time a video uses an effect, it's copied into the video's own `effects/` folder, so changing the library later never changes a finished video. To pick up a library change, delete the video's copy.

A missing effect, a bad `effect.json`, or a shader that doesn't compile stops the video from building, with a message naming the effect. `director describe` lists a video's effects and flags missing ones.

## Write one

An effect is a folder `<name>/` (letters, digits, `-`, `_`) with two files.

`effect.json`:

```json
{
  "title": "Grain",
  "layer": "frame",
  "reach": 0,
  "params": [{ "name": "amount", "default": 0.04, "min": 0, "max": 0.3 }]
}
```

- `reach`: how many pixels away the shader reads (for shifts, smears and glows). Reads beyond it come back clamped to the tile's edge, so set it to the furthest offset you use.
- `params`: floats the shader reads as `p[0]`, `p[1]`, … in this order.
- `tracking`: `true` for an effect that draws on followed points (see Tracking below). Leave it out otherwise.

`effect.metal`, a Metal function:

```metal
float4 effect(Layer src, float2 pos, Signals s, constant float *p) {
  float4 c = src.read(pos);
  return float4(c.rgb + (hash(pos + s.frame) - 0.5) * p[0], 1);
}
```

- `pos`: pixels from the layer's top-left corner (at the pixel's center). `src.read(pos)` reads the layer there, clamped to its edges.
- Colors are sRGB-encoded 0 to 1, as they look on screen.
- The app compiles the shader when a video builds, so no Xcode is needed. These come with it:

| Name | What it is |
|---|---|
| `s.size` | the layer's size in pixels |
| `s.click` | where the last click was, 0 to 1 of the screen, y down |
| `s.time`, `s.frame` | seconds and frames into the output video |
| `s.sinceClick` | seconds since the last click (1e6 before the first) |
| `s.toCut` | seconds to the nearest visible change, before or after: a cut between clips, B-roll or an animation starting or ending, a layout change, a punch-in |
| `s.cutTime` | when that nearest change happens, in output seconds (-1 with none): the same around one change and different at the next, so an effect can vary from cut to cut |
| `s.cutIndex` | which change that is: 0 for the first, in play order (-1 with none), for effects that take turns |
| `s.cutKind` | what that change is: 0 a cut between clips, 1 a jump back to an earlier moment (after a cold open), 2 B-roll or an animation starting or ending, 3 a layout change, 4 a punch-in, 5 a new section (a chapter or slate title); a frame where several land gets the first of jump back, section, B-roll, cut, layout, punch-in |
| `s.speed` | playback speed of the clip on screen (1 is real time) |
| `hash(float2)` | a 0 to 1 pseudo-random number for a point |
| `luma(float4)` | a color's brightness |

## Tracking

An effect with `"tracking": true` gets up to 32 followed points on its layer: `s.blobs` says how many, and `src.blobs[i]` is each one as a `float4`: `xy` its center in the layer's pixels (y down), `z` a box size in pixels that scales with the person, `w` an id that stays the same for the same point from frame to frame.

- `camera`: body joints and fingertips, found by Vision. Ids: 0 nose, 1-2 eyes, 3-4 ears, 5 neck, 6-7 shoulders, 8-9 elbows, 10-11 wrists, 20-24 and 30-34 the fingertips of each hand. The first video that needs them tracks the camera at 10 frames a second and saves `tracking.json` next to it (a couple of minutes of camera takes about 15 s). Points move smoothly between those samples.
- `screen`: 100 the pointer, 101 and up clicks from the last 1.5 s.
- `frame`: none, since the camera and screen can be anywhere in it.

Effects run on the GPU and can only change pixels: they can't read files or the network.
