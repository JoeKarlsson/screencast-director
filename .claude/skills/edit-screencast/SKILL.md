---
name: edit-screencast
description: Edit a recorded screencast in this repo by changing its plan.json (cuts, speed-ups, zooms, layouts, captions, callouts), then verify and render. Use when the user says "edit my recording", "tighten this video", "zoom in when I...", "cut the part where...", or names a project under projects/.
---

# Edit a screencast

Arguments: a project name (folder under `projects/`), plus optional instructions.

## 1. Get the project ready

- If `projects/<name>/transcript.json` is missing, run `bin/sd analyze <name>`.
- If `plan.json` is missing, run `bin/sd plan <name>`. Never pass `--force` on a plan that may hold edits unless the user asks to start over.
- Run `bin/sd describe <name>` and read `plan.json`. Read `CLAUDE.md` for the plan rules.

## 2. Edit pass

Apply the user's instructions first. Then make a quality pass unless they asked for only a specific change:

- **Retakes:** when the speaker says a sentence, stumbles, and says it again, keep only the last clean take. Look for repeated phrases in the transcript and for "sorry", "let me try that again", "wait".
- **Dead air:** gaps over ~0.6 s with nothing on screen should be cut; leave about 0.1 s on each side.
- **Speed:** typing or waiting with no narration should be sped up (3x typing, 4 to 8x for builds and installs). Never speed up narration.
- **Zooms:** when the speaker points at something ("this button", "up here in the config"), add or move a zoom to it. Use click positions from `events.jsonl` (via `describe`) to find where things are. Keep zooms at least ~1.5 s long and don't stack them so tight that the camera jitters.
- **Callouts:** short (2 to 5 word) titles at the start of each new section of the demo.
- **Layouts** (only with a camera): `camera` for an intro or outro talking to the lens, `side` for explanations without screen action, `pip` elsewhere.
- Keep each segment's `note` meaningful; it shows up in `describe`.

## 3. Verify before rendering

- Run `bin/sd describe <name>` again and read it as a viewer would: does every cut land between sentences? Is any narration sped up?
- Render stills at the moments you changed (command in `CLAUDE.md`) and look at them: zoom framing, callout text, layout.

## 4. Render and report

- `bin/sd render <name>` writes `projects/<name>/out.mp4`. For a quick look, open the project in the Screencast Director app.
- Report the source and output length, and list what you changed in a few lines, with output timestamps so the user can jump to them.
