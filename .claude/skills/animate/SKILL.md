---
name: animate
description: Add a Vox-style motion-graphics explainer (real logos, sticker pop-ins, hand-drawn lines, highlighter) to a recording by adding an `animations` entry to its plan.json, timed to the spoken words. Use when the user says "animate the part where I...", "make a diagram for...", "add an explainer/animation", or names one of the templates (sprawl, hub).
---

# Animate a stretch of a recording

An animation is a template filled with data and cued to spoken words. It lives in the plan's `animations` list and plays full frame over the video (captions stay on top). `director animate` renders each one with the macOS web view to `.animations/<template>-<hash>.mp4`. The hash covers the data, the cues and the length, so any change re-renders, and the app renders new ones on its own.

## 1. Find the stretch and its words

Run `bin/sd describe <name>` (or `macos/.build/release/director describe <dir>`) and read the transcript in `transcript.json` (`segments[].words[]` with `word`, `start`, `end` in source seconds). Pick the sentences the animation explains. The animation's `start` is the first word's start, and its `end` is where the speaker moves on. Check that the stretch is kept in the edit (inside `segments`); a cut inside it would chop the animation.

Don't cover a camera punch-in (`camera.punchIns`) or a moment where the screen matters. The animation hides the screen and the face.

## 2. Pick a template and fill its data

Templates live in `macos/Resources/animations/templates/`. Each file's header lists its `data` fields and `cues`. Read the header before filling it in.

- **sprawl**: one thing wired to many apps one at a time, each with its own costs (sign-ins, permissions, logs), until it tangles into a mess. Good for "doing it the hard way".
- **hub**: one connection to a hub that fans out to many apps, with one of each cost. The answer to sprawl. Use the two back to back for problem → solution.

Logos come from `macos/Resources/animations/logos/logos.json` (display name → file). A name with no logo file shows as text in a sticker. Add a logo by dropping a colored SVG in `logos/` and a line in `logos.json`; Simple Icons (CC0) SVGs need `fill="#brandhex"` on the root `<svg>`.

Keep the text short and in the speaker's words. The heading's `highlight` is the phrase that gets the yellow highlighter.

## 3. Cue the beats to words

`cues` maps each beat name to a source time, usually the start of the word that names it ("another **sign-in**" → `cost1`). Beats left out use the template's defaults, which are rarely right. Give a beat a few tenths of a second before the word if it should be on screen as the word lands.

## 4. Add it, render, check

```json
"animations": [{
  "start": 55.75, "end": 81.6, "template": "sprawl", "note": "Hooking up apps one at a time",
  "data": { "title": "Hooking up apps one at a time", "highlight": "one at a time", "center": {"logo": "OpenAI", "label": "your dot"},
            "apps": ["Salesforce", "Slack", "Jira"], "costs": ["sign-ins", "sets of permissions", "places to check"] },
  "cues": { "apps": 56.35, "cost1": 67.35, "cost2": 69.25, "cost3": 71.55, "few": 75.35, "many": 78.7 }
}]
```

Then run `macos/.build/release/director animate <dir>` (about a minute per 20 s of animation) and look at stills across it: `director still <dir> <frame> /tmp/a.png` at a few output frames inside the animation, especially each beat. Check that nothing overlaps, nothing runs off the frame, the captions are clear at the bottom, and each beat lands on its word. Fix by changing data, cues or the template, and render again.

## Writing a new template

Copy a template in `templates/`, register it as `TEMPLATES.<name>` and add its `<script>` tag to `animation.html`. Build it from the kit in `engine.js` (`el`, `popScale`, `popBlur`, `handCurve`, `drawPath`, `heading`, `tally`, `camera`, `grain`, `cue`) so it shares the look: white paper, grain, stickers that pop in with overshoot, lines that draw on, highlighter accents, a camera that always drifts. Keep the bottom ~150 px clear for captions. Bump `Animation.engineVersion` in `DirectorCore/Animation.swift` when a change to the templates or engine should re-render existing clips.
