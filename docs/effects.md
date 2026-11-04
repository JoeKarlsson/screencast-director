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

- `layer`: `screen` (the screen recording, before it's placed, so the effect follows zooms), `camera` (after the camera grade) or `frame` (the whole picture). Titles, captions and other overlays are always drawn on top, so they stay readable. Without `layer`, the effect uses its own.
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
| `s.toCut` | seconds to the nearest cut between clips, before or after |
| `s.speed` | playback speed of the clip on screen (1 is real time) |
| `hash(float2)` | a 0 to 1 pseudo-random number for a point |
| `luma(float4)` | a color's brightness |

Effects run on the GPU and can only change pixels: they can't read files or the network.
