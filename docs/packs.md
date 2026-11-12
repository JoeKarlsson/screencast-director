# Packs

A pack bundles a look so someone else can use it: profiles plus the animation themes, templates, logos, Lotties, effects, sounds and music they use. The app ships with plain profiles and two animation themes (paper and terminal). Anything more personal or branded comes from a pack.

## What's in a pack

A pack is a folder, or the same folder zipped with a `.sdpack` extension. Its layout mirrors the app's support folder, `~/Library/Application Support/Screencast Director`, so every file lands where the app already looks:

```
My Look/
  pack.json
  Profiles/<profile name>/profile.json   (plus its fonts, logos, LUTs, music)
  Animations/themes/<theme>/              theme.json, theme.css, theme.js, marks.json
  Animations/templates/<name>.js, <name>.json
  Animations/logos/                        SVGs or PNGs, plus logos.json
  Animations/lottie/                       Lottie .json files
  Effects/<effect>/                        see effects.md
  Sounds/                                  sound effects
  Music/                                   music tracks
  Work/Sounds/, Work/Music/                offered only in videos whose profile is a work profile
```

Every folder is optional. `pack.json` names the pack:

```json
{ "name": "My Look", "version": "1.0.0", "about": "Dark stage, hand-drawn lines, two profiles." }
```

## Install, list and remove

- In the app: **File > Install Pack…**, or double-click a `.sdpack` in Finder.
- From the command line:

```sh
director pack install <folder-or-.sdpack> [--replace]
director pack list
director pack remove <name>
```

The app carries the CLI at `/Applications/Screencast Director.app/Contents/MacOS/director`; in this repo it's `bin/director`.

**Conflicts.** A file the pack has that's already installed with the same contents is skipped. If any file differs from what's installed, install lists those files and stops without changing anything. Run it again with `--replace` to overwrite them.

## Make one

```sh
director pack export my-look.sdpack --profile "Work" [--profile "Talks"] [--work]
```

Export collects each named profile with the fonts, logos, LUTs and music it points at (copying in any that live elsewhere), plus the effects and animation theme it uses. Templates, logos and Lotties a theme doesn't carry go in by hand. `--work` also includes `Work/Sounds` and `Work/Music`. You can also build the folder by hand and zip it.

## Safety

A pack is files, never a program.

- Nothing runs at install. Install only copies files.
- No symlinks. A pack that contains one is refused.
- Every file must sit inside one of the fixed folders above; another folder at the top is refused. Loose files at the top (pack.json, a README, a LICENSE, a script that zips the pack) and anything starting with a dot (`.git`) are left out, so a pack can live in a git repo.
- A `.sdpack` whose paths climb out (`..`), start at `/`, or that would unpack to more than 4 GB is refused before anything is unpacked.
- A theme's or template's script runs only inside the animation page, which has no network access and can't read files beyond the app's own animation folder and the video's assets.
- `director pack remove <name>` deletes only the files that pack installed, and keeps any you've changed since.

Still, only install packs from people you trust, the same as fonts or any other files.

## Finished videos don't change

A video keeps its own copy of every template, theme, Lottie and effect it uses, made the first time it renders. Updating or removing a pack doesn't change videos you've already made. The exceptions are a profile's fonts and LUTs: plans point at those in the support folder, so replacing them in a pack changes how those videos render next time.

## Write a theme

A theme lives in `Animations/themes/<name>/`. A video picks it with `look.animationTheme: "<name>"`, usually through its profile.

### theme.json

```json
{
  "title": "Night Pencil",
  "css": "theme.css",
  "scripts": ["theme.js"],
  "marks": "marks.json",
  "coverMarks": true
}
```

- `title`: the name the app shows.
- `css`: a stylesheet loaded after the engine's. Set `--paper`, `--ink` and `--accent` here, plus anything else you restyle.
- `scripts`: scripts run in order, after the engine and the template and before the animation starts. Usually one that registers the theme's hooks; a library it needs (a brush engine, say) goes first.
- `marks`: a file of hand-drawn marks that replace the app's by name. The animations draw them, and so does the app itself (a big chapter's rays and coil).
- `coverMarks`: whether the theme's marks are drawn on generated covers and thumbnails.

### marks.json

Each entry replaces the app's mark of that name: `oval` and `burst` (the Sticker Note; `burst` also flares behind storyboard nodes as they land), `coil` and `rays` (big chapters), and `underline` and `asterisk` (covers). A theme can add others for its own scripts, which read them from `SCRIBBLES[name]`. The viewBox must start at `0 0`.

```json
{
  "oval": { "viewBox": "0 0 200 80", "path": "M12 40 C 20 8, 180 6, 190 38 ..." },
  "underline": { "viewBox": "0 0 300 20", "path": "M4 12 C 80 6, 220 16, 296 9" }
}
```

A path with several moves (`M`) draws as several strokes, one after another.

### theme.js hooks

A theme script registers its hooks on `THEMES`. Every hook is optional; leave one out and the engine does its usual thing.

```js
THEMES["night-pencil"] = {
  setup({ stage, k, config }) {},          // once the stage is sized, before the template builds; k is clip pixels per stage pixel
  stroke(path, width) { return width; },   // the stroke width for a line
  curve(a, b, t, seed, bend, tangle) {     // the shape of a line from a to b
    return { d: "M...", at: (u) => [x, y] };  // a falsy return keeps the usual line
  },
  draw(path, curve, progress, opacity) {   // draw a line yourself; return true to hide the SVG path
    return false;
  },
  highlight(hl, p) { return false; },      // draw a highlighted heading word; return true if you did
  beforePackets(t) {},                     // each frame, before packets run along the lines
  tick(t) {},                              // each frame, after everything else
};
```

`aboveLines(node)` puts a node of yours (a canvas the lines are drawn on) above the SVG lines and under the packets. `squiggle(a, b, t, seed)` is a ready-made hand-wobbled line.

Draw from `t` alone. The renderer draws a frame at several nearby times for motion blur, so a hook must not keep state between calls or use timers.
