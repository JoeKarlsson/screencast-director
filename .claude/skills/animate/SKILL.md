---
name: animate
description: Add a Vox-style motion-graphics explainer (real logos, sticker pop-ins, hand-drawn lines, highlighter) to a recording by adding an `animations` entry to its plan.json, timed to the spoken words, or write a new animation template for one video. Use when the user says "animate the part where I...", "make a diagram for...", "add an explainer/animation", or names a template (storyboard, sprawl, hub).
---

# Animate a stretch of a recording

An animation is a template filled with data and cued to spoken words. It lives in the plan's `animations` list and plays full frame over the video (captions stay on top). `director animate` renders each one with the macOS web view to `.animations/<template>-<hash>.mp4`; the app renders new or changed ones on its own.

## Where templates live

First match wins:
1. **The video:** `<project>/animations/templates/<name>.js` + `.json`, and `<project>/animations/logos/`.
2. **The personal library:** `~/Library/Application Support/Screencast Director/Animations/` (same layout).
3. **Built into the app:** `macos/Resources/animations/` in this repo.

A video freezes every template it uses: the first render (or adding one in the app) copies the template into the video's folder, so changing a template in the library never changes a finished video. The clip's name includes the frozen copy's contents, so editing the video's copy re-renders it. In the app, the inspector offers Update Template (take the library's latest) and Save to My Templates (copy the video's version to the personal library).

## 1. Find the stretch and its words

Run `bin/sd describe <name>` (or `bin/director describe <dir>`) and read `transcript.json` (`segments[].words[]` with `word`, `start`, `end` in source seconds). The animation's `start` is the first word's start and its `end` is where the speaker moves on. Check that the stretch is kept in the edit (inside `segments`). Don't cover a camera punch-in (`camera.punchIns`) or a moment where the screen matters.

## 2. Pick a template

Read the manifests (`templates/*.json`: `summary`, `fields`, `cues`, starting `data`) in all three folders.

- **storyboard** is the default for anything specific to this video. Its `steps` build a diagram on cue: `show` a node (`kind` dot, sticker, card or label; `logo`, or `icon` for a hand-drawn line icon when there's no logo: laptop, prompter, camera, mic, phone, server, database, cloud, user, doc, chart, bolt; `label`, optional `x`/`y` in % of the frame, else laid out around the board's first node), `connect` two nodes (`label`, `dashed`), `note`, `count` (a tally row counting up to `value`), `highlight`, `dim`, `hide` a node by `target` id, `tangle` the lines, `circle` the board, `clear` to a new board. Every step has a `cue` key whose time goes in `cues`.
- The storyboard does its own flourishes, so the steps only say what and when: the heading rises a word at a time, every node slams in with squash and stretch and a scribble burst behind it, icons draw themselves, packets run along finished lines, and the camera starts close on the first node and pulls back on a spring as each new one appears, so give nodes room rather than packing them in. Animations should look alive: if a test sheet looks static, add motion instead of toning it down.
- **sprawl** and **hub** are fixed stories (wiring apps up one at a time until it's a mess; one hub that fans out). Use them when the narration is that story.
- **Nothing fits?** Write a new template for this video (below).

Logos come from each folder's `logos/logos.json` (display name → file in that folder). A name with no logo shows as text. To add a logo for one video, put the SVG in `<project>/animations/logos/` and a line in that folder's `logos.json`; Simple Icons (CC0) SVGs need `fill="#brandhex"` on the root `<svg>`.

## 3. Cue the beats to words

`cues` maps each beat (or storyboard step's `cue`) to a source time, usually the start of the word that names it. Give a beat a few tenths of a second before the word if it should be on screen as the word lands.

## 4. Add it, render, check

```json
"animations": [{
  "start": 420.4, "end": 436.0, "template": "storyboard", "note": "Two apps, one answer",
  "data": { "title": "Two apps, one answer", "highlight": "one answer", "steps": [
    { "cue": "s1", "do": "show", "id": "agent", "kind": "dot", "logo": "OpenAI", "label": "your dot", "x": 24, "y": 55 },
    { "cue": "s2", "do": "show", "id": "hub", "kind": "card", "logo": "CData", "label": "Connect AI", "x": 52, "y": 55 },
    { "cue": "s3", "do": "connect", "from": "agent", "to": "hub", "label": "1 plugin" }
  ] },
  "cues": { "s1": 420.6, "s2": 421.6, "s3": 422.4 }
}]
```

Run `bin/director animate <dir>` (one to two minutes per 20 s of animation) and look at the contact sheet, which has a frame after each cue: `director contact-sheet <dir> <dir>/.checks/sheet.png`. Look closer with `director still <dir> <frame> /tmp/a.png`. Check that nothing overlaps, nothing runs off the frame, the bottom ~150 px stays clear for captions, and each beat lands on its word.

## Writing a template for one video

When the narration needs a shape the storyboard can't make (a map, a chart, a timeline, a before/after split), write a template into the video's own folder: `<project>/animations/templates/<name>.js` and `<name>.json`. Start from a built-in one.

Test the hardest beat first: once the template draws, render one second of it before the whole animation, `bin/director animate-test <dir> <index> <source-second>` (index in the plan's `animations`, the second where the tricky move starts). It writes `.checks/animation-<index>-test.mp4` and a contact sheet of its 12 frames beside it (`.png`, labeled with source times). Read the sheet, fix the movement and texture, and test again; render the full animation only once that second looks right.

- The `.js` registers `TEMPLATES.<name> = function (data, cues, duration) { ...; return t => { /* draw time t */ } }`. Build it from the kit in `engine.js` so it shares the look: `el` (stickers, dots, tags, hands, rows), `logoHTML`/`LOGOS[name]`, `popScale` (pop-ins that spring a little past full size), `spring(x, zeta)` and `easeOut` (closed-form springs for any other move), `land` (a slam-in with squash and stretch), `burstMark`/`drawBurst` (the scribble burst behind a landing), `iconHTML`/`drawIcons` (self-drawing line icons), `revealHeading` (words rising out of a mask); packets run along every finished `drawPath` line on their own, `path`/`handCurve`/`drawPath` (lines that draw on and boil), `heading`/`setHL` (highlighter), `tally`/`showTally`, `camera`, `grain`, `cue(cues, name, fallback)`. The stage is 1920×1080 design pixels; the accent is `var(--accent)`. Motion blur is automatic: the renderer averages snapshots across each frame wherever something moves, so don't add blur filters to fake it. Draw everything from `t` alone (no timers or state carried between calls), since a frame is drawn at several nearby times.
- The video's look picks the theme (`look.animationTheme`, set by its profile): unset is the paper collage (CData), `terminal` a 90s screen (Signal Loss), `zine` joekarlsson.com's black stage with hot pink cards, squiggly lines in colored pencil (p5.brush, drawn for every line that goes through `drawPath`), pink highlighted heading words and the site's scribbles drifting dimly behind (the Pink Scribble profile). The kit's helpers draw each theme's version (`path` adds the crayon, `handCurve` squiggles or runs at right angles, `setHL` turns the words pink or inverse, `popScale` flickers on in terminal), so build from them and color with `var(--paper)` (the background), `var(--ink)` and `var(--accent)` instead of fixed colors, and a template works in every theme. Check stills in the theme the video uses.
- The `.json` is what the app's editor shows: `name`, `title`, `summary`, `length`, `fields` (dotted `key` into `data`; `type` text, texts, logo, logos, number or steps; optional `max`, `help`), `cues` (`key`, `label`, default `at` seconds for `length`), and starting `data`.
- Render and check stills as above. Iterate on the video's copy; each edit re-renders.
- If the user likes it and wants it again, copy both files into the personal library folder (or have them press Save to My Templates in the app).

Templates that should ship with the app go in `macos/Resources/animations/templates/` in this repo, with their manifest; the app picks them up with no other changes. Bump `Animation.engineVersion` in `DirectorCore/Animation.swift` only when `engine.js` changes how existing clips look.
